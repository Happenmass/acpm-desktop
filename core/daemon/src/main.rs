mod discovery;

use acpm_pal::{default_telemetry, HostProfile, RuntimePaths, SystemTelemetry};
use acpm_protocol::{
    ApiError, ApiErrorEnvelope, BudgetTier, DiagnosticFailure, ErrorCode, FailureStage,
    ModelStatusInfo, SystemStatusResponse, WorkerState,
};
use acpm_registry::{compute_default_budget, ModelRegistry};
use axum::body::Body;
use axum::extract::State;
use axum::http::{header, HeaderMap, Request, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use clap::Parser;
use discovery::{DiscoveryGuard, RuntimeDiscovery};
use serde::Serialize;
use std::collections::BTreeMap;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::net::TcpListener;
use tracing::{info, warn};
use uuid::Uuid;

#[derive(Debug, Parser)]
#[command(name = "acpmd", version, about = "Cross-platform acpm-desktop control plane daemon")]
struct Args {
    #[arg(long)]
    data_dir: Option<PathBuf>,

    #[arg(long, default_value = "127.0.0.1")]
    host: String,

    #[arg(long, default_value_t = 18790)]
    port: u16,

    #[arg(long)]
    registry: Option<PathBuf>,

    #[arg(long, default_value_t = false)]
    headless: bool,
}

#[derive(Clone)]
struct AppState {
    token: String,
    paths: RuntimePaths,
    profile: HostProfile,
    registry: ModelRegistry,
    telemetry: Arc<dyn SystemTelemetry>,
}

#[derive(Serialize)]
struct HealthResponse<'a> {
    status: &'a str,
    version: &'a str,
    platform: &'a str,
}

#[derive(Serialize)]
struct ModelsListResponse {
    models: Vec<ModelStatusInfo>,
}

#[derive(Serialize)]
struct FailuresListResponse {
    failures: Vec<DiagnosticFailure>,
}

fn api_error_response(
    code: ErrorCode,
    stage: FailureStage,
    detail: impl Into<String>,
    message: impl Into<String>,
    request_id: impl Into<String>,
) -> Response {
    let status = StatusCode::from_u16(code.http_status()).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    let body = ApiErrorEnvelope {
        error: ApiError::new(code, stage, detail, message, request_id),
    };
    (status, Json(body)).into_response()
}

fn is_allowed_local_host(host: &str) -> bool {
    if host.starts_with("[::1]") {
        let rest = &host[5..];
        return rest.is_empty() || rest.starts_with(':');
    }
    let name = host.split(':').next().unwrap_or("");
    matches!(name, "127.0.0.1" | "localhost")
}

fn extract_request_id(headers: &HeaderMap) -> String {
    headers
        .get("X-AI-Request-Id")
        .and_then(|v| v.to_str().ok())
        .filter(|s| !s.is_empty())
        .map(ToString::to_string)
        .unwrap_or_else(|| Uuid::new_v4().to_string())
}

async fn security_middleware(
    State(state): State<AppState>,
    req: Request<Body>,
    next: Next,
) -> Response {
    if req.uri().path() == "/healthz" {
        return next.run(req).await;
    }

    let request_id = extract_request_id(req.headers());

    if let Some(host_val) = req.headers().get(header::HOST).and_then(|v| v.to_str().ok()) {
        if !is_allowed_local_host(host_val) {
            return api_error_response(
                ErrorCode::Forbidden,
                FailureStage::HttpAdmission,
                "INVALID_HOST_HEADER",
                "Rejected non-loopback Host header.",
                request_id,
            );
        }
    }

    if let Some(origin) = req.headers().get(header::ORIGIN).and_then(|v| v.to_str().ok()) {
        if !origin.is_empty() {
            return api_error_response(
                ErrorCode::Forbidden,
                FailureStage::HttpAdmission,
                "ORIGIN_HEADER_REJECTED",
                "Browser cross-origin requests are blocked.",
                request_id,
            );
        }
    }

    let auth_header = req
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    let expected = format!("Bearer {}", state.token);
    if auth_header != expected {
        return api_error_response(
            ErrorCode::Unauthorized,
            FailureStage::HttpAdmission,
            "INVALID_OR_MISSING_TOKEN",
            "Missing or invalid Bearer token.",
            request_id,
        );
    }

    next.run(req).await
}

async fn healthz(State(state): State<AppState>) -> impl IntoResponse {
    Json(HealthResponse {
        status: "ok",
        version: env!("CARGO_PKG_VERSION"),
        platform: &state.profile.platform,
    })
}

async fn list_models(State(state): State<AppState>) -> impl IntoResponse {
    let models = state
        .registry
        .models()
        .iter()
        .map(|entry| {
            let resolved = state
                .registry
                .resolve_variant(&entry.id, &state.profile.platform, None)
                .ok()
                .map(|(_, variant)| variant);
            let installed = resolved
                .map(|v| state.registry.is_variant_installed(&state.paths.models_dir, &entry.id, v))
                .unwrap_or(false);
            ModelStatusInfo {
                id: entry.id.clone(),
                capability: entry.capability,
                display_name: entry.display_name.clone(),
                selected_variant: resolved.map(|v| v.variant_id.clone()),
                installed,
                state: WorkerState::Stopped,
                pin_policy: entry.lifecycle.pin_policy,
                idle_timeout_sec: entry.lifecycle.idle_timeout_sec,
                memory: Default::default(),
            }
        })
        .collect();

    Json(ModelsListResponse { models })
}

async fn system_status(State(state): State<AppState>) -> impl IntoResponse {
    let budget = compute_default_budget(&state.profile, BudgetTier::Balanced);
    Json(SystemStatusResponse {
        platform: state.profile.platform.clone(),
        pid: std::process::id(),
        budget: budget.limits,
        used: Default::default(),
        memory_pressure: state.telemetry.memory_pressure(),
        thermal_state: state.telemetry.thermal_state(),
        loaded_models: Vec::new(),
        active_requests: 0,
        queued_requests: 0,
        caller_counts: BTreeMap::new(),
    })
}

async fn system_failures() -> impl IntoResponse {
    Json(FailuresListResponse {
        failures: Vec::new(),
    })
}

async fn not_implemented_inference(headers: HeaderMap) -> Response {
    let request_id = extract_request_id(&headers);
    api_error_response(
        ErrorCode::NotImplemented,
        FailureStage::WorkerStart,
        "PHASE1_WORKER_SUPERVISOR_PENDING",
        "Control plane skeleton is running; worker subprocess execution is wired in Phase 1.",
        request_id,
    )
}

async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
    info!("received shutdown signal, stopping acpmd");
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "acpmd=info".into()),
        )
        .init();

    let args = Args::parse();
    let paths = args
        .data_dir
        .map(RuntimePaths::from_data_dir)
        .unwrap_or_else(RuntimePaths::default_for_current_os);

    std::fs::create_dir_all(&paths.models_dir)?;
    std::fs::create_dir_all(&paths.voices_dir)?;

    let telemetry: Arc<dyn SystemTelemetry> = Arc::from(default_telemetry());
    let profile = telemetry.host_profile()?;

    let registry = match args.registry {
        Some(path) => ModelRegistry::from_file(&path)?,
        None => ModelRegistry::embedded_default()?,
    };

    let token = format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple());
    let bind_addr: SocketAddr = format!("{}:{}", args.host, args.port).parse()?;
    let listener = TcpListener::bind(bind_addr).await?;
    let local_addr = listener.local_addr()?;
    let http_base_url = format!("http://{local_addr}");

    let discovery = RuntimeDiscovery::new(
        http_base_url.clone(),
        paths.native_ipc_path.display().to_string(),
        token.clone(),
        profile.platform.clone(),
    );
    let _guard = DiscoveryGuard::write_atomic(&paths.runtime_json, &discovery)?;

    info!(
        platform = %profile.platform,
        http = %http_base_url,
        headless = args.headless,
        "acpmd control plane started"
    );
    if !paths.runtime_json.exists() {
        warn!("runtime discovery file missing unexpectedly");
    }

    let state = AppState {
        token,
        paths,
        profile,
        registry,
        telemetry,
    };

    let app = Router::new()
        .route("/healthz", get(healthz))
        .route("/v1/models", get(list_models))
        .route("/v1/system/status", get(system_status))
        .route("/v1/system/failures", get(system_failures))
        .route("/v1/chat/completions", post(not_implemented_inference))
        .route("/v1/audio/transcriptions", post(not_implemented_inference))
        .route("/v1/audio/speech", post(not_implemented_inference))
        .route("/v1/audio/vad", post(not_implemented_inference))
        .route("/v1/audio/diarization", post(not_implemented_inference))
        .layer(middleware::from_fn_with_state(
            state.clone(),
            security_middleware,
        ))
        .with_state(state);

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;

    Ok(())
}
