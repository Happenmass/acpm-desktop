mod batches;
mod config;
mod diagnostics;
mod discovery;
mod downloader;
mod mdns;
mod multipart;
mod supervisor;
mod voices;
mod worker_client;

use acpm_pal::{default_telemetry, HostProfile, RuntimePaths, SystemTelemetry};
use acpm_protocol::{
    ApiError, ApiErrorEnvelope, BudgetTier, ChatCompletionRequest, CreateSpeechBatchRequest,
    CreateVoiceRequest, DiagnosticFailure, ErrorCode, FailureStage, ModelDownloadState,
    ModelStatusInfo, Priority, SpeechBatchState, SpeechRequest, StartDownloadRequest,
    TranscriptionRequest, UpdateModelConfigRequest, UpdateSystemConfigRequest, VadRequest,
    VoiceProfile,
};
use acpm_registry::ModelRegistry;
use axum::body::{Body, Bytes};
use axum::extract::{DefaultBodyLimit, Path as AxumPath, Query, State};
use axum::http::{header, HeaderMap, HeaderName, HeaderValue, Request, StatusCode};
use axum::middleware::{self, Next};
use axum::response::sse::{Event, KeepAlive, Sse};
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, patch, post};
use axum::{Json, Router};
use batches::BatchManager;
use clap::Parser;
use config::{
    parse_model_path_arg, resolve_worker_mlx_bin, resolve_worker_speech_bin, DaemonFileConfig,
    ModelOverrideConfig,
};
use diagnostics::DiagnosticsStore;
use discovery::{DiscoveryGuard, RuntimeDiscovery};
use downloader::DownloadManager;
use futures_util::stream;
use mdns::{normalize_mdns_hostname, MdnsAdvertiser, MdnsConfig};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::convert::Infallible;
use std::net::{Ipv4Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::{Arc, RwLock};
use std::time::Duration;
use supervisor::{RequestContext, RuntimeSupervisor, SpeechOutput, SupervisorConfig};
use tokio::net::TcpListener;
use tokio::sync::broadcast::error::RecvError;
use tokio::sync::watch;
use tracing::{info, warn};
use uuid::Uuid;
use voices::VoiceStore;

#[derive(Debug, Parser)]
#[command(name = "acpmd", version, about = "Cross-platform acpm-desktop control plane daemon")]
struct Args {
    #[arg(long)]
    data_dir: Option<PathBuf>,

    #[arg(long)]
    host: Option<String>,

    #[arg(long, default_value_t = 18790)]
    port: u16,

    #[arg(long, default_value = "acpm.local")]
    mdns_host: String,

    #[arg(long, default_value = "acpm-desktop")]
    mdns_service_name: String,

    #[arg(long, default_value_t = false)]
    no_mdns: bool,

    #[arg(long)]
    token: Option<String>,

    #[arg(long)]
    registry: Option<PathBuf>,

    #[arg(long = "model-path")]
    model_paths: Vec<String>,

    #[arg(long)]
    worker_mlx_bin: Option<PathBuf>,

    #[arg(long)]
    worker_speech_bin: Option<PathBuf>,

    #[arg(long)]
    budget_tier: Option<String>,

    #[arg(long)]
    budget_mb: Option<u64>,

    #[arg(long, default_value_t = 5000)]
    idle_check_interval_ms: u64,

    #[arg(long)]
    default_idle_timeout_sec: Option<u64>,

    #[arg(long, default_value_t = false)]
    headless: bool,
}

#[derive(Clone)]
struct AppState {
    token: String,
    profile: HostProfile,
    supervisor: RuntimeSupervisor,
    voices: VoiceStore,
    batches: BatchManager,
    downloads: DownloadManager,
    http_base_url: String,
    mdns_hostname: Option<String>,
    mdns_base_url: Option<String>,
    active_lan_ip: Arc<RwLock<Option<Ipv4Addr>>>,
}

#[derive(Serialize)]
struct HealthResponse {
    status: &'static str,
    version: &'static str,
    platform: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    mdns_hostname: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    mdns_base_url: Option<String>,
}

#[derive(Serialize)]
struct ModelsListResponse {
    models: Vec<ModelStatusInfo>,
}

#[derive(Serialize)]
struct FailuresListResponse {
    failures: Vec<DiagnosticFailure>,
}

#[derive(Default, Deserialize)]
struct LoadModelBody {
    #[serde(default)]
    quant: Option<String>,
}

#[derive(Deserialize)]
struct PrewarmBody {
    models: Vec<String>,
}

#[derive(Default, Deserialize)]
struct UnloadAllBody {
    #[serde(default)]
    include_pinned: bool,
}

#[derive(Serialize)]
struct UnloadAllResponse {
    unloaded: Vec<String>,
}

fn api_error_into_response(err: ApiError) -> Response {
    let status = StatusCode::from_u16(err.code.http_status()).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    let req_id = err.request_id.clone();
    let mut resp = (status, Json(ApiErrorEnvelope { error: err })).into_response();
    if let Ok(hv) = HeaderValue::from_str(&req_id) {
        resp.headers_mut()
            .insert(HeaderName::from_static("x-ai-request-id"), hv);
    }
    resp
}

fn api_error_response(
    code: ErrorCode,
    stage: FailureStage,
    detail: impl Into<String>,
    message: impl Into<String>,
    request_id: impl Into<String>,
) -> Response {
    api_error_into_response(ApiError::new(code, stage, detail, message, request_id))
}

fn extract_host_name(raw_host: &str) -> Option<String> {
    let trimmed = raw_host.trim();
    if trimmed.is_empty() {
        return None;
    }
    if let Some(after_open) = trimmed.strip_prefix('[') {
        let close_idx = after_open.find(']')?;
        let inner = &after_open[..close_idx];
        let rest = &after_open[close_idx + 1..];
        if !rest.is_empty() && !rest.starts_with(':') {
            return None;
        }
        return Some(inner.to_ascii_lowercase());
    }
    let name = match trimmed.rsplit_once(':') {
        Some((h, port)) if !port.is_empty() && port.chars().all(|c| c.is_ascii_digit()) => h,
        Some(_) => return None,
        None => trimmed,
    };
    Some(name.trim_end_matches('.').to_ascii_lowercase())
}

fn is_allowed_local_host(
    host: &str,
    allowed_mdns_host: Option<&str>,
    active_lan_ip: Option<Ipv4Addr>,
) -> bool {
    let Some(name) = extract_host_name(host) else {
        return false;
    };
    if matches!(name.as_str(), "127.0.0.1" | "localhost" | "::1") {
        return true;
    }
    if let Some(mdns) = allowed_mdns_host {
        if name == mdns.trim_end_matches('.').to_ascii_lowercase() {
            return true;
        }
    }
    if let Some(ip) = active_lan_ip {
        if name == ip.to_string() {
            return true;
        }
    }
    false
}

fn load_or_create_token(data_dir: &Path, cli_token: Option<String>) -> std::io::Result<String> {
    if let Some(explicit) = cli_token.filter(|t| !t.trim().is_empty()) {
        return Ok(explicit);
    }
    let token_path = data_dir.join("auth_token");
    if let Ok(existing) = std::fs::read_to_string(&token_path) {
        let trimmed = existing.trim();
        if !trimmed.is_empty() {
            return Ok(trimmed.to_string());
        }
    }
    let generated = format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple());
    let tmp_path = data_dir.join(format!("auth_token.tmp.{}", std::process::id()));
    std::fs::write(&tmp_path, format!("{generated}\n"))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&tmp_path, std::fs::Permissions::from_mode(0o600))?;
    }
    std::fs::rename(&tmp_path, &token_path)?;
    Ok(generated)
}

fn extract_request_id(headers: &HeaderMap) -> String {
    headers
        .get("X-AI-Request-Id")
        .and_then(|v| v.to_str().ok())
        .filter(|s| !s.is_empty())
        .map(ToString::to_string)
        .unwrap_or_else(|| Uuid::new_v4().to_string())
}

fn extract_request_context(headers: &HeaderMap) -> RequestContext {
    let request_id = extract_request_id(headers);
    let caller_raw = headers
        .get("X-AI-Caller")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("unknown")
        .trim();
    let mut caller: String = caller_raw
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-'))
        .take(64)
        .collect();
    if caller.is_empty() {
        caller = "unknown".to_string();
    }

    let priority = match headers
        .get("X-AI-Priority")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("normal")
        .trim()
        .to_ascii_lowercase()
        .as_str()
    {
        "interactive" | "p0" => Priority::Interactive,
        "batch" | "p2" => Priority::Batch,
        _ => Priority::Normal,
    };

    RequestContext {
        request_id,
        caller,
        priority,
    }
}

async fn security_middleware(
    State(state): State<AppState>,
    req: Request<Body>,
    next: Next,
) -> Response {
    let request_id = extract_request_id(req.headers());
    if req.uri().path() == "/healthz" {
        let mut resp = next.run(req).await;
        if let Ok(hv) = HeaderValue::from_str(&request_id) {
            resp.headers_mut()
                .insert(HeaderName::from_static("x-ai-request-id"), hv);
        }
        return resp;
    }

    let active_ip = state.active_lan_ip.read().ok().and_then(|g| *g);
    if let Some(host_val) = req.headers().get(header::HOST).and_then(|v| v.to_str().ok()) {
        if !is_allowed_local_host(host_val, state.mdns_hostname.as_deref(), active_ip) {
            return api_error_response(
                ErrorCode::Forbidden,
                FailureStage::HttpAdmission,
                "INVALID_HOST_HEADER",
                "Rejected non-loopback or non-LAN Host header.",
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

    let mut resp = next.run(req).await;
    if let Ok(hv) = HeaderValue::from_str(&request_id) {
        resp.headers_mut()
            .insert(HeaderName::from_static("x-ai-request-id"), hv);
    }
    resp
}

async fn healthz(State(state): State<AppState>) -> impl IntoResponse {
    Json(HealthResponse {
        status: "ok",
        version: env!("CARGO_PKG_VERSION"),
        platform: state.profile.platform.clone(),
        mdns_hostname: state.mdns_hostname.clone(),
        mdns_base_url: state.mdns_base_url.clone(),
    })
}

async fn list_models(State(state): State<AppState>) -> impl IntoResponse {
    Json(ModelsListResponse {
        models: state.supervisor.list_models_status(),
    })
}

async fn load_model_handler(
    State(state): State<AppState>,
    AxumPath(model_id): AxumPath<String>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let ctx = extract_request_context(&headers);
    let quant = if body.is_empty() {
        None
    } else {
        serde_json::from_slice::<LoadModelBody>(&body)
            .ok()
            .and_then(|b| b.quant)
    };
    match state
        .supervisor
        .load_model(&model_id, quant.as_deref(), &ctx)
        .await
    {
        Ok(info) => (StatusCode::OK, Json(info)).into_response(),
        Err(err) => api_error_into_response(err),
    }
}

async fn unload_model_handler(
    State(state): State<AppState>,
    AxumPath(model_id): AxumPath<String>,
    headers: HeaderMap,
) -> Response {
    let ctx = extract_request_context(&headers);
    match state.supervisor.unload_model(&model_id, &ctx).await {
        Ok(info) => (StatusCode::OK, Json(info)).into_response(),
        Err(err) => api_error_into_response(err),
    }
}

async fn prewarm_models_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(payload): Json<PrewarmBody>,
) -> Response {
    let ctx = extract_request_context(&headers);
    match state.supervisor.prewarm(&payload.models, &ctx).await {
        Ok(models) => (StatusCode::OK, Json(ModelsListResponse { models })).into_response(),
        Err(err) => api_error_into_response(err),
    }
}

async fn system_status(State(state): State<AppState>) -> impl IntoResponse {
    Json(state.supervisor.system_status())
}

async fn system_failures(State(state): State<AppState>) -> impl IntoResponse {
    Json(FailuresListResponse {
        failures: state.supervisor.recent_failures(20),
    })
}

async fn system_events(State(state): State<AppState>) -> impl IntoResponse {
    let rx = state.supervisor.subscribe_events();
    let event_stream = stream::unfold(rx, |mut rx| async move {
        loop {
            match rx.recv().await {
                Ok(ev) => {
                    let data = serde_json::to_string(&ev).unwrap_or_else(|_| "{}".to_string());
                    return Some((Ok::<Event, Infallible>(Event::default().data(data)), rx));
                }
                Err(RecvError::Lagged(_)) => continue,
                Err(RecvError::Closed) => return None,
            }
        }
    });
    Sse::new(event_stream).keep_alive(KeepAlive::default())
}

async fn unload_all_handler(
    State(state): State<AppState>,
    body: Bytes,
) -> Response {
    let include_pinned = if body.is_empty() {
        false
    } else {
        serde_json::from_slice::<UnloadAllBody>(&body)
            .map(|b| b.include_pinned)
            .unwrap_or(false)
    };
    let unloaded = state.supervisor.unload_all(include_pinned).await;
    (StatusCode::OK, Json(UnloadAllResponse { unloaded })).into_response()
}

async fn chat_completions_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(payload): Json<ChatCompletionRequest>,
) -> Response {
    let ctx = extract_request_context(&headers);
    if payload.stream {
        match state.supervisor.chat_completion_stream(payload, ctx).await {
            Ok(rx) => {
                let sse_stream = stream::unfold(rx, |mut rx| async move {
                    rx.recv().await.map(|item| (item, rx))
                });
                Sse::new(sse_stream)
                    .keep_alive(KeepAlive::default())
                    .into_response()
            }
            Err(err) => api_error_into_response(err),
        }
    } else {
        match state.supervisor.chat_completion(payload, ctx).await {
            Ok(resp) => (StatusCode::OK, Json(resp)).into_response(),
            Err(err) => api_error_into_response(err),
        }
    }
}

struct TempFileGuard {
    path: PathBuf,
}

impl Drop for TempFileGuard {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

async fn audio_transcriptions_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let ctx = extract_request_context(&headers);
    let content_type_raw = headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    let is_multipart = content_type_raw
        .to_ascii_lowercase()
        .contains("multipart/form-data");

    let mut _temp_guard: Option<TempFileGuard> = None;
    let req: TranscriptionRequest = if is_multipart {
        let Some(boundary) = multipart::extract_boundary(content_type_raw) else {
            return api_error_response(
                ErrorCode::InvalidRequest,
                FailureStage::HttpAdmission,
                "MISSING_MULTIPART_BOUNDARY",
                "Missing multipart boundary in Content-Type header.",
                ctx.request_id,
            );
        };
        let fields = match multipart::parse_multipart(&body, &boundary) {
            Ok(f) => f,
            Err(msg) => {
                return api_error_response(
                    ErrorCode::InvalidRequest,
                    FailureStage::HttpAdmission,
                    "INVALID_MULTIPART_BODY",
                    msg,
                    ctx.request_id,
                );
            }
        };

        let mut model: Option<String> = None;
        let mut language: Option<String> = None;
        let mut prompt: Option<String> = None;
        let mut vad_filter = true;
        let mut timestamps = true;
        let mut temp_path: Option<PathBuf> = None;

        for field in fields {
            match field.name.as_str() {
                "model" => {
                    let s = String::from_utf8_lossy(&field.data).trim().to_string();
                    if !s.is_empty() {
                        model = Some(s);
                    }
                }
                "language" => {
                    let s = String::from_utf8_lossy(&field.data).trim().to_string();
                    if !s.is_empty() {
                        language = Some(s);
                    }
                }
                "prompt" => {
                    let s = String::from_utf8_lossy(&field.data).to_string();
                    if !s.is_empty() {
                        prompt = Some(s);
                    }
                }
                "vad_filter" => {
                    vad_filter = String::from_utf8_lossy(&field.data).trim() != "false";
                }
                "timestamps" => {
                    timestamps = String::from_utf8_lossy(&field.data).trim() != "false";
                }
                "file" => {
                    let ext = field
                        .filename
                        .as_deref()
                        .and_then(|f| Path::new(f).extension())
                        .and_then(|e| e.to_str())
                        .filter(|e| !e.is_empty())
                        .unwrap_or("wav");
                    let path = std::env::temp_dir()
                        .join(format!("acpmd-upload-{}.{ext}", Uuid::new_v4()));
                    if let Err(err) = std::fs::write(&path, &field.data) {
                        return api_error_response(
                            ErrorCode::InferenceFailed,
                            FailureStage::AudioValidation,
                            "TEMP_AUDIO_WRITE_FAILED",
                            format!("Failed writing uploaded audio: {err}"),
                            ctx.request_id,
                        );
                    }
                    temp_path = Some(path);
                }
                _ => {}
            }
        }

        let Some(audio_file) = temp_path else {
            return api_error_response(
                ErrorCode::AudioValidationFailed,
                FailureStage::AudioValidation,
                "MISSING_UPLOAD_FILE",
                "Multipart transcription request did not contain a 'file' part.",
                ctx.request_id,
            );
        };
        let resolved_model = model.unwrap_or_else(|| "qwen3-asr-1.7b".to_string());
        let file_path = audio_file.display().to_string();
        _temp_guard = Some(TempFileGuard { path: audio_file });

        TranscriptionRequest {
            model: resolved_model,
            file_path,
            language,
            vad_filter,
            timestamps,
            prompt,
        }
    } else {
        match serde_json::from_slice::<TranscriptionRequest>(&body) {
            Ok(r) => r,
            Err(err) => {
                return api_error_response(
                    ErrorCode::InvalidRequest,
                    FailureStage::HttpAdmission,
                    "INVALID_TRANSCRIPTION_JSON",
                    format!("Failed parsing transcription JSON: {err}"),
                    ctx.request_id,
                );
            }
        }
    };

    match state.supervisor.transcribe(req, ctx).await {
        Ok(resp) => (StatusCode::OK, Json(resp)).into_response(),
        Err(err) => api_error_into_response(err),
    }
}

#[derive(Serialize)]
struct VoicesListResponse {
    voices: Vec<VoiceProfile>,
}

#[derive(Serialize)]
struct BatchesListResponse {
    batches: Vec<SpeechBatchState>,
}

async fn audio_speech_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(mut payload): Json<SpeechRequest>,
) -> Response {
    let ctx = extract_request_context(&headers);
    match state.voices.resolve_for_speech(
        payload.voice.take(),
        payload.reference_audio.take(),
        payload.reference_text.take(),
    ) {
        Ok(resolved) => {
            payload.voice = resolved.voice;
            payload.reference_audio = resolved.reference_audio;
            payload.reference_text = resolved.reference_text;
        }
        Err(err) => return api_error_into_response(err.into_api_error(&ctx.request_id)),
    }

    match state.supervisor.synthesize(payload, ctx).await {
        Ok(SpeechOutput::File(meta)) => (StatusCode::OK, Json(meta)).into_response(),
        Ok(SpeechOutput::AudioBytes {
            wav,
            duration_ms,
            decode_ms,
            voice_cache_hit,
            queue_ms,
            model_load_ms,
        }) => {
            let mut resp = Response::new(Body::from(wav));
            *resp.status_mut() = StatusCode::OK;
            resp.headers_mut().insert(
                header::CONTENT_TYPE,
                HeaderValue::from_static("audio/wav"),
            );
            let extra_headers = [
                ("x-ai-audio-duration-ms", duration_ms.to_string()),
                ("x-ai-timing-decode-ms", format!("{decode_ms:.2}")),
                ("x-ai-timing-queue-ms", format!("{queue_ms:.2}")),
                ("x-ai-timing-model-load-ms", format!("{model_load_ms:.2}")),
                (
                    "x-ai-voice-cache-hit",
                    if voice_cache_hit { "true" } else { "false" }.to_string(),
                ),
            ];
            for (k, v) in extra_headers {
                if let (Ok(name), Ok(val)) = (
                    HeaderName::from_bytes(k.as_bytes()),
                    HeaderValue::from_str(&v),
                ) {
                    resp.headers_mut().insert(name, val);
                }
            }
            resp
        }
        Err(err) => api_error_into_response(err),
    }
}

fn save_temp_audio(field: &multipart::MultipartField, request_id: &str) -> Result<PathBuf, Response> {
    let ext = field
        .filename
        .as_deref()
        .and_then(|f| Path::new(f).extension())
        .and_then(|e| e.to_str())
        .filter(|e| !e.is_empty() && e.chars().all(|c| c.is_ascii_alphanumeric()))
        .unwrap_or("wav");
    let path = std::env::temp_dir().join(format!("acpmd-upload-{}.{ext}", Uuid::new_v4()));
    if let Err(err) = std::fs::write(&path, &field.data) {
        return Err(api_error_response(
            ErrorCode::InferenceFailed,
            FailureStage::AudioValidation,
            "TEMP_AUDIO_WRITE_FAILED",
            format!("Failed writing uploaded audio: {err}"),
            request_id.to_string(),
        ));
    }
    Ok(path)
}

fn parse_multipart_or_err(
    headers: &HeaderMap,
    body: &[u8],
    request_id: &str,
) -> Result<Vec<multipart::MultipartField>, Response> {
    let content_type_raw = headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    let Some(boundary) = multipart::extract_boundary(content_type_raw) else {
        return Err(api_error_response(
            ErrorCode::InvalidRequest,
            FailureStage::HttpAdmission,
            "MISSING_MULTIPART_BOUNDARY",
            "Missing multipart boundary in Content-Type header.",
            request_id.to_string(),
        ));
    };
    multipart::parse_multipart(body, &boundary).map_err(|msg| {
        api_error_response(
            ErrorCode::InvalidRequest,
            FailureStage::HttpAdmission,
            "INVALID_MULTIPART_BODY",
            msg,
            request_id.to_string(),
        )
    })
}

async fn audio_vad_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let ctx = extract_request_context(&headers);
    let content_type_raw = headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    let is_multipart = content_type_raw
        .to_ascii_lowercase()
        .contains("multipart/form-data");

    let mut _temp_guard: Option<TempFileGuard> = None;
    let req: VadRequest = if is_multipart {
        let fields = match parse_multipart_or_err(&headers, &body, &ctx.request_id) {
            Ok(f) => f,
            Err(resp) => return resp,
        };
        let mut model: Option<String> = None;
        let mut min_speech_ms: Option<i64> = None;
        let mut min_silence_ms: Option<i64> = None;
        let mut temp_path: Option<PathBuf> = None;
        for field in fields {
            match field.name.as_str() {
                "model" => {
                    let s = String::from_utf8_lossy(&field.data).trim().to_string();
                    if !s.is_empty() {
                        model = Some(s);
                    }
                }
                "min_speech_ms" => {
                    min_speech_ms = String::from_utf8_lossy(&field.data).trim().parse().ok();
                }
                "min_silence_ms" => {
                    min_silence_ms = String::from_utf8_lossy(&field.data).trim().parse().ok();
                }
                "file" => {
                    let path = match save_temp_audio(&field, &ctx.request_id) {
                        Ok(p) => p,
                        Err(resp) => return resp,
                    };
                    temp_path = Some(path);
                }
                _ => {}
            }
        }
        let Some(audio_file) = temp_path else {
            return api_error_response(
                ErrorCode::AudioValidationFailed,
                FailureStage::AudioValidation,
                "MISSING_UPLOAD_FILE",
                "Multipart VAD request did not contain a 'file' part.",
                ctx.request_id,
            );
        };
        let file_path = audio_file.display().to_string();
        _temp_guard = Some(TempFileGuard { path: audio_file });
        VadRequest {
            model: model.unwrap_or_else(|| "speech-vad-pyannote".to_string()),
            file_path,
            min_speech_ms,
            min_silence_ms,
        }
    } else {
        match serde_json::from_slice::<VadRequest>(&body) {
            Ok(r) => r,
            Err(err) => {
                return api_error_response(
                    ErrorCode::InvalidRequest,
                    FailureStage::HttpAdmission,
                    "INVALID_VAD_JSON",
                    format!("Failed parsing VAD JSON: {err}"),
                    ctx.request_id,
                );
            }
        }
    };

    match state.supervisor.vad(req, ctx).await {
        Ok(resp) => (StatusCode::OK, Json(resp)).into_response(),
        Err(err) => api_error_into_response(err),
    }
}

async fn diarization_deferred_handler(headers: HeaderMap) -> Response {
    let request_id = extract_request_id(&headers);
    api_error_response(
        ErrorCode::NotImplemented,
        FailureStage::HttpAdmission,
        "DIARIZATION_DEFERRED",
        "Speaker diarization is deferred in the current phase; only VAD is enabled.",
        request_id,
    )
}

async fn list_voices_handler(State(state): State<AppState>) -> impl IntoResponse {
    Json(VoicesListResponse {
        voices: state.voices.list(),
    })
}

async fn create_voice_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let request_id = extract_request_id(&headers);
    let content_type_raw = headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    let is_multipart = content_type_raw
        .to_ascii_lowercase()
        .contains("multipart/form-data");

    let created = if is_multipart {
        let fields = match parse_multipart_or_err(&headers, &body, &request_id) {
            Ok(f) => f,
            Err(resp) => return resp,
        };
        let mut name = String::new();
        let mut reference_text: Option<String> = None;
        let mut language: Option<String> = None;
        let mut notes: Option<String> = None;
        let mut audio_bytes: Option<(Vec<u8>, Option<String>)> = None;

        for field in fields {
            match field.name.as_str() {
                "name" => name = String::from_utf8_lossy(&field.data).to_string(),
                "reference_text" => {
                    reference_text = Some(String::from_utf8_lossy(&field.data).to_string());
                }
                "language" => language = Some(String::from_utf8_lossy(&field.data).to_string()),
                "notes" => notes = Some(String::from_utf8_lossy(&field.data).to_string()),
                "audio" | "file" => {
                    audio_bytes = Some((field.data, field.filename));
                }
                _ => {}
            }
        }
        let Some((bytes, filename)) = audio_bytes else {
            return api_error_response(
                ErrorCode::AudioValidationFailed,
                FailureStage::AudioValidation,
                "MISSING_VOICE_AUDIO",
                "Multipart voice creation request must include an 'audio' or 'file' part.",
                request_id,
            );
        };
        state
            .voices
            .register_from_bytes(name, filename.as_deref(), bytes, reference_text, language, notes)
            .await
    } else {
        let req: CreateVoiceRequest = match serde_json::from_slice(&body) {
            Ok(r) => r,
            Err(err) => {
                return api_error_response(
                    ErrorCode::InvalidRequest,
                    FailureStage::HttpAdmission,
                    "INVALID_VOICE_JSON",
                    format!("Failed parsing voice JSON: {err}"),
                    request_id,
                );
            }
        };
        state
            .voices
            .register_from_file(
                req.name,
                Path::new(&req.reference_audio),
                req.reference_text,
                req.language,
                req.notes,
            )
            .await
    };

    match created {
        Ok(profile) => (StatusCode::CREATED, Json(profile)).into_response(),
        Err(err) => api_error_into_response(err.into_api_error(&request_id)),
    }
}

async fn get_voice_handler(
    State(state): State<AppState>,
    AxumPath(voice_id): AxumPath<String>,
    headers: HeaderMap,
) -> Response {
    let request_id = extract_request_id(&headers);
    match state.voices.get(&voice_id) {
        Some((profile, _)) => (StatusCode::OK, Json(profile)).into_response(),
        None => api_error_response(
            ErrorCode::NotFound,
            FailureStage::HttpAdmission,
            "VOICE_NOT_FOUND",
            format!("Voice '{voice_id}' not found."),
            request_id,
        ),
    }
}

async fn get_voice_sample_handler(
    State(state): State<AppState>,
    AxumPath(voice_id): AxumPath<String>,
    headers: HeaderMap,
) -> Response {
    let request_id = extract_request_id(&headers);
    let Some(sample_path) = state.voices.sample_path(&voice_id) else {
        return api_error_response(
            ErrorCode::NotFound,
            FailureStage::HttpAdmission,
            "VOICE_NOT_FOUND",
            format!("Voice '{voice_id}' not found."),
            request_id,
        );
    };
    match std::fs::read(&sample_path) {
        Ok(bytes) => {
            let mut resp = Response::new(Body::from(bytes));
            *resp.status_mut() = StatusCode::OK;
            resp.headers_mut().insert(
                header::CONTENT_TYPE,
                HeaderValue::from_static("audio/wav"),
            );
            if let Ok(cd) = HeaderValue::from_str(&format!("inline; filename=\"{voice_id}.wav\"")) {
                resp.headers_mut()
                    .insert(header::CONTENT_DISPOSITION, cd);
            }
            resp
        }
        Err(err) => api_error_response(
            ErrorCode::InferenceFailed,
            FailureStage::AudioValidation,
            "VOICE_SAMPLE_UNREADABLE",
            format!("Failed reading voice sample: {err}"),
            request_id,
        ),
    }
}

async fn delete_voice_handler(
    State(state): State<AppState>,
    AxumPath(voice_id): AxumPath<String>,
    headers: HeaderMap,
) -> Response {
    let request_id = extract_request_id(&headers);
    match state.voices.delete(&voice_id) {
        Ok(true) => StatusCode::NO_CONTENT.into_response(),
        Ok(false) => api_error_response(
            ErrorCode::NotFound,
            FailureStage::HttpAdmission,
            "VOICE_NOT_FOUND",
            format!("Voice '{voice_id}' not found."),
            request_id,
        ),
        Err(err) => api_error_into_response(err.into_api_error(&request_id)),
    }
}

async fn list_speech_batches_handler(State(state): State<AppState>) -> impl IntoResponse {
    Json(BatchesListResponse {
        batches: state.batches.list_batches(),
    })
}

async fn create_speech_batch_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(payload): Json<CreateSpeechBatchRequest>,
) -> Response {
    let ctx = extract_request_context(&headers);
    match state.batches.create_batch(payload, ctx.caller) {
        Ok(batch) => (StatusCode::ACCEPTED, Json(batch)).into_response(),
        Err(err) => api_error_into_response(err.into_api_error(&ctx.request_id)),
    }
}

async fn get_speech_batch_handler(
    State(state): State<AppState>,
    AxumPath(batch_id): AxumPath<String>,
    headers: HeaderMap,
) -> Response {
    let request_id = extract_request_id(&headers);
    match state.batches.get_batch(&batch_id) {
        Some(batch) => (StatusCode::OK, Json(batch)).into_response(),
        None => api_error_response(
            ErrorCode::NotFound,
            FailureStage::HttpAdmission,
            "SPEECH_BATCH_NOT_FOUND",
            format!("Speech batch '{batch_id}' not found."),
            request_id,
        ),
    }
}

async fn speech_batch_events_handler(
    State(state): State<AppState>,
    AxumPath(batch_id): AxumPath<String>,
    headers: HeaderMap,
) -> Response {
    let request_id = extract_request_id(&headers);
    let Some((initial, rx)) = state.batches.subscribe_batch(&batch_id) else {
        return api_error_response(
            ErrorCode::NotFound,
            FailureStage::HttpAdmission,
            "SPEECH_BATCH_NOT_FOUND",
            format!("Speech batch '{batch_id}' not found."),
            request_id,
        );
    };

    let is_terminal = |st: &SpeechBatchState| {
        matches!(
            st.status,
            acpm_protocol::SpeechBatchStatus::Completed
                | acpm_protocol::SpeechBatchStatus::CompletedWithErrors
                | acpm_protocol::SpeechBatchStatus::Cancelled
        )
    };

    let event_stream = stream::unfold(
        (Some(initial), Some(rx)),
        move |(initial_opt, mut rx_opt)| async move {
            if let Some(init) = initial_opt {
                let data = serde_json::to_string(&init).unwrap_or_else(|_| "{}".to_string());
                let next_rx = if is_terminal(&init) { None } else { rx_opt };
                return Some((Ok::<Event, Infallible>(Event::default().data(data)), (None, next_rx)));
            }
            let Some(ref mut rx) = rx_opt else {
                return None;
            };
            loop {
                match rx.recv().await {
                    Ok(ev) => {
                        let data =
                            serde_json::to_string(&ev).unwrap_or_else(|_| "{}".to_string());
                        let next_rx = if is_terminal(&ev) { None } else { rx_opt };
                        return Some((
                            Ok::<Event, Infallible>(Event::default().data(data)),
                            (None, next_rx),
                        ));
                    }
                    Err(RecvError::Lagged(_)) => continue,
                    Err(RecvError::Closed) => return None,
                }
            }
        },
    );
    Sse::new(event_stream)
        .keep_alive(KeepAlive::default())
        .into_response()
}

async fn pause_speech_batch_handler(
    State(state): State<AppState>,
    AxumPath(batch_id): AxumPath<String>,
    headers: HeaderMap,
) -> Response {
    let request_id = extract_request_id(&headers);
    match state.batches.pause_batch(&batch_id) {
        Ok(batch) => (StatusCode::OK, Json(batch)).into_response(),
        Err(err) => api_error_into_response(err.into_api_error(&request_id)),
    }
}

async fn resume_speech_batch_handler(
    State(state): State<AppState>,
    AxumPath(batch_id): AxumPath<String>,
    headers: HeaderMap,
) -> Response {
    let request_id = extract_request_id(&headers);
    match state.batches.resume_batch(&batch_id) {
        Ok(batch) => (StatusCode::OK, Json(batch)).into_response(),
        Err(err) => api_error_into_response(err.into_api_error(&request_id)),
    }
}

async fn cancel_speech_batch_handler(
    State(state): State<AppState>,
    AxumPath(batch_id): AxumPath<String>,
    headers: HeaderMap,
) -> Response {
    let request_id = extract_request_id(&headers);
    match state.batches.cancel_batch(&batch_id) {
        Ok(batch) => (StatusCode::OK, Json(batch)).into_response(),
        Err(err) => api_error_into_response(err.into_api_error(&request_id)),
    }
}

#[derive(Serialize)]
struct DownloadsListResponse {
    downloads: Vec<ModelDownloadState>,
}

#[derive(Default, Deserialize)]
struct DeleteModelQuery {
    #[serde(default)]
    quant: Option<String>,
}

async fn get_system_config_handler(State(state): State<AppState>) -> impl IntoResponse {
    Json(state.supervisor.get_system_config(
        state.http_base_url.clone(),
        state.mdns_hostname.clone(),
        state.mdns_base_url.clone(),
    ))
}

async fn update_system_config_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(payload): Json<UpdateSystemConfigRequest>,
) -> Response {
    let request_id = extract_request_id(&headers);
    match state.supervisor.update_system_config(
        payload,
        state.http_base_url.clone(),
        state.mdns_hostname.clone(),
        state.mdns_base_url.clone(),
    ) {
        Ok(cfg) => (StatusCode::OK, Json(cfg)).into_response(),
        Err(msg) => api_error_response(
            ErrorCode::InferenceFailed,
            FailureStage::HttpAdmission,
            "CONFIG_SAVE_FAILED",
            msg,
            request_id,
        ),
    }
}

async fn update_model_config_handler(
    State(state): State<AppState>,
    AxumPath(model_id): AxumPath<String>,
    headers: HeaderMap,
    Json(payload): Json<UpdateModelConfigRequest>,
) -> Response {
    let ctx = extract_request_context(&headers);
    match state.supervisor.update_model_config(&model_id, payload, &ctx) {
        Ok(info) => (StatusCode::OK, Json(info)).into_response(),
        Err(err) => api_error_into_response(err),
    }
}

async fn list_downloads_handler(State(state): State<AppState>) -> impl IntoResponse {
    Json(DownloadsListResponse {
        downloads: state.downloads.list_downloads(),
    })
}

async fn start_download_handler(
    State(state): State<AppState>,
    AxumPath(model_id): AxumPath<String>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let ctx = extract_request_context(&headers);
    let quant = if body.is_empty() {
        None
    } else {
        serde_json::from_slice::<StartDownloadRequest>(&body)
            .ok()
            .and_then(|r| r.quant)
    };
    match state
        .downloads
        .start_download(&model_id, quant, ctx.request_id.clone(), ctx.caller)
    {
        Ok(st) => (StatusCode::ACCEPTED, Json(st)).into_response(),
        Err(err) => api_error_into_response(err.into_api_error(&ctx.request_id)),
    }
}

async fn get_download_handler(
    State(state): State<AppState>,
    AxumPath(model_id): AxumPath<String>,
    headers: HeaderMap,
) -> Response {
    let request_id = extract_request_id(&headers);
    match state.downloads.get_download(&model_id) {
        Some(st) => (StatusCode::OK, Json(st)).into_response(),
        None => api_error_response(
            ErrorCode::NotFound,
            FailureStage::ModelPrepare,
            "DOWNLOAD_NOT_FOUND",
            format!("No download state recorded for '{model_id}'."),
            request_id,
        ),
    }
}

async fn cancel_download_handler(
    State(state): State<AppState>,
    AxumPath(model_id): AxumPath<String>,
    headers: HeaderMap,
) -> Response {
    let request_id = extract_request_id(&headers);
    match state.downloads.cancel_download(&model_id) {
        Ok(st) => (StatusCode::OK, Json(st)).into_response(),
        Err(err) => api_error_into_response(err.into_api_error(&request_id)),
    }
}

async fn delete_model_handler(
    State(state): State<AppState>,
    AxumPath(model_id): AxumPath<String>,
    Query(query): Query<DeleteModelQuery>,
    headers: HeaderMap,
) -> Response {
    let ctx = extract_request_context(&headers);
    match state
        .downloads
        .delete_model(&model_id, query.quant.as_deref(), &ctx)
        .await
    {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(err) => api_error_into_response(err.into_api_error(&ctx.request_id)),
    }
}

async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };

    #[cfg(unix)]
    let terminate = async {
        if let Ok(mut sigterm) =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            sigterm.recv().await;
        } else {
            std::future::pending::<()>().await;
        }
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }

    info!("received shutdown signal, stopping acpmd");
}

fn parse_budget_tier(raw: &str) -> Result<BudgetTier, String> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "eco" => Ok(BudgetTier::Eco),
        "balanced" => Ok(BudgetTier::Balanced),
        "performance" => Ok(BudgetTier::Performance),
        other => Err(format!(
            "invalid --budget-tier '{other}' (expected eco|balanced|performance)"
        )),
    }
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

    let file_cfg = DaemonFileConfig::load_if_exists(&paths.config_json)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;

    let mut model_overrides: BTreeMap<String, ModelOverrideConfig> = file_cfg.model_overrides;
    for raw in &args.model_paths {
        let (model_id, quant, path) = parse_model_path_arg(raw)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidInput, e))?;
        let entry = model_overrides.entry(model_id).or_default();
        entry.path = path;
        if quant.is_some() {
            entry.quant = quant;
        }
    }

    let budget_tier = match args.budget_tier.as_deref() {
        Some(raw) => parse_budget_tier(raw)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidInput, e))?,
        None => file_cfg.budget_tier.unwrap_or(BudgetTier::Balanced),
    };
    let budget_override_mb = args.budget_mb.or(file_cfg.budget_override_mb);
    let worker_mlx_bin = resolve_worker_mlx_bin(args.worker_mlx_bin, file_cfg.worker_mlx_bin);
    if let Some(ref bin) = worker_mlx_bin {
        info!(worker_mlx_bin = %bin.display(), "resolved acpm-worker-mlx binary");
    } else {
        warn!("acpm-worker-mlx binary not found; MLX worker spawns will fail until built or configured");
    }
    let worker_speech_bin =
        resolve_worker_speech_bin(args.worker_speech_bin, file_cfg.worker_speech_bin);
    if let Some(ref bin) = worker_speech_bin {
        info!(worker_speech_bin = %bin.display(), "resolved acpm-worker-speech binary");
    } else {
        warn!("acpm-worker-speech binary not found; CPU VAD worker spawns will fail until built or configured");
    }

    let telemetry: Arc<dyn SystemTelemetry> = Arc::from(default_telemetry());
    let profile = telemetry.host_profile()?;

    let registry = match args.registry {
        Some(path) => ModelRegistry::from_file(&path)?,
        None => ModelRegistry::embedded_default()?,
    };
    let diagnostics = Arc::new(DiagnosticsStore::open(&paths.diagnostics_db));

    let supervisor = RuntimeSupervisor::new(
        registry,
        profile.clone(),
        paths.clone(),
        telemetry,
        diagnostics,
        SupervisorConfig {
            worker_mlx_bin,
            worker_speech_bin,
            model_overrides,
            budget_tier,
            budget_override_mb,
            default_idle_timeout_override: args.default_idle_timeout_sec,
            queue_timeout: Duration::from_secs(30),
            startup_timeout: Duration::from_secs(120),
        },
    );

    let voices = VoiceStore::open(&paths.voices_dir)?;
    let batches = BatchManager::new(supervisor.clone(), voices.clone());

    let reaper_interval = Duration::from_millis(args.idle_check_interval_ms.max(250));
    let reaper_handle = supervisor.start_reaper_task(reaper_interval);

    let token = load_or_create_token(&paths.data_dir, args.token)?;
    let mdns_enabled = !args.no_mdns;
    let bind_host = args
        .host
        .unwrap_or_else(|| if mdns_enabled { "0.0.0.0" } else { "127.0.0.1" }.to_string());
    let bind_addr: SocketAddr = format!("{bind_host}:{}", args.port).parse()?;
    let tcp_listener = TcpListener::bind(bind_addr).await?;
    let local_addr = tcp_listener.local_addr()?;
    let http_base_url = if local_addr.ip().is_unspecified() {
        if local_addr.is_ipv6() {
            format!("http://[::1]:{}", local_addr.port())
        } else {
            format!("http://127.0.0.1:{}", local_addr.port())
        }
    } else {
        format!("http://{local_addr}")
    };

    let mdns_hostname = if mdns_enabled {
        Some(normalize_mdns_hostname(&args.mdns_host))
    } else {
        None
    };
    let mdns_base_url = mdns_hostname
        .as_ref()
        .map(|h| format!("http://{h}:{}", local_addr.port()));

    let mut mdns_advertiser = mdns_hostname.as_ref().map(|host| {
        MdnsAdvertiser::start(MdnsConfig {
            service_name: args.mdns_service_name.clone(),
            hostname: host.clone(),
            port: local_addr.port(),
            capabilities: vec![
                "llm".to_string(),
                "asr".to_string(),
                "tts".to_string(),
                "vad".to_string(),
            ],
        })
    });
    let active_lan_ip = mdns_advertiser
        .as_ref()
        .map(MdnsAdvertiser::active_ip_handle)
        .unwrap_or_else(|| Arc::new(RwLock::new(None)));

    let discovery = RuntimeDiscovery::new(
        http_base_url.clone(),
        paths.native_ipc_path.display().to_string(),
        token.clone(),
        profile.platform.clone(),
    )
    .with_mdns(mdns_hostname.clone(), local_addr.port());
    let _guard = DiscoveryGuard::write_atomic(&paths.runtime_json, &discovery)?;

    let downloads = DownloadManager::new(supervisor.clone());
    let state = AppState {
        token,
        profile: profile.clone(),
        supervisor: supervisor.clone(),
        voices,
        batches: batches.clone(),
        downloads: downloads.clone(),
        http_base_url: http_base_url.clone(),
        mdns_hostname,
        mdns_base_url: mdns_base_url.clone(),
        active_lan_ip,
    };

    let app = Router::new()
        .route("/healthz", get(healthz))
        .route("/v1/models", get(list_models))
        .route("/v1/models/prewarm", post(prewarm_models_handler))
        .route("/v1/models/downloads", get(list_downloads_handler))
        .route("/v1/models/:id", delete(delete_model_handler))
        .route("/v1/models/:id/load", post(load_model_handler))
        .route("/v1/models/:id/unload", post(unload_model_handler))
        .route("/v1/models/:id/config", patch(update_model_config_handler))
        .route(
            "/v1/models/:id/download",
            get(get_download_handler).post(start_download_handler),
        )
        .route(
            "/v1/models/:id/download/cancel",
            post(cancel_download_handler),
        )
        .route("/v1/system/status", get(system_status))
        .route(
            "/v1/system/config",
            get(get_system_config_handler).patch(update_system_config_handler),
        )
        .route("/v1/system/failures", get(system_failures))
        .route("/v1/system/events", get(system_events))
        .route("/v1/system/unload-all", post(unload_all_handler))
        .route("/v1/chat/completions", post(chat_completions_handler))
        .route(
            "/v1/audio/transcriptions",
            post(audio_transcriptions_handler),
        )
        .route("/v1/audio/speech", post(audio_speech_handler))
        .route("/v1/audio/vad", post(audio_vad_handler))
        .route("/v1/audio/diarization", post(diarization_deferred_handler))
        .route(
            "/v1/audio/voices",
            get(list_voices_handler).post(create_voice_handler),
        )
        .route(
            "/v1/audio/voices/:id",
            get(get_voice_handler).delete(delete_voice_handler),
        )
        .route("/v1/audio/voices/:id/sample", get(get_voice_sample_handler))
        .route(
            "/v1/audio/speech/batches",
            get(list_speech_batches_handler).post(create_speech_batch_handler),
        )
        .route(
            "/v1/audio/speech/batches/:id",
            get(get_speech_batch_handler),
        )
        .route(
            "/v1/audio/speech/batches/:id/events",
            get(speech_batch_events_handler),
        )
        .route(
            "/v1/audio/speech/batches/:id/pause",
            post(pause_speech_batch_handler),
        )
        .route(
            "/v1/audio/speech/batches/:id/resume",
            post(resume_speech_batch_handler),
        )
        .route(
            "/v1/audio/speech/batches/:id/cancel",
            post(cancel_speech_batch_handler),
        )
        .layer(DefaultBodyLimit::max(128 * 1024 * 1024))
        .layer(middleware::from_fn_with_state(
            state.clone(),
            security_middleware,
        ))
        .with_state(state);

    let (shutdown_tx, mut shutdown_rx) = watch::channel(false);

    #[cfg(unix)]
    let uds_task = {
        let ipc_path = paths.native_ipc_path.clone();
        if ipc_path.as_os_str().len() >= 104 {
            warn!(
                path = %ipc_path.display(),
                "native IPC socket path exceeds 104-byte Unix sockaddr_un limit; skipping UDS listener"
            );
            None
        } else {
            if ipc_path.exists() {
                let _ = std::fs::remove_file(&ipc_path);
            }
            if let Some(parent) = ipc_path.parent() {
                std::fs::create_dir_all(parent)?;
            }
            let uds_listener = tokio::net::UnixListener::bind(&ipc_path)?;
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = std::fs::set_permissions(&ipc_path, std::fs::Permissions::from_mode(0o600));
            }
            let uds_app = app.clone();
            let mut uds_shutdown = shutdown_tx.subscribe();
            Some(tokio::spawn(async move {
                loop {
                    tokio::select! {
                        changed = uds_shutdown.changed() => {
                            if changed.is_err() || *uds_shutdown.borrow() {
                                break;
                            }
                        }
                        accept_res = uds_listener.accept() => {
                            match accept_res {
                                Ok((stream, _)) => {
                                    let svc = hyper_util::service::TowerToHyperService::new(uds_app.clone());
                                    let io = hyper_util::rt::TokioIo::new(stream);
                                    tokio::spawn(async move {
                                        let _ = hyper::server::conn::http1::Builder::new()
                                            .serve_connection(io, svc)
                                            .await;
                                    });
                                }
                                Err(err) => {
                                    warn!(error = %err, "UDS accept failed");
                                    break;
                                }
                            }
                        }
                    }
                }
            }))
        }
    };

    info!(
        platform = %profile.platform,
        http = %http_base_url,
        uds = %paths.native_ipc_path.display(),
        mdns_url = mdns_base_url.as_deref().unwrap_or("disabled"),
        headless = args.headless,
        "acpmd control plane started (Phase 1)"
    );

    let signal_tx = shutdown_tx.clone();
    tokio::spawn(async move {
        shutdown_signal().await;
        let _ = signal_tx.send(true);
    });

    axum::serve(tcp_listener, app)
        .with_graceful_shutdown(async move {
            while !*shutdown_rx.borrow() {
                if shutdown_rx.changed().await.is_err() {
                    break;
                }
            }
        })
        .await?;

    #[cfg(unix)]
    if let Some(handle) = uds_task {
        let _ = handle.await;
        let _ = std::fs::remove_file(&paths.native_ipc_path);
    }

    reaper_handle.abort();
    batches.cancel_all_active();
    downloads.cancel_all_active();
    supervisor.shutdown_all().await;
    if let Some(adv) = mdns_advertiser.as_mut() {
        adv.stop();
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_allowlist_accepts_loopback_mdns_and_lan_ip_only() {
        let lan = Some(Ipv4Addr::new(192, 168, 1, 50));
        assert!(is_allowed_local_host("127.0.0.1:18790", Some("acpm.local"), lan));
        assert!(is_allowed_local_host("localhost:18790", Some("acpm.local"), lan));
        assert!(is_allowed_local_host("[::1]:18790", Some("acpm.local"), lan));
        assert!(is_allowed_local_host("acpm.local:18790", Some("acpm.local"), lan));
        assert!(is_allowed_local_host("ACPM.LOCAL.:18790", Some("acpm.local"), lan));
        assert!(is_allowed_local_host("192.168.1.50:18790", Some("acpm.local"), lan));

        assert!(!is_allowed_local_host("evil.com:18790", Some("acpm.local"), lan));
        assert!(!is_allowed_local_host("acpm.local.evil.com:18790", Some("acpm.local"), lan));
        assert!(!is_allowed_local_host("192.168.1.51:18790", Some("acpm.local"), lan));
    }

    #[test]
    fn persists_and_reuses_auth_token_across_restarts() {
        let temp_dir = std::env::temp_dir().join(format!("acpmd-token-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&temp_dir).unwrap();
        let first = load_or_create_token(&temp_dir, None).unwrap();
        let second = load_or_create_token(&temp_dir, None).unwrap();
        assert_eq!(first, second);
        assert_eq!(first.len(), 64);

        let override_tok = load_or_create_token(&temp_dir, Some("custom-token".to_string())).unwrap();
        assert_eq!(override_tok, "custom-token");
        let _ = std::fs::remove_dir_all(&temp_dir);
    }
}
