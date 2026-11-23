use crate::supervisor::{RequestContext, RuntimeSupervisor, SpeechOutput};
use crate::voices::VoiceStore;
use acpm_protocol::{
    ApiError, Capability, CreateSpeechBatchRequest, ErrorCode, FailureStage, Priority,
    SpeechBatchItemState, SpeechBatchItemStatus, SpeechBatchState, SpeechBatchStatus,
    SpeechRequest, ThermalState,
};
use chrono::Utc;
use std::collections::BTreeMap;
use std::path::{Component, Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{broadcast, watch};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BatchControlSignal {
    Run,
    Pause,
    Cancel,
}

#[derive(Debug, Clone)]
pub struct BatchConfig {
    pub thermal_serious_cooldown: Duration,
    pub thermal_critical_poll: Duration,
}

impl Default for BatchConfig {
    fn default() -> Self {
        Self {
            thermal_serious_cooldown: Duration::from_millis(500),
            thermal_critical_poll: Duration::from_secs(1),
        }
    }
}

#[derive(Debug, Clone)]
pub enum BatchError {
    InvalidRequest { code: &'static str, message: String },
    InvalidAudio { code: &'static str, message: String },
    NotFound { message: String },
    Conflict { code: &'static str, message: String },
}

impl BatchError {
    pub fn into_api_error(self, request_id: &str) -> ApiError {
        match self {
            Self::InvalidRequest { code, message } => ApiError::new(
                ErrorCode::InvalidRequest,
                FailureStage::HttpAdmission,
                code,
                message,
                request_id,
            ),
            Self::InvalidAudio { code, message } => ApiError::new(
                ErrorCode::AudioValidationFailed,
                FailureStage::AudioValidation,
                code,
                message,
                request_id,
            ),
            Self::NotFound { message } => ApiError::new(
                ErrorCode::NotFound,
                FailureStage::HttpAdmission,
                "SPEECH_BATCH_NOT_FOUND",
                message,
                request_id,
            ),
            Self::Conflict { code, message } => ApiError::new(
                ErrorCode::InvalidRequest,
                FailureStage::HttpAdmission,
                code,
                message,
                request_id,
            ),
        }
    }
}

struct BatchEntry {
    supervisor: RuntimeSupervisor,
    state: Mutex<SpeechBatchState>,
    signal_tx: watch::Sender<BatchControlSignal>,
    events_tx: broadcast::Sender<SpeechBatchState>,
}

impl BatchEntry {
    fn snapshot(&self) -> SpeechBatchState {
        self.state.lock().unwrap().clone()
    }

    fn update_and_publish<F>(&self, f: F) -> SpeechBatchState
    where
        F: FnOnce(&mut SpeechBatchState),
    {
        let snapshot = {
            let mut st = self.state.lock().unwrap();
            f(&mut st);
            st.updated_at = Utc::now().to_rfc3339();
            st.clone()
        };
        let _ = self.events_tx.send(snapshot.clone());
        self.supervisor.emit_batch_progress(&snapshot);
        snapshot
    }
}

#[derive(Clone)]
pub struct BatchManager {
    supervisor: RuntimeSupervisor,
    voices: VoiceStore,
    config: BatchConfig,
    batches: Arc<Mutex<BTreeMap<String, Arc<BatchEntry>>>>,
}

impl BatchManager {
    pub fn new(supervisor: RuntimeSupervisor, voices: VoiceStore) -> Self {
        Self::with_config(supervisor, voices, BatchConfig::default())
    }

    pub fn with_config(
        supervisor: RuntimeSupervisor,
        voices: VoiceStore,
        config: BatchConfig,
    ) -> Self {
        Self {
            supervisor,
            voices,
            config,
            batches: Arc::new(Mutex::new(BTreeMap::new())),
        }
    }

    pub fn create_batch(
        &self,
        req: CreateSpeechBatchRequest,
        caller: String,
    ) -> Result<SpeechBatchState, BatchError> {
        if req.model.trim().is_empty() {
            return Err(BatchError::InvalidRequest {
                code: "MISSING_MODEL",
                message: "model must not be empty.".to_string(),
            });
        }
        let model_status = self
            .supervisor
            .list_models_status()
            .into_iter()
            .find(|m| m.id == req.model);
        if let Some(ref m) = model_status {
            if m.capability != Capability::Tts {
                return Err(BatchError::InvalidRequest {
                    code: "CAPABILITY_MISMATCH",
                    message: format!("Model '{}' is not a TTS model.", req.model),
                });
            }
        } else {
            return Err(BatchError::InvalidRequest {
                code: "UNKNOWN_MODEL",
                message: format!("Unknown model '{}'.", req.model),
            });
        }

        if req.items.is_empty() {
            return Err(BatchError::InvalidRequest {
                code: "EMPTY_BATCH_ITEMS",
                message: "items must not be empty.".to_string(),
            });
        }

        let output_dir_str = req.output_dir.trim();
        if output_dir_str.is_empty() {
            return Err(BatchError::InvalidRequest {
                code: "INVALID_OUTPUT_DIR",
                message: "output_dir must not be empty.".to_string(),
            });
        }
        let output_dir = PathBuf::from(output_dir_str);
        std::fs::create_dir_all(&output_dir).map_err(|e| BatchError::InvalidRequest {
            code: "UNWRITABLE_OUTPUT_DIR",
            message: format!("Cannot create output_dir '{}': {e}", output_dir.display()),
        })?;

        let resolved_voice = self
            .voices
            .resolve_for_speech(
                req.voice.clone(),
                req.reference_audio.clone(),
                req.reference_text.clone(),
            )
            .map_err(|e| match e {
                crate::voices::VoiceStoreError::InvalidAudio { code, message } => {
                    BatchError::InvalidAudio { code, message }
                }
                other => BatchError::InvalidRequest {
                    code: "INVALID_VOICE_REFERENCE",
                    message: format!("{other:?}"),
                },
            })?;

        let mut planned_items = Vec::with_capacity(req.items.len());
        let mut status_items = Vec::with_capacity(req.items.len());
        for item in &req.items {
            if item.id.trim().is_empty() {
                return Err(BatchError::InvalidRequest {
                    code: "EMPTY_ITEM_ID",
                    message: "Each batch item must specify a non-empty id.".to_string(),
                });
            }
            if item.text.trim().is_empty() {
                return Err(BatchError::InvalidRequest {
                    code: "EMPTY_ITEM_TEXT",
                    message: format!("Batch item '{}' has empty text.", item.id),
                });
            }
            let safe_rel = validate_relative_output_file(&item.output_file)?;
            let out_path = output_dir.join(&safe_rel);
            let out_str = out_path.to_string_lossy().into_owned();
            planned_items.push((
                item.id.clone(),
                item.text.clone(),
                item.instruct.clone().or_else(|| req.instruct.clone()),
                out_str.clone(),
            ));
            status_items.push(SpeechBatchItemStatus {
                id: item.id.clone(),
                output_path: out_str,
                status: SpeechBatchItemState::Pending,
                bytes: None,
                duration_ms: None,
                voice_cache_hit: None,
                error: None,
            });
        }

        let batch_id = format!("sb_{}", &Uuid::new_v4().simple().to_string()[..12]);
        let now = Utc::now().to_rfc3339();
        let initial_state = SpeechBatchState {
            batch_id: batch_id.clone(),
            model: req.model.clone(),
            status: SpeechBatchStatus::Queued,
            total: planned_items.len(),
            completed: 0,
            failed: 0,
            created_at: now.clone(),
            updated_at: now,
            items: status_items,
        };

        let (signal_tx, signal_rx) = watch::channel(BatchControlSignal::Run);
        let (events_tx, _) = broadcast::channel(128);
        let entry = Arc::new(BatchEntry {
            supervisor: self.supervisor.clone(),
            state: Mutex::new(initial_state.clone()),
            signal_tx,
            events_tx,
        });
        self.batches
            .lock()
            .unwrap()
            .insert(batch_id.clone(), Arc::clone(&entry));

        let manager = self.clone();
        let model = req.model;
        let speed = req.speed;
        let x_vector_only_mode = req.x_vector_only_mode;
        tokio::spawn(async move {
            manager
                .run_batch_loop(
                    batch_id,
                    model,
                    resolved_voice.voice,
                    resolved_voice.reference_audio,
                    resolved_voice.reference_text,
                    x_vector_only_mode,
                    speed,
                    caller,
                    planned_items,
                    entry,
                    signal_rx,
                )
                .await;
        });

        Ok(initial_state)
    }

    #[allow(clippy::too_many_arguments)]
    async fn run_batch_loop(
        self,
        batch_id: String,
        model: String,
        voice: Option<String>,
        reference_audio: Option<String>,
        reference_text: Option<String>,
        x_vector_only_mode: bool,
        speed: Option<f32>,
        caller: String,
        planned_items: Vec<(String, String, Option<String>, String)>,
        entry: Arc<BatchEntry>,
        mut signal_rx: watch::Receiver<BatchControlSignal>,
    ) {
        let mut cancelled = false;

        for (idx, (item_id, text, instruct, out_path)) in planned_items.into_iter().enumerate() {
            // Respect Pause / Cancel before touching GPU slot for the next sentence.
            loop {
                let sig = *signal_rx.borrow();
                match sig {
                    BatchControlSignal::Run => break,
                    BatchControlSignal::Cancel => {
                        cancelled = true;
                        break;
                    }
                    BatchControlSignal::Pause => {
                        entry.update_and_publish(|st| {
                            st.status = SpeechBatchStatus::Paused;
                        });
                        if signal_rx.changed().await.is_err() {
                            cancelled = true;
                            break;
                        }
                    }
                }
            }
            if cancelled {
                break;
            }

            // Thermal protection check for background batch synthesis.
            loop {
                match self.supervisor.system_status().thermal_state {
                    ThermalState::Critical => {
                        tokio::select! {
                            _ = tokio::time::sleep(self.config.thermal_critical_poll) => {}
                            res = signal_rx.changed() => {
                                if res.is_err() || *signal_rx.borrow() == BatchControlSignal::Cancel {
                                    cancelled = true;
                                    break;
                                }
                            }
                        }
                    }
                    ThermalState::Serious if !self.config.thermal_serious_cooldown.is_zero() => {
                        tokio::select! {
                            _ = tokio::time::sleep(self.config.thermal_serious_cooldown) => {}
                            res = signal_rx.changed() => {
                                if res.is_err() || *signal_rx.borrow() == BatchControlSignal::Cancel {
                                    cancelled = true;
                                    break;
                                }
                            }
                        }
                        break;
                    }
                    _ => break,
                }
            }
            if cancelled || *signal_rx.borrow() == BatchControlSignal::Cancel {
                cancelled = true;
                break;
            }

            entry.update_and_publish(|st| {
                st.status = SpeechBatchStatus::Running;
                if let Some(it) = st.items.get_mut(idx) {
                    it.status = SpeechBatchItemState::Running;
                }
            });

            let speech_req = SpeechRequest {
                model: model.clone(),
                input: text,
                voice: voice.clone(),
                instruct,
                reference_audio: reference_audio.clone(),
                reference_text: reference_text.clone(),
                x_vector_only_mode,
                speed,
                response_format: Some("wav".to_string()),
                output_path: Some(out_path.clone()),
            };
            let ctx = RequestContext {
                request_id: format!("{batch_id}-{item_id}"),
                caller: caller.clone(),
                priority: Priority::Batch,
            };

            let res = self.supervisor.synthesize(speech_req, ctx).await;

            entry.update_and_publish(|st| {
                if let Some(it) = st.items.get_mut(idx) {
                    match &res {
                        Ok(SpeechOutput::File(file_resp)) => {
                            it.status = SpeechBatchItemState::Completed;
                            it.bytes = Some(file_resp.bytes);
                            it.duration_ms = Some(file_resp.duration_ms);
                            it.voice_cache_hit = Some(file_resp.voice_cache_hit);
                            st.completed += 1;
                        }
                        Ok(SpeechOutput::AudioBytes { wav, duration_ms, voice_cache_hit, .. }) => {
                            let bytes = wav.len() as u64;
                            it.status = SpeechBatchItemState::Completed;
                            it.bytes = Some(bytes);
                            it.duration_ms = Some(*duration_ms);
                            it.voice_cache_hit = Some(*voice_cache_hit);
                            st.completed += 1;
                        }
                        Err(err) => {
                            it.status = SpeechBatchItemState::Failed;
                            it.error = Some(err.message.clone());
                            st.failed += 1;
                        }
                    }
                }
            });

            // Yield right after releasing the per-sentence GPU slot and worker lease so any
            // waiting Interactive request (e.g. Yanmo IME) immediately preempts the next sentence.
            tokio::task::yield_now().await;
        }

        entry.update_and_publish(|st| {
            if cancelled || *signal_rx.borrow() == BatchControlSignal::Cancel {
                st.status = SpeechBatchStatus::Cancelled;
                for it in &mut st.items {
                    if matches!(it.status, SpeechBatchItemState::Pending | SpeechBatchItemState::Running)
                    {
                        it.status = SpeechBatchItemState::Cancelled;
                    }
                }
            } else if st.failed > 0 {
                st.status = SpeechBatchStatus::CompletedWithErrors;
            } else {
                st.status = SpeechBatchStatus::Completed;
            }
        });
    }

    pub fn list_batches(&self) -> Vec<SpeechBatchState> {
        let mut out: Vec<SpeechBatchState> = self
            .batches
            .lock()
            .unwrap()
            .values()
            .map(|entry| entry.snapshot())
            .collect();
        out.sort_by(|a, b| {
            b.created_at
                .cmp(&a.created_at)
                .then_with(|| a.batch_id.cmp(&b.batch_id))
        });
        out
    }

    pub fn get_batch(&self, batch_id: &str) -> Option<SpeechBatchState> {
        self.batches
            .lock()
            .unwrap()
            .get(batch_id)
            .map(|entry| entry.snapshot())
    }

    pub fn subscribe_batch(
        &self,
        batch_id: &str,
    ) -> Option<(SpeechBatchState, broadcast::Receiver<SpeechBatchState>)> {
        let map = self.batches.lock().unwrap();
        let entry = map.get(batch_id)?;
        Some((entry.snapshot(), entry.events_tx.subscribe()))
    }

    pub fn pause_batch(&self, batch_id: &str) -> Result<SpeechBatchState, BatchError> {
        let entry = self
            .batches
            .lock()
            .unwrap()
            .get(batch_id)
            .cloned()
            .ok_or_else(|| BatchError::NotFound {
                message: format!("Speech batch '{batch_id}' not found."),
            })?;
        let current = entry.snapshot();
        if matches!(
            current.status,
            SpeechBatchStatus::Completed
                | SpeechBatchStatus::CompletedWithErrors
                | SpeechBatchStatus::Cancelled
        ) {
            return Err(BatchError::Conflict {
                code: "BATCH_ALREADY_TERMINAL",
                message: format!("Batch '{batch_id}' is already finished."),
            });
        }
        let _ = entry.signal_tx.send(BatchControlSignal::Pause);
        Ok(entry.update_and_publish(|st| {
            st.status = SpeechBatchStatus::Paused;
        }))
    }

    pub fn resume_batch(&self, batch_id: &str) -> Result<SpeechBatchState, BatchError> {
        let entry = self
            .batches
            .lock()
            .unwrap()
            .get(batch_id)
            .cloned()
            .ok_or_else(|| BatchError::NotFound {
                message: format!("Speech batch '{batch_id}' not found."),
            })?;
        let current = entry.snapshot();
        if matches!(
            current.status,
            SpeechBatchStatus::Completed
                | SpeechBatchStatus::CompletedWithErrors
                | SpeechBatchStatus::Cancelled
        ) {
            return Err(BatchError::Conflict {
                code: "BATCH_ALREADY_TERMINAL",
                message: format!("Batch '{batch_id}' is already finished."),
            });
        }
        let _ = entry.signal_tx.send(BatchControlSignal::Run);
        Ok(entry.update_and_publish(|st| {
            if st.status == SpeechBatchStatus::Paused {
                st.status = SpeechBatchStatus::Running;
            }
        }))
    }

    pub fn cancel_batch(&self, batch_id: &str) -> Result<SpeechBatchState, BatchError> {
        let entry = self
            .batches
            .lock()
            .unwrap()
            .get(batch_id)
            .cloned()
            .ok_or_else(|| BatchError::NotFound {
                message: format!("Speech batch '{batch_id}' not found."),
            })?;
        let current = entry.snapshot();
        if matches!(
            current.status,
            SpeechBatchStatus::Completed
                | SpeechBatchStatus::CompletedWithErrors
                | SpeechBatchStatus::Cancelled
        ) {
            return Ok(current);
        }
        let _ = entry.signal_tx.send(BatchControlSignal::Cancel);
        Ok(entry.update_and_publish(|st| {
            st.status = SpeechBatchStatus::Cancelled;
            for it in &mut st.items {
                if it.status == SpeechBatchItemState::Pending {
                    it.status = SpeechBatchItemState::Cancelled;
                }
            }
        }))
    }

    pub fn cancel_all_active(&self) {
        let entries: Vec<Arc<BatchEntry>> = self.batches.lock().unwrap().values().cloned().collect();
        for entry in entries {
            let current = entry.snapshot();
            if !matches!(
                current.status,
                SpeechBatchStatus::Completed
                    | SpeechBatchStatus::CompletedWithErrors
                    | SpeechBatchStatus::Cancelled
            ) {
                let _ = entry.signal_tx.send(BatchControlSignal::Cancel);
            }
        }
    }
}

fn validate_relative_output_file(raw: &str) -> Result<PathBuf, BatchError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(BatchError::InvalidRequest {
            code: "INVALID_OUTPUT_FILE",
            message: "output_file must not be empty.".to_string(),
        });
    }
    let path = Path::new(trimmed);
    if path.is_absolute() {
        return Err(BatchError::InvalidRequest {
            code: "ABSOLUTE_OUTPUT_FILE_FORBIDDEN",
            message: format!("output_file '{trimmed}' must be relative to output_dir."),
        });
    }
    let mut clean = PathBuf::new();
    for comp in path.components() {
        match comp {
            Component::Normal(part) => clean.push(part),
            Component::CurDir => {}
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => {
                return Err(BatchError::InvalidRequest {
                    code: "PATH_TRAVERSAL_FORBIDDEN",
                    message: format!("output_file '{trimmed}' must not escape output_dir."),
                });
            }
        }
    }
    if clean.as_os_str().is_empty() {
        return Err(BatchError::InvalidRequest {
            code: "INVALID_OUTPUT_FILE",
            message: format!("output_file '{trimmed}' resolved to empty path."),
        });
    }
    Ok(clean)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::ModelOverrideConfig;
    use crate::diagnostics::DiagnosticsStore;
    use crate::supervisor::SupervisorConfig;
    use acpm_pal::mock::MockTelemetry;
    use acpm_pal::{RuntimePaths, SystemTelemetry};
    use acpm_protocol::{BudgetTier, ChatCompletionRequest, ChatMessage, SpeechBatchItemInput};
    use acpm_registry::ModelRegistry;

    fn write_http_mock_worker(dir: &Path, event_log: &Path) -> PathBuf {
        let script = dir.join("http_mock_worker.py");
        let code = format!(
            r#"#!/usr/bin/env python3
import json, os, signal, socket, sys, threading, time

args = sys.argv[1:]
def arg_val(flag, default=""):
    if flag in args:
        idx = args.index(flag)
        if idx + 1 < len(args):
            return args[idx + 1]
    return default

mode = arg_val("--mode", "llm")
model_id = arg_val("--model-id", "unknown")
ipc_path = arg_val("--ipc-path")
event_log = {event_log:?}
stop_event = threading.Event()
log_lock = threading.Lock()

def log_event(obj):
    with log_lock:
        with open(event_log, "a", encoding="utf-8") as f:
            f.write(json.dumps(obj) + "\n")

def emit(obj):
    sys.stdout.write("ACPM_FRAME\t" + json.dumps(obj) + "\n")
    sys.stdout.flush()

emit({{"type": "state", "state": "STARTING", "ts_ms": 1}})
emit({{"type": "state", "state": "LOADING", "ts_ms": 2}})
if os.path.exists(ipc_path):
    os.remove(ipc_path)
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(ipc_path)
srv.listen(16)
srv.settimeout(0.1)
emit({{"type": "state", "state": "WARM", "ts_ms": 3, "model_load_ms": 5.0, "memory": {{"unified_mb": 3250 if mode == "tts" else 5265}}}})

def make_wav_bytes():
    import struct
    sr = 24000
    n = 2400
    data = b"\x00\x00" * n
    hdr = struct.pack("<4sI4s4sIHHIIHH4sI", b"RIFF", 36 + len(data), b"WAVE", b"fmt ", 16, 1, 1, sr, sr*2, 2, 16, b"data", len(data))
    return hdr + data

def handle_conn(conn):
    try:
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = conn.recv(4096)
            if not chunk:
                return
            buf += chunk
        head, rest = buf.split(b"\r\n\r\n", 1)
        head_str = head.decode("utf-8", errors="replace")
        lines = head_str.split("\r\n")
        method, path, *_ = lines[0].split(" ")
        clen = 0
        for line in lines[1:]:
            if line.lower().startswith("content-length:"):
                clen = int(line.split(":", 1)[1].strip())
        while len(rest) < clen:
            chunk = conn.recv(4096)
            if not chunk:
                break
            rest += chunk
        body = rest[:clen]

        if path == "/infer/tts":
            payload = json.loads(body.decode("utf-8"))
            log_event({{"ts": time.time(), "op": "tts_start", "model": model_id, "input": payload.get("input")}})
            time.sleep(0.12)
            out_path = payload.get("output_path")
            wav = make_wav_bytes()
            if out_path:
                os.makedirs(os.path.dirname(out_path), exist_ok=True)
                with open(out_path, "wb") as f:
                    f.write(wav)
            resp = json.dumps({{
                "output_path": out_path,
                "bytes": len(wav),
                "sample_rate": 24000,
                "duration_ms": 100,
                "voice_cache_hit": False,
                "x_acpm_timing": {{"queue_ms": 0.0, "decode_ms": 120.0}}
            }}).encode("utf-8")
            log_event({{"ts": time.time(), "op": "tts_done", "model": model_id, "input": payload.get("input")}})
        elif path == "/infer/chat":
            payload = json.loads(body.decode("utf-8"))
            log_event({{"ts": time.time(), "op": "llm_start", "model": model_id}})
            resp = json.dumps({{
                "id": "chatcmpl-test",
                "object": "chat.completion",
                "created": 1,
                "model": model_id,
                "raw_text": "polished",
                "choices": [{{"index": 0, "message": {{"role": "assistant", "content": "polished"}}, "finish_reason": "stop"}}],
                "usage": {{"prompt_tokens": 5, "completion_tokens": 1, "total_tokens": 6}}
            }}).encode("utf-8")
            log_event({{"ts": time.time(), "op": "llm_done", "model": model_id}})
        elif path == "/shutdown":
            resp = b'{{"status":"shutting_down"}}'
            stop_event.set()
        else:
            resp = b'{{"status":"ok"}}'

        http = (
            f"HTTP/1.1 200 OK\r\n"
            f"Content-Type: application/json\r\n"
            f"Content-Length: {{len(resp)}}\r\n"
            f"Connection: close\r\n\r\n"
        ).encode("utf-8") + resp
        conn.sendall(http)
    finally:
        conn.close()

def stdin_loop():
    for line in sys.stdin:
        if "shutdown" in line:
            stop_event.set()
            break
    stop_event.set()

signal.signal(signal.SIGTERM, lambda *_: stop_event.set())
threading.Thread(target=stdin_loop, daemon=True).start()

while not stop_event.is_set():
    try:
        conn, _ = srv.accept()
        threading.Thread(target=handle_conn, args=(conn,), daemon=True).start()
    except socket.timeout:
        pass
    except OSError:
        break

emit({{"type": "state", "state": "UNLOADING", "ts_ms": 4}})
srv.close()
if os.path.exists(ipc_path):
    os.remove(ipc_path)
sys.exit(0)
"#,
            event_log = event_log.to_string_lossy()
        );
        std::fs::write(&script, code).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        script
    }

    fn setup_fake_model(dir: &Path, name: &str, quant_bits: u64) -> PathBuf {
        let mdir = dir.join(name);
        std::fs::create_dir_all(&mdir).unwrap();
        std::fs::write(
            mdir.join("config.json"),
            format!(r#"{{"quantization":{{"bits":{quant_bits}}}}}"#),
        )
        .unwrap();
        std::fs::write(mdir.join("model.safetensors"), b"stub").unwrap();
        mdir
    }

    fn build_16gb_supervisor(
        tmp: &Path,
        mock_worker: PathBuf,
        budget_mb: u64,
    ) -> RuntimeSupervisor {
        let tts_dir = setup_fake_model(tmp, "tts-8bit", 8);
        let llm_dir = setup_fake_model(tmp, "llm-8bit", 8);
        let mut overrides = BTreeMap::new();
        overrides.insert(
            "qwen3-tts-1.7b".to_string(),
            ModelOverrideConfig {
                path: tts_dir,
                quant: Some("8bit".to_string()),
                idle_timeout_sec: Some(60),
                pin_policy: None,
            },
        );
        overrides.insert(
            "yanmo-correct-4b-cot".to_string(),
            ModelOverrideConfig {
                path: llm_dir,
                quant: Some("8bit".to_string()),
                idle_timeout_sec: Some(60),
                pin_policy: None,
            },
        );
        let paths = RuntimePaths::from_data_dir(tmp);
        let diagnostics = Arc::new(DiagnosticsStore::open(&paths.diagnostics_db));
        RuntimeSupervisor::new(
            ModelRegistry::embedded_default().unwrap(),
            MockTelemetry::mac_16gb().host_profile().unwrap(),
            paths,
            Arc::new(MockTelemetry::mac_16gb()),
            diagnostics,
            SupervisorConfig {
                worker_mlx_bin: Some(mock_worker),
                worker_speech_bin: None,
                model_overrides: overrides,
                budget_tier: BudgetTier::Balanced,
                budget_override_mb: Some(budget_mb),
                default_idle_timeout_override: None,
                queue_timeout: Duration::from_secs(10),
                startup_timeout: Duration::from_secs(10),
            },
        )
    }

    #[tokio::test]
    async fn sentence_level_preemption_under_16gb_budget_7500mb() {
        let tmp = std::env::temp_dir().join(format!("acpm-batch-preempt-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&tmp).unwrap();
        let event_log = tmp.join("worker_events.jsonl");
        let mock_bin = write_http_mock_worker(&tmp, &event_log);
        // 7500 MB budget: TTS 8bit (3250 MB) + LLM 8bit (5265 MB) = 8515 MB > 7500 MB -> forces eviction!
        let supervisor = build_16gb_supervisor(&tmp, mock_bin, 7500);
        let voices = VoiceStore::open(tmp.join("voices")).unwrap();
        let manager = BatchManager::with_config(
            supervisor.clone(),
            voices,
            BatchConfig {
                thermal_serious_cooldown: Duration::ZERO,
                thermal_critical_poll: Duration::from_millis(50),
            },
        );

        let out_dir = tmp.join("out");
        let created = manager
            .create_batch(
                CreateSpeechBatchRequest {
                    model: "qwen3-tts-1.7b".to_string(),
                    voice: Some("Vivian".to_string()),
                    instruct: None,
                    reference_audio: None,
                    reference_text: None,
                    x_vector_only_mode: false,
                    speed: None,
                    output_dir: out_dir.to_string_lossy().into_owned(),
                    items: vec![
                        SpeechBatchItemInput {
                            id: "s1".to_string(),
                            text: "第一句".to_string(),
                            output_file: "01.wav".to_string(),
                            instruct: None,
                        },
                        SpeechBatchItemInput {
                            id: "s2".to_string(),
                            text: "第二句".to_string(),
                            output_file: "02.wav".to_string(),
                            instruct: None,
                        },
                        SpeechBatchItemInput {
                            id: "s3".to_string(),
                            text: "第三句".to_string(),
                            output_file: "03.wav".to_string(),
                            instruct: None,
                        },
                        SpeechBatchItemInput {
                            id: "s4".to_string(),
                            text: "第四句".to_string(),
                            output_file: "04.wav".to_string(),
                            instruct: None,
                        },
                    ],
                },
                "dubbing".to_string(),
            )
            .unwrap();

        let (_snap, mut events_rx) = manager.subscribe_batch(&created.batch_id).unwrap();

        // Wait until the first sentence completes while remaining batch sentences are running.
        loop {
            let cur = manager.get_batch(&created.batch_id).unwrap();
            if cur.completed >= 1 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }

        // Dispatch Interactive LLM request while Batch TTS is active.
        let llm_resp = supervisor
            .chat_completion(
                ChatCompletionRequest {
                    model: "yanmo-correct-4b-cot".to_string(),
                    messages: vec![ChatMessage {
                        role: "user".to_string(),
                        content: "请润色这句话".to_string(),
                        reasoning_content: None,
                    }],
                    temperature: None,
                    max_tokens: Some(16),
                    stream: false,
                    separate_reasoning: false,
                    prompt_cache_key: None,
                },
                RequestContext {
                    request_id: "ime-preempt-1".to_string(),
                    caller: "yanmo-ime".to_string(),
                    priority: Priority::Interactive,
                },
            )
            .await
            .unwrap();
        assert_eq!(llm_resp.choices[0].message.content, "polished");

        // Wait for remaining batch items to finish after Interactive LLM completes.
        let deadline = tokio::time::Instant::now() + Duration::from_secs(15);
        let final_state = loop {
            let st = manager.get_batch(&created.batch_id).unwrap();
            if matches!(
                st.status,
                SpeechBatchStatus::Completed
                    | SpeechBatchStatus::CompletedWithErrors
                    | SpeechBatchStatus::Cancelled
            ) {
                break st;
            }
            assert!(
                tokio::time::Instant::now() < deadline,
                "timed out waiting for batch completion; state={st:?}"
            );
            tokio::time::sleep(Duration::from_millis(30)).await;
        };

        assert_eq!(final_state.status, SpeechBatchStatus::Completed);
        assert_eq!(final_state.completed, 4);
        assert_eq!(final_state.failed, 0);
        for name in ["01.wav", "02.wav", "03.wav", "04.wav"] {
            assert!(out_dir.join(name).is_file(), "missing {name}");
        }

        // Confirm SSE stream observed updates and Interactive LLM ran before the final TTS sentence.
        let mut saw_sse = false;
        while let Ok(_ev) = events_rx.try_recv() {
            saw_sse = true;
        }
        assert!(saw_sse);

        let ops: Vec<String> = std::fs::read_to_string(&event_log)
            .unwrap()
            .lines()
            .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
            .filter_map(|v| v.get("op").and_then(|s| s.as_str()).map(ToOwned::to_owned))
            .collect();
        let first_tts_done = ops.iter().position(|o| o == "tts_done").unwrap();
        let llm_pos = ops.iter().position(|o| o == "llm_start").unwrap();
        let last_tts_start = ops.iter().rposition(|o| o == "tts_start").unwrap();
        assert!(
            llm_pos > first_tts_done && llm_pos < last_tts_start,
            "expected Interactive LLM between TTS sentences, got ops={ops:?}"
        );

        supervisor.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test]
    async fn batch_pause_resume_cancel_and_path_traversal_guard() {
        let tmp = std::env::temp_dir().join(format!("acpm-batch-ctrl-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&tmp).unwrap();
        let event_log = tmp.join("worker_events.jsonl");
        let mock_bin = write_http_mock_worker(&tmp, &event_log);
        let supervisor = build_16gb_supervisor(&tmp, mock_bin, 10000);
        let voices = VoiceStore::open(tmp.join("voices")).unwrap();
        let manager = BatchManager::new(supervisor.clone(), voices);

        let err = manager
            .create_batch(
                CreateSpeechBatchRequest {
                    model: "qwen3-tts-1.7b".to_string(),
                    voice: None,
                    instruct: None,
                    reference_audio: None,
                    reference_text: None,
                    x_vector_only_mode: false,
                    speed: None,
                    output_dir: tmp.join("out").to_string_lossy().into_owned(),
                    items: vec![SpeechBatchItemInput {
                        id: "bad".to_string(),
                        text: "escape".to_string(),
                        output_file: "../escape.wav".to_string(),
                        instruct: None,
                    }],
                },
                "test".to_string(),
            )
            .unwrap_err();
        assert!(matches!(
            err,
            BatchError::InvalidRequest {
                code: "PATH_TRAVERSAL_FORBIDDEN",
                ..
            }
        ));

        let batch = manager
            .create_batch(
                CreateSpeechBatchRequest {
                    model: "qwen3-tts-1.7b".to_string(),
                    voice: None,
                    instruct: None,
                    reference_audio: None,
                    reference_text: None,
                    x_vector_only_mode: false,
                    speed: None,
                    output_dir: tmp.join("out2").to_string_lossy().into_owned(),
                    items: (1..=4)
                        .map(|i| SpeechBatchItemInput {
                            id: format!("i{i}"),
                            text: format!("句子 {i}"),
                            output_file: format!("{i}.wav"),
                            instruct: None,
                        })
                        .collect(),
                },
                "test".to_string(),
            )
            .unwrap();

        let paused = manager.pause_batch(&batch.batch_id).unwrap();
        assert_eq!(paused.status, SpeechBatchStatus::Paused);
        tokio::time::sleep(Duration::from_millis(250)).await;
        let resumed = manager.resume_batch(&batch.batch_id).unwrap();
        assert_eq!(resumed.status, SpeechBatchStatus::Running);
        let cancelled = manager.cancel_batch(&batch.batch_id).unwrap();
        assert_eq!(cancelled.status, SpeechBatchStatus::Cancelled);

        supervisor.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
