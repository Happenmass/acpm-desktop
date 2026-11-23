mod audio;
mod pyannote_vad;
mod runtime_lib;

use acpm_pal::default_telemetry;
use acpm_protocol::{
    ApiError, ApiErrorEnvelope, ErrorCode, FailureStage, ResourceVector, TimingMetrics, VadRequest,
    VadResponse, WorkerCommand, WorkerFrame, WorkerState, FRAME_PREFIX,
};
use chrono::Utc;
use clap::Parser;
use pyannote_vad::PyannoteVad;
use runtime_lib::resolve_model_file;
use std::collections::HashMap;
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::watch;
use uuid::Uuid;

#[derive(Debug, Parser)]
#[command(name = "acpm-worker-speech", version)]
struct Args {
    #[arg(long, default_value = "speech")]
    mode: String,

    #[arg(long)]
    model_id: String,

    #[arg(long)]
    model_dir: Option<PathBuf>,

    #[arg(long)]
    ipc_path: Option<String>,

    #[arg(long, default_value = "ACPM_WORKER_TOKEN")]
    auth_token_env: String,

    #[arg(long, default_value_t = 512)]
    memory_limit_mb: u64,

    #[arg(long, default_value_t = 2)]
    threads: usize,

    #[arg(long, default_value_t = false)]
    probe: bool,
}

struct SpeechState {
    model_id: String,
    token: String,
    vad: Option<Arc<PyannoteVad>>,
    shutdown_tx: watch::Sender<bool>,
}

fn emit_frame(frame: &WorkerFrame) {
    if let Ok(json) = serde_json::to_string(frame) {
        let mut out = io::stdout().lock();
        let _ = writeln!(out, "{FRAME_PREFIX}{json}");
        let _ = out.flush();
    }
}

fn current_process_memory() -> ResourceVector {
    default_telemetry()
        .process_memory(std::process::id())
        .unwrap_or_else(|_| ResourceVector::system_and_gpu(140, 0, 0))
}

#[tokio::main]
async fn main() {
    let args = Args::parse();
    emit_frame(&WorkerFrame::State {
        state: WorkerState::Starting,
        ts_ms: Utc::now().timestamp_millis(),
        model_load_ms: None,
        memory: None,
        ipc_endpoint: args.ipc_path.clone(),
    });

    if args.probe {
        emit_frame(&WorkerFrame::State {
            state: WorkerState::Warm,
            ts_ms: Utc::now().timestamp_millis(),
            model_load_ms: Some(0.0),
            memory: Some(current_process_memory()),
            ipc_endpoint: args.ipc_path,
        });
        return;
    }

    let Some(ref model_dir) = args.model_dir else {
        emit_frame(&WorkerFrame::Error {
            stage: FailureStage::WorkerStart,
            detail: "MISSING_MODEL_DIR".to_string(),
            native_code: None,
            fatal: true,
        });
        std::process::exit(2);
    };

    emit_frame(&WorkerFrame::State {
        state: WorkerState::Loading,
        ts_ms: Utc::now().timestamp_millis(),
        model_load_ms: None,
        memory: None,
        ipc_endpoint: args.ipc_path.clone(),
    });

    let load_start = Instant::now();
    let threads = args.threads.clamp(1, 8);

    let seg_model = resolve_model_file(model_dir, &["segmentation.onnx", "model.onnx"]);
    let Some(seg_path) = seg_model else {
        emit_frame(&WorkerFrame::Error {
            stage: FailureStage::ModelLoad,
            detail: format!("MISSING_SEGMENTATION_ONNX in {}", model_dir.display()),
            native_code: None,
            fatal: true,
        });
        std::process::exit(3);
    };

    let vad = match PyannoteVad::load(&seg_path, threads) {
        Ok(v) => Some(Arc::new(v)),
        Err(err) => {
            emit_frame(&WorkerFrame::Error {
                stage: FailureStage::ModelLoad,
                detail: err,
                native_code: None,
                fatal: true,
            });
            std::process::exit(4);
        }
    };

    let model_load_ms = load_start.elapsed().as_secs_f64() * 1000.0;
    let token = std::env::var(&args.auth_token_env)
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "acpm-local-dev-token".to_string());

    let (shutdown_tx, mut shutdown_rx) = watch::channel(false);
    let state = Arc::new(SpeechState {
        model_id: args.model_id.clone(),
        token,
        vad,
        shutdown_tx: shutdown_tx.clone(),
    });

    #[cfg(unix)]
    let ipc_task = if let Some(ref raw_ipc) = args.ipc_path {
        let sock_path = PathBuf::from(raw_ipc);
        if sock_path.exists() {
            let _ = std::fs::remove_file(&sock_path);
        }
        if let Some(parent) = sock_path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        match tokio::net::UnixListener::bind(&sock_path) {
            Ok(listener) => {
                use std::os::unix::fs::PermissionsExt;
                let _ = std::fs::set_permissions(&sock_path, std::fs::Permissions::from_mode(0o600));
                let st = Arc::clone(&state);
                let mut sd = shutdown_tx.subscribe();
                let sp = sock_path.clone();
                Some((
                    sock_path,
                    tokio::spawn(async move {
                        loop {
                            tokio::select! {
                                changed = sd.changed() => {
                                    if changed.is_err() || *sd.borrow() {
                                        break;
                                    }
                                }
                                accepted = listener.accept() => {
                                    match accepted {
                                        Ok((stream, _)) => {
                                            let st_conn = Arc::clone(&st);
                                            tokio::spawn(async move {
                                                handle_connection(stream, st_conn).await;
                                            });
                                        }
                                        Err(_) => break,
                                    }
                                }
                            }
                        }
                        let _ = std::fs::remove_file(&sp);
                    }),
                ))
            }
            Err(err) => {
                emit_frame(&WorkerFrame::Error {
                    stage: FailureStage::WorkerStart,
                    detail: format!("UDS_BIND_FAILED: {err}"),
                    native_code: None,
                    fatal: true,
                });
                std::process::exit(6);
            }
        }
    } else {
        None
    };

    emit_frame(&WorkerFrame::State {
        state: WorkerState::Warm,
        ts_ms: Utc::now().timestamp_millis(),
        model_load_ms: Some(model_load_ms),
        memory: Some(current_process_memory()),
        ipc_endpoint: args.ipc_path.clone(),
    });

    // Parent death / EOF self-termination + stdin control reader.
    let stdin_shutdown = shutdown_tx.clone();
    std::thread::spawn(move || {
        let stdin = io::stdin();
        for line in stdin.lock().lines() {
            let Ok(raw) = line else {
                break;
            };
            let trimmed = raw.trim();
            if trimmed.is_empty() {
                continue;
            }
            if let Ok(cmd) = serde_json::from_str::<WorkerCommand>(trimmed) {
                match cmd {
                    WorkerCommand::Shutdown => {
                        let _ = stdin_shutdown.send(true);
                        return;
                    }
                    WorkerCommand::TrimCache => {}
                }
            }
        }
        let _ = stdin_shutdown.send(true);
    });

    #[cfg(unix)]
    {
        let sig_shutdown = shutdown_tx.clone();
        tokio::spawn(async move {
            let mut sigterm =
                tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).ok();
            let sigint = tokio::signal::ctrl_c();
            tokio::select! {
                _ = sigint => {}
                _ = async {
                    if let Some(ref mut s) = sigterm {
                        s.recv().await;
                    } else {
                        std::future::pending::<()>().await;
                    }
                } => {}
            }
            let _ = sig_shutdown.send(true);
        });
    }

    while !*shutdown_rx.borrow() {
        if shutdown_rx.changed().await.is_err() {
            break;
        }
    }

    emit_frame(&WorkerFrame::State {
        state: WorkerState::Unloading,
        ts_ms: Utc::now().timestamp_millis(),
        model_load_ms: None,
        memory: None,
        ipc_endpoint: None,
    });

    #[cfg(unix)]
    if let Some((sock_path, handle)) = ipc_task {
        let _ = handle.await;
        let _ = std::fs::remove_file(sock_path);
    }
}

struct ParsedHttp {
    method: String,
    path: String,
    headers: HashMap<String, String>,
    body: Vec<u8>,
}

async fn read_http_request<S: AsyncRead + Unpin>(stream: &mut S) -> Option<ParsedHttp> {
    let mut buf = Vec::with_capacity(4096);
    let mut chunk = [0u8; 8192];
    let header_end;
    loop {
        let n = stream.read(&mut chunk).await.ok()?;
        if n == 0 {
            return None;
        }
        buf.extend_from_slice(&chunk[..n]);
        if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            header_end = pos;
            break;
        }
        if buf.len() > 64 * 1024 {
            return None;
        }
    }

    let head_str = std::str::from_utf8(&buf[..header_end]).ok()?;
    let mut lines = head_str.split("\r\n");
    let req_line = lines.next()?;
    let mut parts = req_line.split_whitespace();
    let method = parts.next()?.to_ascii_uppercase();
    let path = parts
        .next()?
        .split('?')
        .next()
        .unwrap_or("/")
        .to_string();

    let mut headers = HashMap::new();
    for line in lines {
        if let Some((k, v)) = line.split_once(':') {
            headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
        }
    }

    let content_len = headers
        .get("content-length")
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(0);
    if content_len > 32 * 1024 * 1024 {
        return None;
    }

    let mut body = buf[header_end + 4..].to_vec();
    while body.len() < content_len {
        let n = stream.read(&mut chunk).await.ok()?;
        if n == 0 {
            break;
        }
        body.extend_from_slice(&chunk[..n]);
    }
    body.truncate(content_len);

    Some(ParsedHttp {
        method,
        path,
        headers,
        body,
    })
}

async fn write_json_response<S: AsyncWrite + Unpin>(
    stream: &mut S,
    status: u16,
    body: &[u8],
    request_id: &str,
) {
    let reason = match status {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        422 => "Unprocessable Entity",
        424 => "Failed Dependency",
        501 => "Not Implemented",
        503 => "Service Unavailable",
        _ => "Internal Server Error",
    };
    let head = format!(
        "HTTP/1.1 {status} {reason}\r\n\
         Content-Type: application/json; charset=utf-8\r\n\
         Content-Length: {}\r\n\
         X-AI-Request-Id: {request_id}\r\n\
         Connection: close\r\n\r\n",
        body.len()
    );
    let _ = stream.write_all(head.as_bytes()).await;
    let _ = stream.write_all(body).await;
    let _ = stream.flush().await;
}

async fn write_api_error<S: AsyncWrite + Unpin>(
    stream: &mut S,
    code: ErrorCode,
    stage: FailureStage,
    detail: &str,
    message: &str,
    request_id: &str,
) {
    let env = ApiErrorEnvelope {
        error: ApiError::new(code, stage, detail, message, request_id),
    };
    let bytes = serde_json::to_vec(&env).unwrap_or_default();
    write_json_response(stream, code.http_status(), &bytes, request_id).await;
}

async fn handle_connection<S: AsyncRead + AsyncWrite + Unpin>(
    mut stream: S,
    state: Arc<SpeechState>,
) {
    let Some(req) = read_http_request(&mut stream).await else {
        return;
    };
    let request_id = req
        .headers
        .get("x-ai-request-id")
        .filter(|s| !s.is_empty())
        .cloned()
        .unwrap_or_else(|| Uuid::new_v4().to_string());

    if !(req.method == "GET" && (req.path == "/health" || req.path == "/healthz")) {
        let worker_tok = req
            .headers
            .get("x-worker-token")
            .map(String::as_str)
            .unwrap_or("");
        let bearer_ok = req
            .headers
            .get("authorization")
            .map(|v| v == &format!("Bearer {}", state.token))
            .unwrap_or(false);
        if worker_tok != state.token && !bearer_ok {
            write_api_error(
                &mut stream,
                ErrorCode::Unauthorized,
                FailureStage::HttpAdmission,
                "INVALID_OR_MISSING_TOKEN",
                "Missing or invalid X-Worker-Token.",
                &request_id,
            )
            .await;
            return;
        }
    }

    match (req.method.as_str(), req.path.as_str()) {
        ("GET", "/health") | ("GET", "/healthz") => {
            let payload = serde_json::json!({
                "status": "ok",
                "state": "WARM",
                "model_id": state.model_id,
                "capabilities": {
                    "vad": state.vad.is_some(),
                    "diarization": false,
                },
                "memory": current_process_memory(),
            });
            let bytes = serde_json::to_vec(&payload).unwrap();
            write_json_response(&mut stream, 200, &bytes, &request_id).await;
        }
        ("POST", "/infer/vad") => {
            let parsed: VadRequest = match serde_json::from_slice(&req.body) {
                Ok(r) => r,
                Err(e) => {
                    write_api_error(
                        &mut stream,
                        ErrorCode::InvalidRequest,
                        FailureStage::HttpAdmission,
                        "INVALID_VAD_REQUEST",
                        &format!("Invalid /infer/vad JSON: {e}"),
                        &request_id,
                    )
                    .await;
                    return;
                }
            };
            let Some(vad) = state.vad.clone() else {
                write_api_error(
                    &mut stream,
                    ErrorCode::ModelNotInstalled,
                    FailureStage::ModelPrepare,
                    "VAD_MODEL_NOT_LOADED",
                    "Pyannote VAD model is not loaded.",
                    &request_id,
                )
                .await;
                return;
            };

            let file_path = PathBuf::from(&parsed.file_path);
            let min_speech_ms = parsed.min_speech_ms.unwrap_or(250);
            let min_silence_ms = parsed.min_silence_ms.unwrap_or(500);
            let started = Instant::now();

            let res = tokio::task::spawn_blocking(move || -> Result<VadResponse, String> {
                let (samples, duration_ms) = audio::load_audio_16k_mono(&file_path)?;
                let segments = vad.detect(&samples, duration_ms, min_speech_ms, min_silence_ms)?;
                Ok(VadResponse {
                    segments,
                    duration_ms,
                    x_acpm_timing: Some(TimingMetrics {
                        queue_ms: 0.0,
                        model_load_ms: None,
                        prefill_ms: None,
                        decode_ms: started.elapsed().as_secs_f64() * 1000.0,
                        kv_cache_hit: None,
                        voice_cache_hit: None,
                    }),
                })
            })
            .await;

            match res {
                Ok(Ok(resp)) => {
                    let bytes = serde_json::to_vec(&resp).unwrap();
                    write_json_response(&mut stream, 200, &bytes, &request_id).await;
                }
                Ok(Err(msg)) => {
                    let code = if Path::new(&parsed.file_path).is_file() {
                        ErrorCode::InferenceFailed
                    } else {
                        ErrorCode::AudioValidationFailed
                    };
                    write_api_error(
                        &mut stream,
                        code,
                        FailureStage::Inference,
                        "VAD_FAILED",
                        &msg,
                        &request_id,
                    )
                    .await;
                }
                Err(e) => {
                    write_api_error(
                        &mut stream,
                        ErrorCode::InferenceFailed,
                        FailureStage::Inference,
                        "VAD_JOIN_ERROR",
                        &e.to_string(),
                        &request_id,
                    )
                    .await;
                }
            }
        }
        ("POST", "/infer/diarize") => {
            write_api_error(
                &mut stream,
                ErrorCode::NotImplemented,
                FailureStage::HttpAdmission,
                "DIARIZATION_DEFERRED",
                "Speaker diarization is deferred in the current phase; only VAD is enabled.",
                &request_id,
            )
            .await;
        }
        ("POST", "/cache/clear") => {
            let bytes = br#"{"status":"ok"}"#;
            write_json_response(&mut stream, 200, bytes, &request_id).await;
        }
        ("POST", "/shutdown") => {
            let bytes = br#"{"status":"shutting_down"}"#;
            write_json_response(&mut stream, 200, bytes, &request_id).await;
            let _ = state.shutdown_tx.send(true);
        }
        _ => {
            write_api_error(
                &mut stream,
                ErrorCode::NotFound,
                FailureStage::HttpAdmission,
                "ROUTE_NOT_FOUND",
                &format!("Unknown endpoint {} {}", req.method, req.path),
                &request_id,
            )
            .await;
        }
    }
}
