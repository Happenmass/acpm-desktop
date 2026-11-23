use crate::config::{
    inspect_model_installation, resolve_installed_model, resolve_sherpa_lib_dir, DaemonFileConfig,
    ModelOverrideConfig, ResolveModelError, ResolvedModel,
};
use crate::diagnostics::DiagnosticsStore;
use crate::worker_client::{open_chat_stream, post_json, WorkerEndpoint};
use acpm_pal::{HostProfile, RuntimePaths, SystemTelemetry};
use acpm_protocol::{
    ApiError, BudgetTier, Capability, ChatChoice, ChatCompletionRequest, ChatCompletionResponse,
    ChatMessage, ComputeSlot, DiagnosticFailure, ErrorCode, FailureStage, MemoryPressure,
    ModelConfigOverrideSummary, ModelDownloadState, ModelStatusInfo, ModelVariant, PinPolicy,
    Priority, ResourceBudget, ResourceVector, SpeechBatchState, SpeechFileResponse, SpeechRequest,
    SystemConfigResponse, SystemStatusResponse, TimingMetrics, TranscriptSegment,
    TranscriptionRequest, TranscriptionResponse, UpdateModelConfigRequest, UpdateSystemConfigRequest,
    UsageStats, VadRequest, VadResponse, VadSegment, WorkerCommand, WorkerFrame, WorkerMode,
    WorkerState, FRAME_PREFIX,
};
use acpm_registry::{compute_default_budget, ModelRegistry};
use acpm_scheduler::{
    plan_admission, AdmissionDecision, AdmissionRequest, CotChunk, CotStreamSplitter,
    LoadedWorkerSnapshot,
};
use axum::response::sse::Event;
use chrono::Utc;
use serde::Serialize;
use std::collections::{BTreeMap, HashMap};
use std::convert::Infallible;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use tokio::sync::{broadcast, mpsc, oneshot, watch, Notify};
use tracing::{info, warn};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum SystemEvent {
    ModelStateChanged {
        model_id: String,
        state: WorkerState,
        memory: ResourceVector,
        ts_ms: i64,
    },
    FailureRecorded {
        failure: DiagnosticFailure,
    },
    BatchProgress {
        batch: SpeechBatchState,
    },
    DownloadProgress {
        download: ModelDownloadState,
    },
    ConfigChanged {
        budget_tier: BudgetTier,
        budget: ResourceVector,
    },
}

#[derive(Debug, Clone)]
pub struct RequestContext {
    pub request_id: String,
    pub caller: String,
    pub priority: Priority,
}

pub enum SpeechOutput {
    File(SpeechFileResponse),
    AudioBytes {
        wav: Vec<u8>,
        duration_ms: i64,
        decode_ms: f64,
        voice_cache_hit: bool,
        queue_ms: f64,
        model_load_ms: f64,
    },
}

struct Waiter {
    seq: u64,
    rank: u8,
    tx: oneshot::Sender<SlotPermit>,
}

struct GateState {
    max_concurrent: usize,
    active: usize,
    next_seq: u64,
    waiters: Vec<Waiter>,
}

pub struct PrioritySlotGate {
    state: Mutex<GateState>,
}

pub struct SlotPermit {
    gate: Arc<PrioritySlotGate>,
    armed: AtomicBool,
}

impl SlotPermit {
    fn new(gate: Arc<PrioritySlotGate>) -> Self {
        Self {
            gate,
            armed: AtomicBool::new(true),
        }
    }

    fn disarm(&self) {
        self.armed.store(false, Ordering::SeqCst);
    }
}

impl Drop for SlotPermit {
    fn drop(&mut self) {
        if self.armed.swap(false, Ordering::SeqCst) {
            self.gate.release();
        }
    }
}

impl PrioritySlotGate {
    pub fn new(max_concurrent: usize) -> Arc<Self> {
        Arc::new(Self {
            state: Mutex::new(GateState {
                max_concurrent: max_concurrent.max(1),
                active: 0,
                next_seq: 0,
                waiters: Vec::new(),
            }),
        })
    }

    pub async fn acquire(
        self: &Arc<Self>,
        priority: Priority,
        timeout: Duration,
    ) -> Result<(SlotPermit, f64), ()> {
        let start = Instant::now();
        let rx = {
            let mut guard = self.state.lock().unwrap();
            if guard.active < guard.max_concurrent && guard.waiters.is_empty() {
                guard.active += 1;
                return Ok((SlotPermit::new(Arc::clone(self)), 0.0));
            }
            let seq = guard.next_seq;
            guard.next_seq += 1;
            let (tx, rx) = oneshot::channel();
            guard.waiters.push(Waiter {
                seq,
                rank: priority.retention_rank(),
                tx,
            });
            rx
        };

        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(permit)) => {
                let waited_ms = start.elapsed().as_secs_f64() * 1000.0;
                Ok((permit, waited_ms))
            }
            _ => {
                let mut guard = self.state.lock().unwrap();
                guard.waiters.retain(|w| !w.tx.is_closed());
                Err(())
            }
        }
    }

    fn release(self: &Arc<Self>) {
        let mut guard = self.state.lock().unwrap();
        guard.active = guard.active.saturating_sub(1);
        while guard.active < guard.max_concurrent && !guard.waiters.is_empty() {
            let best_idx = guard
                .waiters
                .iter()
                .enumerate()
                .max_by(|(_, a), (_, b)| a.rank.cmp(&b.rank).then_with(|| b.seq.cmp(&a.seq)))
                .map(|(idx, _)| idx);

            let Some(idx) = best_idx else {
                break;
            };
            let waiter = guard.waiters.remove(idx);
            let permit = SlotPermit::new(Arc::clone(self));
            match waiter.tx.send(permit) {
                Ok(()) => {
                    guard.active += 1;
                    break;
                }
                Err(returned) => {
                    returned.disarm();
                }
            }
        }
    }

    pub fn active_count(&self) -> usize {
        self.state.lock().unwrap().active
    }

    pub fn queued_count(&self) -> usize {
        self.state
            .lock()
            .unwrap()
            .waiters
            .iter()
            .filter(|w| !w.tx.is_closed())
            .count()
    }
}

struct ManagedWorkerMutable {
    state: WorkerState,
    model_load_ms: Option<f64>,
    actual_memory: Option<ResourceVector>,
    pin_policy: PinPolicy,
    idle_timeout_sec: u64,
    kv_cache_entries: usize,
    voice_cache_entries: usize,
    in_flight: usize,
    last_active_at_ms: i64,
    last_error: Option<(FailureStage, String, Option<String>)>,
}

struct ManagedWorker {
    model_id: String,
    variant: ModelVariant,
    priority: Priority,
    endpoint: WorkerEndpoint,
    token: String,
    pid: u32,
    stdin_tx: mpsc::UnboundedSender<WorkerCommand>,
    kill_tx: Mutex<Option<oneshot::Sender<()>>>,
    exit_rx: watch::Receiver<Option<Option<i32>>>,
    mutable: Mutex<ManagedWorkerMutable>,
}

pub struct WorkerLease {
    inner: Arc<SupervisorInner>,
    worker: Arc<ManagedWorker>,
    pub model_load_ms: f64,
}

impl WorkerLease {
    fn endpoint(&self) -> &WorkerEndpoint {
        &self.worker.endpoint
    }

    fn token(&self) -> &str {
        &self.worker.token
    }

    fn pid(&self) -> u32 {
        self.worker.pid
    }
}

impl Drop for WorkerLease {
    fn drop(&mut self) {
        let now_ms = Utc::now().timestamp_millis();
        let mut emit_state = None;
        {
            let mut st = self.worker.mutable.lock().unwrap();
            st.in_flight = st.in_flight.saturating_sub(1);
            st.last_active_at_ms = now_ms;
            if st.in_flight == 0 && st.state == WorkerState::Running {
                st.state = WorkerState::Warm;
                let mem = st
                    .actual_memory
                    .clone()
                    .unwrap_or_else(|| self.worker.variant.footprint.clone());
                emit_state = Some((WorkerState::Warm, mem));
            }
        }
        if let Some((state, memory)) = emit_state {
            self.inner.emit_model_state(&self.worker.model_id, state, memory);
        }
        self.inner.state_notify.notify_waiters();
    }
}

pub struct SupervisorConfig {
    pub worker_mlx_bin: Option<PathBuf>,
    pub worker_speech_bin: Option<PathBuf>,
    pub model_overrides: BTreeMap<String, ModelOverrideConfig>,
    pub budget_tier: BudgetTier,
    pub budget_override_mb: Option<u64>,
    pub default_idle_timeout_override: Option<u64>,
    pub queue_timeout: Duration,
    pub startup_timeout: Duration,
}

fn compute_effective_budget(
    profile: &HostProfile,
    tier: BudgetTier,
    override_mb: Option<u64>,
) -> ResourceBudget {
    let mut budget = compute_default_budget(profile, tier);
    if let Some(mb) = override_mb {
        if profile.is_unified_memory {
            budget.limits = ResourceVector::unified(mb);
        } else if let Some(vram) = budget.limits.gpu_vram_mb.get_mut(&0) {
            *vram = mb;
        }
    }
    budget
}

struct SupervisorInner {
    registry: ModelRegistry,
    profile: HostProfile,
    paths: RuntimePaths,
    telemetry: Arc<dyn SystemTelemetry>,
    budget: RwLock<ResourceBudget>,
    budget_tier: RwLock<BudgetTier>,
    budget_override_mb: RwLock<Option<u64>>,
    worker_mlx_bin: Option<PathBuf>,
    worker_speech_bin: Option<PathBuf>,
    model_overrides: RwLock<BTreeMap<String, ModelOverrideConfig>>,
    default_idle_timeout_override: Option<u64>,
    queue_timeout: Duration,
    startup_timeout: Duration,
    uds_dir: PathBuf,
    next_worker_seq: AtomicU64,
    workers: Mutex<HashMap<String, Arc<ManagedWorker>>>,
    caller_counts: Mutex<BTreeMap<String, u64>>,
    state_notify: Arc<Notify>,
    gpu_gate: Arc<PrioritySlotGate>,
    cpu_gate: Arc<PrioritySlotGate>,
    diagnostics: Arc<DiagnosticsStore>,
    events_tx: broadcast::Sender<SystemEvent>,
}

impl SupervisorInner {
    fn emit_model_state(&self, model_id: &str, state: WorkerState, memory: ResourceVector) {
        let _ = self.events_tx.send(SystemEvent::ModelStateChanged {
            model_id: model_id.to_string(),
            state,
            memory,
            ts_ms: Utc::now().timestamp_millis(),
        });
    }

    fn record_failure(
        &self,
        ctx: &RequestContext,
        model_id: Option<&str>,
        operation: &str,
        stage: FailureStage,
        code: ErrorCode,
        detail: &str,
        message: &str,
        native_code: Option<String>,
        elapsed_ms: i64,
        worker_pid: Option<u32>,
    ) -> ApiError {
        let failure = DiagnosticFailure {
            timestamp_ms: Utc::now().timestamp_millis(),
            request_id: ctx.request_id.clone(),
            caller: ctx.caller.clone(),
            model_id: model_id.map(ToString::to_string),
            operation: operation.to_string(),
            stage,
            code,
            detail: detail.to_string(),
            native_code: native_code.clone(),
            elapsed_ms,
            worker_pid,
        };
        self.diagnostics.record(failure.clone());
        let _ = self.events_tx.send(SystemEvent::FailureRecorded { failure });
        ApiError {
            code,
            message: message.to_string(),
            request_id: ctx.request_id.clone(),
            stage,
            detail: detail.to_string(),
            native_code,
            elapsed_ms,
            retryable: code.default_retryable(),
        }
    }

    fn record_caller(&self, caller: &str) {
        let key = if caller.trim().is_empty() {
            "unknown"
        } else {
            caller.trim()
        };
        if let Ok(mut guard) = self.caller_counts.lock() {
            *guard.entry(key.to_string()).or_insert(0) += 1;
        }
    }

    fn normalize_resource_for_profile(&self, raw: &ResourceVector) -> ResourceVector {
        let mut out = raw.clone();
        if self.profile.is_unified_memory {
            out.unified_mb = if raw.unified_mb > 0 {
                raw.unified_mb
            } else {
                raw.system_ram_mb
            };
            out.system_ram_mb = 0;
        } else {
            out.system_ram_mb = if raw.system_ram_mb > 0 {
                raw.system_ram_mb
            } else {
                raw.unified_mb
            };
            out.unified_mb = 0;
        }
        out
    }

    fn snapshot_loaded_workers(&self) -> Vec<LoadedWorkerSnapshot> {
        let workers = self.workers.lock().unwrap();
        workers
            .values()
            .map(|w| {
                let st = w.mutable.lock().unwrap();
                LoadedWorkerSnapshot {
                    model_id: w.model_id.clone(),
                    variant_id: w.variant.variant_id.clone(),
                    footprint: self.normalize_resource_for_profile(&w.variant.footprint),
                    actual_memory: st
                        .actual_memory
                        .as_ref()
                        .map(|m| self.normalize_resource_for_profile(m)),
                    in_flight: st.in_flight,
                    pin_policy: st.pin_policy,
                    priority: w.priority,
                    last_active_at_ms: st.last_active_at_ms,
                }
            })
            .collect()
    }

    async fn stop_and_remove_worker(&self, model_id: &str) {
        let worker = {
            let workers = self.workers.lock().unwrap();
            workers.get(model_id).cloned()
        };
        let Some(worker) = worker else {
            return;
        };

        {
            let mut st = worker.mutable.lock().unwrap();
            if st.state != WorkerState::Failed {
                st.state = WorkerState::Unloading;
            }
        }
        self.emit_model_state(
            &worker.model_id,
            WorkerState::Unloading,
            ResourceVector::default(),
        );
        self.state_notify.notify_waiters();

        let _ = worker.stdin_tx.send(WorkerCommand::Shutdown);

        let mut exit_rx = worker.exit_rx.clone();
        let exited = tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                if exit_rx.borrow().is_some() {
                    break;
                }
                if exit_rx.changed().await.is_err() {
                    break;
                }
            }
        })
        .await
        .is_ok();

        if !exited {
            let kill_sender = worker.kill_tx.lock().unwrap().take();
            if let Some(tx) = kill_sender {
                let _ = tx.send(());
            }
            let _ = tokio::time::timeout(Duration::from_secs(2), async {
                loop {
                    if exit_rx.borrow().is_some() {
                        break;
                    }
                    if exit_rx.changed().await.is_err() {
                        break;
                    }
                }
            })
            .await;
        }

        if let WorkerEndpoint::Unix(sock) = &worker.endpoint {
            let _ = std::fs::remove_file(sock);
        }

        {
            let mut workers = self.workers.lock().unwrap();
            if let Some(current) = workers.get(model_id) {
                if Arc::ptr_eq(current, &worker) {
                    workers.remove(model_id);
                }
            }
        }

        self.emit_model_state(
            &worker.model_id,
            WorkerState::Stopped,
            ResourceVector::default(),
        );
        self.state_notify.notify_waiters();
    }

    async fn spawn_and_wait_warm(
        self: &Arc<Self>,
        resolved: &ResolvedModel,
        ctx: &RequestContext,
        operation: &str,
        start_time: Instant,
    ) -> Result<Arc<ManagedWorker>, ApiError> {
        let (mode, worker_bin_opt, missing_code, missing_msg) = match resolved.entry.capability {
            Capability::Llm => (
                WorkerMode::Llm,
                &self.worker_mlx_bin,
                "WORKER_BINARY_NOT_FOUND",
                "Could not locate acpm-worker-mlx executable.",
            ),
            Capability::Asr => (
                WorkerMode::Asr,
                &self.worker_mlx_bin,
                "WORKER_BINARY_NOT_FOUND",
                "Could not locate acpm-worker-mlx executable.",
            ),
            Capability::Tts => (
                WorkerMode::Tts,
                &self.worker_mlx_bin,
                "WORKER_BINARY_NOT_FOUND",
                "Could not locate acpm-worker-mlx executable.",
            ),
            Capability::Vad => (
                WorkerMode::Speech,
                &self.worker_speech_bin,
                "SPEECH_WORKER_BINARY_NOT_FOUND",
                "Could not locate acpm-worker-speech executable.",
            ),
            Capability::Diarization => {
                return Err(self.record_failure(
                    ctx,
                    Some(&resolved.entry.id),
                    operation,
                    FailureStage::HttpAdmission,
                    ErrorCode::NotImplemented,
                    "DIARIZATION_DEFERRED",
                    "Speaker diarization is deferred in the current phase; only VAD is enabled.",
                    None,
                    start_time.elapsed().as_millis() as i64,
                    None,
                ));
            }
        };

        let Some(worker_bin) = worker_bin_opt else {
            return Err(self.record_failure(
                ctx,
                Some(&resolved.entry.id),
                operation,
                FailureStage::WorkerStart,
                ErrorCode::WorkerCrashed,
                missing_code,
                missing_msg,
                None,
                start_time.elapsed().as_millis() as i64,
                None,
            ));
        };

        std::fs::create_dir_all(&self.uds_dir).map_err(|e| {
            self.record_failure(
                ctx,
                Some(&resolved.entry.id),
                operation,
                FailureStage::WorkerStart,
                ErrorCode::WorkerCrashed,
                "UDS_DIR_CREATE_FAILED",
                &format!("Failed creating worker UDS directory: {e}"),
                None,
                start_time.elapsed().as_millis() as i64,
                None,
            )
        })?;

        let seq = self.next_worker_seq.fetch_add(1, Ordering::SeqCst);
        let sock_path = self.uds_dir.join(format!("w-{seq}.sock"));
        let _ = std::fs::remove_file(&sock_path);
        let token = format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple());
        let memory_limit_mb = self.budget.read().unwrap().limits.total_mb().max(1024);

        let mode_arg = match mode {
            WorkerMode::Llm => "llm",
            WorkerMode::Asr => "asr",
            WorkerMode::Tts => "tts",
            WorkerMode::Speech => "speech",
        };

        let mut cmd = Command::new(worker_bin);
        cmd.arg("--mode")
            .arg(mode_arg)
            .arg("--model-id")
            .arg(&resolved.entry.id)
            .arg("--model-dir")
            .arg(&resolved.model_dir)
            .arg("--ipc-path")
            .arg(&sock_path)
            .arg("--auth-token-env")
            .arg("ACPM_WORKER_TOKEN")
            .arg("--memory-limit-mb")
            .arg(memory_limit_mb.to_string())
            .arg("--threads")
            .arg(self.profile.cpu_cores.clamp(1, 8).to_string())
            .env("ACPM_WORKER_TOKEN", &token)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());

        if mode == WorkerMode::Speech {
            if let Some(lib_dir) = resolve_sherpa_lib_dir() {
                cmd.env("ACPM_SHERPA_LIB_DIR", lib_dir);
            }
        }

        #[cfg(unix)]
        unsafe {
            cmd.pre_exec(|| {
                libc::setpgid(0, 0);
                Ok(())
            });
        }

        let mut child = cmd.spawn().map_err(|e| {
            self.record_failure(
                ctx,
                Some(&resolved.entry.id),
                operation,
                FailureStage::WorkerStart,
                ErrorCode::WorkerCrashed,
                "WORKER_SPAWN_FAILED",
                &format!("Failed spawning {}: {e}", worker_bin.display()),
                None,
                start_time.elapsed().as_millis() as i64,
                None,
            )
        })?;

        let pid = child.id().unwrap_or(0);
        let stdin = child.stdin.take();
        let stdout = child.stdout.take();
        let stderr = child.stderr.take();

        let (stdin_tx, mut stdin_rx) = mpsc::unbounded_channel::<WorkerCommand>();
        if let Some(mut stdin_pipe) = stdin {
            tokio::spawn(async move {
                while let Some(cmd) = stdin_rx.recv().await {
                    let is_shutdown = matches!(cmd, WorkerCommand::Shutdown);
                    if let Ok(mut line) = serde_json::to_vec(&cmd) {
                        line.push(b'\n');
                        if stdin_pipe.write_all(&line).await.is_err() {
                            break;
                        }
                        let _ = stdin_pipe.flush().await;
                    }
                    if is_shutdown {
                        break;
                    }
                }
            });
        }

        let (kill_tx, mut kill_rx) = oneshot::channel::<()>();
        let (exit_tx, exit_rx) = watch::channel(None);

        let endpoint = {
            #[cfg(unix)]
            {
                WorkerEndpoint::Unix(sock_path.clone())
            }
            #[cfg(not(unix))]
            {
                WorkerEndpoint::Tcp(SocketAddr::from(([127, 0, 0, 1], 0)))
            }
        };

        let now_ms = Utc::now().timestamp_millis();
        let worker = Arc::new(ManagedWorker {
            model_id: resolved.entry.id.clone(),
            variant: resolved.variant.clone(),
            priority: resolved.entry.lifecycle.default_priority,
            endpoint,
            token,
            pid,
            stdin_tx,
            kill_tx: Mutex::new(Some(kill_tx)),
            exit_rx: exit_rx.clone(),
            mutable: Mutex::new(ManagedWorkerMutable {
                state: WorkerState::Starting,
                model_load_ms: None,
                actual_memory: Some(resolved.variant.footprint.clone()),
                pin_policy: resolved.pin_policy,
                idle_timeout_sec: resolved.idle_timeout_sec,
                kv_cache_entries: 0,
                voice_cache_entries: 0,
                in_flight: 0,
                last_active_at_ms: now_ms,
                last_error: None,
            }),
        });

        {
            let mut map = self.workers.lock().unwrap();
            map.insert(resolved.entry.id.clone(), Arc::clone(&worker));
        }
        self.emit_model_state(
            &worker.model_id,
            WorkerState::Starting,
            resolved.variant.footprint.clone(),
        );

        // stderr forwarder (captures diagnostic logs without interfering with control frames)
        if let Some(stderr_pipe) = stderr {
            let model_name = worker.model_id.clone();
            tokio::spawn(async move {
                let mut reader = BufReader::new(stderr_pipe).lines();
                while let Ok(Some(line)) = reader.next_line().await {
                    let trimmed = line.trim();
                    if !trimmed.is_empty() {
                        info!(model = %model_name, worker_stderr = %trimmed, "worker log");
                    }
                }
            });
        }

        // stdout frame reader
        if let Some(stdout_pipe) = stdout {
            let inner = Arc::clone(self);
            let worker_ref = Arc::clone(&worker);
            tokio::spawn(async move {
                let mut reader = BufReader::new(stdout_pipe).lines();
                while let Ok(Some(line)) = reader.next_line().await {
                    if let Some(json_str) = line.strip_prefix(FRAME_PREFIX) {
                        if let Ok(frame) = serde_json::from_str::<WorkerFrame>(json_str) {
                            match frame {
                                WorkerFrame::State {
                                    state,
                                    model_load_ms,
                                    memory,
                                    ..
                                } => {
                                    let emit_mem = {
                                        let mut st = worker_ref.mutable.lock().unwrap();
                                        if st.state != WorkerState::Failed {
                                            st.state = state;
                                        }
                                        if let Some(ms) = model_load_ms {
                                            st.model_load_ms = Some(ms);
                                        }
                                        if let Some(mem) = memory {
                                            st.actual_memory = Some(mem);
                                        }
                                        st.actual_memory
                                            .clone()
                                            .unwrap_or_else(|| worker_ref.variant.footprint.clone())
                                    };
                                    inner.emit_model_state(&worker_ref.model_id, state, emit_mem);
                                    inner.state_notify.notify_waiters();
                                }
                                WorkerFrame::Metric {
                                    memory,
                                    kv_cache_entries,
                                    voice_cache_entries,
                                } => {
                                    let mut st = worker_ref.mutable.lock().unwrap();
                                    st.actual_memory = Some(memory);
                                    st.kv_cache_entries = kv_cache_entries;
                                    st.voice_cache_entries = voice_cache_entries;
                                }
                                WorkerFrame::Error {
                                    stage,
                                    detail,
                                    native_code,
                                    fatal,
                                } => {
                                    let emit_mem = {
                                        let mut st = worker_ref.mutable.lock().unwrap();
                                        st.last_error = Some((stage, detail.clone(), native_code));
                                        if fatal {
                                            st.state = WorkerState::Failed;
                                        }
                                        st.actual_memory
                                            .clone()
                                            .unwrap_or_else(|| worker_ref.variant.footprint.clone())
                                    };
                                    if fatal {
                                        inner.emit_model_state(
                                            &worker_ref.model_id,
                                            WorkerState::Failed,
                                            emit_mem,
                                        );
                                    }
                                    inner.state_notify.notify_waiters();
                                }
                            }
                        }
                    } else if !line.trim().is_empty() {
                        info!(model = %worker_ref.model_id, worker_stdout = %line.trim(), "worker info");
                    }
                }
            });
        }

        // child reaper task
        {
            let inner = Arc::clone(self);
            let worker_ref = Arc::clone(&worker);
            tokio::spawn(async move {
                let status = tokio::select! {
                    res = child.wait() => res.ok(),
                    _ = &mut kill_rx => {
                        let _ = child.kill().await;
                        child.wait().await.ok()
                    }
                };
                let code = status.and_then(|s| s.code());
                let _ = exit_tx.send(Some(code));

                if let WorkerEndpoint::Unix(sock) = &worker_ref.endpoint {
                    let _ = std::fs::remove_file(sock);
                }

                let unexpected = {
                    let mut st = worker_ref.mutable.lock().unwrap();
                    let was_expected = matches!(st.state, WorkerState::Unloading | WorkerState::Stopped);
                    if !was_expected && code != Some(0) {
                        st.state = WorkerState::Failed;
                    } else if was_expected {
                        st.state = WorkerState::Stopped;
                    }
                    !was_expected
                };

                if unexpected {
                    let mut workers = inner.workers.lock().unwrap();
                    if let Some(cur) = workers.get(&worker_ref.model_id) {
                        if Arc::ptr_eq(cur, &worker_ref) {
                            workers.remove(&worker_ref.model_id);
                        }
                    }
                    inner.emit_model_state(
                        &worker_ref.model_id,
                        WorkerState::Stopped,
                        ResourceVector::default(),
                    );
                }
                inner.state_notify.notify_waiters();
            });
        }

        // Await WARM transition (or early exit/error)
        let deadline = tokio::time::Instant::now() + self.startup_timeout;
        let mut exit_sub = exit_rx;
        loop {
            let (cur_state, cur_err) = {
                let st = worker.mutable.lock().unwrap();
                (st.state, st.last_error.clone())
            };
            match cur_state {
                WorkerState::Warm | WorkerState::Running => {
                    return Ok(worker);
                }
                WorkerState::Failed => {
                    let (stage, detail, native) = cur_err.unwrap_or((
                        FailureStage::ModelLoad,
                        "WORKER_REPORTED_FAILURE".to_string(),
                        None,
                    ));
                    self.stop_and_remove_worker(&worker.model_id).await;
                    return Err(self.record_failure(
                        ctx,
                        Some(&resolved.entry.id),
                        operation,
                        stage,
                        ErrorCode::WorkerCrashed,
                        &detail,
                        "Worker failed during startup/model load.",
                        native,
                        start_time.elapsed().as_millis() as i64,
                        Some(pid),
                    ));
                }
                _ => {}
            }

            let exit_snapshot = *exit_sub.borrow();
            if let Some(code_opt) = exit_snapshot {
                self.stop_and_remove_worker(&worker.model_id).await;
                return Err(self.record_failure(
                    ctx,
                    Some(&resolved.entry.id),
                    operation,
                    FailureStage::WorkerStart,
                    ErrorCode::WorkerCrashed,
                    "WORKER_EXITED_BEFORE_WARM",
                    &format!("Worker pid {pid} exited unexpectedly (code={code_opt:?}) before reaching WARM."),
                    None,
                    start_time.elapsed().as_millis() as i64,
                    Some(pid),
                ));
            }

            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                self.stop_and_remove_worker(&worker.model_id).await;
                return Err(self.record_failure(
                    ctx,
                    Some(&resolved.entry.id),
                    operation,
                    FailureStage::ModelLoad,
                    ErrorCode::QueueTimeout,
                    "WORKER_STARTUP_TIMEOUT",
                    "Timed out waiting for worker to reach WARM state.",
                    None,
                    start_time.elapsed().as_millis() as i64,
                    Some(pid),
                ));
            }

            tokio::select! {
                _ = self.state_notify.notified() => {}
                _ = exit_sub.changed() => {}
                _ = tokio::time::sleep(remaining) => {}
            }
        }
    }
}

#[derive(Clone)]
pub struct RuntimeSupervisor {
    inner: Arc<SupervisorInner>,
}

impl RuntimeSupervisor {
    pub fn new(
        registry: ModelRegistry,
        profile: HostProfile,
        paths: RuntimePaths,
        telemetry: Arc<dyn SystemTelemetry>,
        diagnostics: Arc<DiagnosticsStore>,
        config: SupervisorConfig,
    ) -> Self {
        let budget = compute_effective_budget(&profile, config.budget_tier, config.budget_override_mb);

        static NEXT_SUPERVISOR_SEQ: AtomicU64 = AtomicU64::new(1);
        let sup_seq = NEXT_SUPERVISOR_SEQ.fetch_add(1, Ordering::SeqCst);
        let (events_tx, _) = broadcast::channel(256);
        let uds_dir = std::env::temp_dir().join(format!("acpm-{}-{sup_seq}", std::process::id()));
        if let Err(err) = std::fs::create_dir_all(&uds_dir) {
            warn!(error = %err, dir = %uds_dir.display(), "failed creating worker UDS directory");
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&uds_dir, std::fs::Permissions::from_mode(0o700));
        }

        let gpu_gate = PrioritySlotGate::new(budget.max_concurrent_gpu);
        let cpu_gate = PrioritySlotGate::new(budget.max_concurrent_cpu);

        Self {
            inner: Arc::new(SupervisorInner {
                registry,
                profile,
                paths,
                telemetry,
                budget: RwLock::new(budget),
                budget_tier: RwLock::new(config.budget_tier),
                budget_override_mb: RwLock::new(config.budget_override_mb),
                worker_mlx_bin: config.worker_mlx_bin,
                worker_speech_bin: config.worker_speech_bin,
                model_overrides: RwLock::new(config.model_overrides),
                default_idle_timeout_override: config.default_idle_timeout_override,
                queue_timeout: config.queue_timeout,
                startup_timeout: config.startup_timeout,
                uds_dir,
                next_worker_seq: AtomicU64::new(1),
                workers: Mutex::new(HashMap::new()),
                caller_counts: Mutex::new(BTreeMap::new()),
                state_notify: Arc::new(Notify::new()),
                gpu_gate,
                cpu_gate,
                diagnostics,
                events_tx,
            }),
        }
    }

    pub fn registry(&self) -> &ModelRegistry {
        &self.inner.registry
    }

    pub fn profile(&self) -> &HostProfile {
        &self.inner.profile
    }

    pub fn paths(&self) -> &RuntimePaths {
        &self.inner.paths
    }

    pub fn subscribe_events(&self) -> broadcast::Receiver<SystemEvent> {
        self.inner.events_tx.subscribe()
    }

    pub fn emit_batch_progress(&self, batch: &SpeechBatchState) {
        let _ = self.inner.events_tx.send(SystemEvent::BatchProgress {
            batch: batch.clone(),
        });
    }

    pub fn emit_download_progress(&self, download: &ModelDownloadState) {
        let _ = self.inner.events_tx.send(SystemEvent::DownloadProgress {
            download: download.clone(),
        });
    }

    pub fn record_external_failure(
        &self,
        request_id: &str,
        caller: &str,
        model_id: Option<&str>,
        operation: &str,
        stage: FailureStage,
        code: ErrorCode,
        detail: &str,
        message: &str,
    ) -> ApiError {
        let ctx = RequestContext {
            request_id: request_id.to_string(),
            caller: caller.to_string(),
            priority: Priority::Normal,
        };
        self.inner
            .record_failure(&ctx, model_id, operation, stage, code, detail, message, None, 0, None)
    }

    pub fn recent_failures(&self, limit: usize) -> Vec<DiagnosticFailure> {
        self.inner.diagnostics.recent(limit)
    }

    pub fn is_external_model_path(&self, model_id: &str) -> bool {
        let overrides = self.inner.model_overrides.read().unwrap();
        let Some(ov) = overrides.get(model_id) else {
            return false;
        };
        !ov.path.as_os_str().is_empty() && !ov.path.starts_with(&self.inner.paths.models_dir)
    }

    fn persist_config_file(&self) -> Result<(), String> {
        let mut cfg = DaemonFileConfig::load_if_exists(&self.inner.paths.config_json)
            .unwrap_or_default();
        cfg.budget_tier = Some(*self.inner.budget_tier.read().unwrap());
        cfg.budget_override_mb = *self.inner.budget_override_mb.read().unwrap();
        cfg.model_overrides = self.inner.model_overrides.read().unwrap().clone();
        cfg.save_atomic(&self.inner.paths.config_json)
    }

    pub fn get_system_config(
        &self,
        http_base_url: String,
        mdns_hostname: Option<String>,
        mdns_base_url: Option<String>,
    ) -> SystemConfigResponse {
        let tier = *self.inner.budget_tier.read().unwrap();
        let override_mb = *self.inner.budget_override_mb.read().unwrap();
        let effective_budget = self.inner.budget.read().unwrap().limits.clone();
        let overrides_map = self.inner.model_overrides.read().unwrap();
        let model_overrides = overrides_map
            .iter()
            .map(|(k, v)| {
                let path = if v.path.as_os_str().is_empty() {
                    None
                } else {
                    Some(v.path.display().to_string())
                };
                (
                    k.clone(),
                    ModelConfigOverrideSummary {
                        path,
                        quant: v.quant.clone(),
                        idle_timeout_sec: v.idle_timeout_sec,
                        pin_policy: v.pin_policy,
                    },
                )
            })
            .collect();

        SystemConfigResponse {
            budget_tier: tier,
            budget_override_mb: override_mb,
            effective_budget,
            data_dir: self.inner.paths.data_dir.display().to_string(),
            models_dir: self.inner.paths.models_dir.display().to_string(),
            voices_dir: self.inner.paths.voices_dir.display().to_string(),
            config_path: self.inner.paths.config_json.display().to_string(),
            mdns_hostname,
            mdns_base_url,
            http_base_url,
            model_overrides,
        }
    }

    pub fn update_system_config(
        &self,
        req: UpdateSystemConfigRequest,
        http_base_url: String,
        mdns_hostname: Option<String>,
        mdns_base_url: Option<String>,
    ) -> Result<SystemConfigResponse, String> {
        let new_tier = {
            let mut tier_guard = self.inner.budget_tier.write().unwrap();
            if let Some(t) = req.budget_tier {
                *tier_guard = t;
            }
            *tier_guard
        };
        let new_override = {
            let mut ov_guard = self.inner.budget_override_mb.write().unwrap();
            if req.clear_budget_override {
                *ov_guard = None;
            } else if let Some(mb) = req.budget_override_mb {
                *ov_guard = Some(mb.max(1024));
            }
            *ov_guard
        };

        let new_budget = compute_effective_budget(&self.inner.profile, new_tier, new_override);
        let new_limits = new_budget.limits.clone();
        *self.inner.budget.write().unwrap() = new_budget;
        self.persist_config_file()?;

        let _ = self.inner.events_tx.send(SystemEvent::ConfigChanged {
            budget_tier: new_tier,
            budget: new_limits,
        });
        Ok(self.get_system_config(http_base_url, mdns_hostname, mdns_base_url))
    }

    pub fn update_model_config(
        &self,
        model_id: &str,
        req: UpdateModelConfigRequest,
        ctx: &RequestContext,
    ) -> Result<ModelStatusInfo, ApiError> {
        let Some(entry) = self.inner.registry.find_model(model_id) else {
            return Err(self.inner.record_failure(
                ctx,
                Some(model_id),
                "update_model_config",
                FailureStage::HttpAdmission,
                ErrorCode::NotFound,
                "UNKNOWN_MODEL_ID",
                &format!("Model '{model_id}' is not registered."),
                None,
                0,
                None,
            ));
        };

        if let Some(ref raw_quant) = req.quant {
            let q = raw_quant.trim();
            if !q.is_empty() {
                let valid = entry.variants.iter().any(|v| {
                    (v.platform == self.inner.profile.platform || v.platform == "any")
                        && v.quant.as_deref() == Some(q)
                });
                if !valid {
                    return Err(self.inner.record_failure(
                        ctx,
                        Some(model_id),
                        "update_model_config",
                        FailureStage::HttpAdmission,
                        ErrorCode::InvalidRequest,
                        "INVALID_QUANT_VARIANT",
                        &format!("Model '{model_id}' has no compatible variant for quant '{q}'."),
                        None,
                        0,
                        None,
                    ));
                }
            }
        }

        {
            let mut overrides = self.inner.model_overrides.write().unwrap();
            let entry_ov = overrides.entry(model_id.to_string()).or_default();
            if let Some(pin) = req.pin_policy {
                entry_ov.pin_policy = Some(pin);
            }
            if let Some(idle) = req.idle_timeout_sec {
                entry_ov.idle_timeout_sec = Some(idle);
            }
            if let Some(ref quant) = req.quant {
                let trimmed = quant.trim();
                entry_ov.quant = if trimmed.is_empty() {
                    None
                } else {
                    Some(trimmed.to_string())
                };
            }
            if let Some(ref path_str) = req.path {
                let trimmed = path_str.trim();
                entry_ov.path = if trimmed.is_empty() {
                    PathBuf::new()
                } else {
                    PathBuf::from(trimmed)
                };
            }
        }

        if let Err(err) = self.persist_config_file() {
            return Err(self.inner.record_failure(
                ctx,
                Some(model_id),
                "update_model_config",
                FailureStage::HttpAdmission,
                ErrorCode::InferenceFailed,
                "CONFIG_SAVE_FAILED",
                &err,
                None,
                0,
                None,
            ));
        }

        let live_emit = {
            let workers = self.inner.workers.lock().unwrap();
            if let Some(w) = workers.get(model_id) {
                let mut st = w.mutable.lock().unwrap();
                if let Some(pin) = req.pin_policy {
                    st.pin_policy = pin;
                }
                if let Some(idle) = req.idle_timeout_sec {
                    st.idle_timeout_sec = idle;
                }
                Some((
                    st.state,
                    st.actual_memory
                        .clone()
                        .unwrap_or_else(|| w.variant.footprint.clone()),
                ))
            } else {
                None
            }
        };
        if let Some((state, mem)) = live_emit {
            self.inner.emit_model_state(model_id, state, mem);
        }
        self.inner.state_notify.notify_waiters();

        self.list_models_status()
            .into_iter()
            .find(|m| m.id == model_id)
            .ok_or_else(|| {
                self.inner.record_failure(
                    ctx,
                    Some(model_id),
                    "update_model_config",
                    FailureStage::ModelPrepare,
                    ErrorCode::NotFound,
                    "UNKNOWN_MODEL_ID",
                    "Model vanished from registry.",
                    None,
                    0,
                    None,
                )
            })
    }

    pub fn list_models_status(&self) -> Vec<ModelStatusInfo> {
        let overrides = self.inner.model_overrides.read().unwrap().clone();
        let workers = self.inner.workers.lock().unwrap();
        let now_ms = Utc::now().timestamp_millis();

        self.inner
            .registry
            .models()
            .iter()
            .map(|entry| {
                let inspected = inspect_model_installation(
                    &self.inner.registry,
                    &self.inner.profile.platform,
                    &self.inner.paths.models_dir,
                    &overrides,
                    &entry.id,
                    None,
                    self.inner.default_idle_timeout_override,
                )
                .ok();

                let mut available_quants = Vec::new();
                for v in &entry.variants {
                    if v.platform == self.inner.profile.platform || v.platform == "any" {
                        if let Some(ref q) = v.quant {
                            if !available_quants.contains(q) {
                                available_quants.push(q.clone());
                            }
                        }
                    }
                }

                let live = workers.get(&entry.id);
                let (state, memory, variant_id, idle_sec, pin_policy, idle_remaining_sec) =
                    if let Some(w) = live {
                        let st = w.mutable.lock().unwrap();
                        let remaining = if st.state == WorkerState::Warm
                            && st.pin_policy != PinPolicy::Pinned
                            && st.idle_timeout_sec > 0
                        {
                            let elapsed = (now_ms.saturating_sub(st.last_active_at_ms).max(0)
                                / 1000) as u64;
                            Some(st.idle_timeout_sec.saturating_sub(elapsed))
                        } else {
                            None
                        };
                        (
                            st.state,
                            st.actual_memory
                                .clone()
                                .unwrap_or_else(|| w.variant.footprint.clone()),
                            Some(w.variant.variant_id.clone()),
                            st.idle_timeout_sec,
                            st.pin_policy,
                            remaining,
                        )
                    } else {
                        (
                            WorkerState::Stopped,
                            ResourceVector::default(),
                            inspected.as_ref().map(|(r, _)| r.variant.variant_id.clone()),
                            inspected
                                .as_ref()
                                .map(|(r, _)| r.idle_timeout_sec)
                                .unwrap_or(entry.lifecycle.idle_timeout_sec),
                            inspected
                                .as_ref()
                                .map(|(r, _)| r.pin_policy)
                                .unwrap_or(entry.lifecycle.pin_policy),
                            None,
                        )
                    };

                let installed = inspected.as_ref().map(|(_, ok)| *ok).unwrap_or(false);
                let model_path = if installed {
                    inspected.as_ref().map(|(r, _)| r.model_dir.display().to_string())
                } else {
                    None
                };

                ModelStatusInfo {
                    id: entry.id.clone(),
                    capability: entry.capability,
                    display_name: entry.display_name.clone(),
                    selected_variant: variant_id,
                    installed,
                    state,
                    pin_policy,
                    idle_timeout_sec: idle_sec,
                    idle_remaining_sec,
                    available_quants,
                    model_path,
                    memory,
                }
            })
            .collect()
    }

    pub fn system_status(&self) -> SystemStatusResponse {
        let all_models = self.list_models_status();
        let loaded_models: Vec<ModelStatusInfo> = all_models
            .into_iter()
            .filter(|m| m.state != WorkerState::Stopped)
            .collect();
        let used = loaded_models.iter().fold(ResourceVector::default(), |acc, m| {
            acc.add(&m.memory)
        });
        let caller_counts = self.inner.caller_counts.lock().unwrap().clone();
        let active_requests = self.inner.gpu_gate.active_count() + self.inner.cpu_gate.active_count();
        let queued_requests = self.inner.gpu_gate.queued_count() + self.inner.cpu_gate.queued_count();
        let budget = self.inner.budget.read().unwrap().limits.clone();

        SystemStatusResponse {
            platform: self.inner.profile.platform.clone(),
            pid: std::process::id(),
            budget,
            used,
            memory_pressure: self.inner.telemetry.memory_pressure(),
            thermal_state: self.inner.telemetry.thermal_state(),
            loaded_models,
            active_requests,
            queued_requests,
            caller_counts,
        }
    }

    fn resolve_model(
        &self,
        model_id: &str,
        quant: Option<&str>,
        ctx: &RequestContext,
        operation: &str,
    ) -> Result<ResolvedModel, ApiError> {
        let overrides = self.inner.model_overrides.read().unwrap().clone();
        match resolve_installed_model(
            &self.inner.registry,
            &self.inner.profile.platform,
            &self.inner.paths.models_dir,
            &overrides,
            model_id,
            quant,
            self.inner.default_idle_timeout_override,
        ) {
            Ok(resolved) => Ok(resolved),
            Err(ResolveModelError::NotFound(id)) => Err(self.inner.record_failure(
                ctx,
                Some(model_id),
                operation,
                FailureStage::ModelPrepare,
                ErrorCode::NotFound,
                "UNKNOWN_MODEL_ID",
                &format!("Model '{id}' is not registered."),
                None,
                0,
                None,
            )),
            Err(ResolveModelError::UnsupportedPlatform { model_id, platform }) => {
                Err(self.inner.record_failure(
                    ctx,
                    Some(&model_id),
                    operation,
                    FailureStage::ModelPrepare,
                    ErrorCode::UnsupportedPlatform,
                    "UNSUPPORTED_PLATFORM",
                    &format!("No compatible variant of '{model_id}' for '{platform}'."),
                    None,
                    0,
                    None,
                ))
            }
            Err(ResolveModelError::NotInstalled {
                model_id,
                variant_id,
                expected_path,
            }) => Err(self.inner.record_failure(
                ctx,
                Some(&model_id),
                operation,
                FailureStage::ModelPrepare,
                ErrorCode::ModelNotInstalled,
                "MISSING_WEIGHT_FILES",
                &format!(
                    "Model '{model_id}' ({variant_id}) is not installed at '{}'.",
                    expected_path.display()
                ),
                None,
                0,
                None,
            )),
        }
    }

    async fn acquire_worker_lease(
        &self,
        resolved: &ResolvedModel,
        ctx: &RequestContext,
        operation: &str,
        mark_running: bool,
    ) -> Result<WorkerLease, ApiError> {
        let start = Instant::now();
        let deadline = tokio::time::Instant::now() + self.inner.queue_timeout;

        loop {
            let existing = {
                let workers = self.inner.workers.lock().unwrap();
                workers.get(&resolved.entry.id).cloned()
            };

            if let Some(worker) = existing {
                let mut wait_needed = false;
                {
                    let mut st = worker.mutable.lock().unwrap();
                    match st.state {
                        WorkerState::Warm | WorkerState::Running => {
                            if mark_running {
                                st.in_flight += 1;
                                st.state = WorkerState::Running;
                            }
                            st.last_active_at_ms = Utc::now().timestamp_millis();
                            let mem = st
                                .actual_memory
                                .clone()
                                .unwrap_or_else(|| worker.variant.footprint.clone());
                            let state = st.state;
                            drop(st);
                            if mark_running {
                                self.inner.emit_model_state(&worker.model_id, state, mem);
                            }
                            return Ok(WorkerLease {
                                inner: Arc::clone(&self.inner),
                                worker,
                                model_load_ms: 0.0,
                            });
                        }
                        WorkerState::Starting | WorkerState::Loading | WorkerState::Unloading => {
                            wait_needed = true;
                        }
                        WorkerState::Stopped | WorkerState::Failed => {}
                    }
                }
                if wait_needed {
                    let rem = deadline.saturating_duration_since(tokio::time::Instant::now());
                    if rem.is_zero() {
                        return Err(self.inner.record_failure(
                            ctx,
                            Some(&resolved.entry.id),
                            operation,
                            FailureStage::SchedulerQueue,
                            ErrorCode::QueueTimeout,
                            "WORKER_TRANSITION_TIMEOUT",
                            "Timed out waiting for worker state transition.",
                            None,
                            start.elapsed().as_millis() as i64,
                            None,
                        ));
                    }
                    tokio::select! {
                        _ = self.inner.state_notify.notified() => {}
                        _ = tokio::time::sleep(rem) => {}
                    }
                    continue;
                } else {
                    self.inner.stop_and_remove_worker(&resolved.entry.id).await;
                    continue;
                }
            }

            if self.inner.telemetry.memory_pressure() == MemoryPressure::Critical
                && ctx.priority == Priority::Batch
            {
                return Err(self.inner.record_failure(
                    ctx,
                    Some(&resolved.entry.id),
                    operation,
                    FailureStage::SchedulerQueue,
                    ErrorCode::InsufficientMemory,
                    "CRITICAL_MEMORY_PRESSURE",
                    "Paused cold start of batch model during critical system memory pressure.",
                    None,
                    start.elapsed().as_millis() as i64,
                    None,
                ));
            }

            let snapshots = self.inner.snapshot_loaded_workers();
            let incoming = AdmissionRequest {
                model_id: resolved.entry.id.clone(),
                footprint: self
                    .inner
                    .normalize_resource_for_profile(&resolved.variant.footprint),
            };
            let budget_limits = self.inner.budget.read().unwrap().limits.clone();
            match plan_admission(&budget_limits, &snapshots, &incoming) {
                AdmissionDecision::AdmitImmediate => {
                    let spawned = self
                        .inner
                        .spawn_and_wait_warm(resolved, ctx, operation, start)
                        .await?;
                    let load_ms = {
                        let mut st = spawned.mutable.lock().unwrap();
                        if mark_running {
                            st.in_flight += 1;
                            st.state = WorkerState::Running;
                        }
                        st.last_active_at_ms = Utc::now().timestamp_millis();
                        st.model_load_ms
                            .unwrap_or_else(|| start.elapsed().as_secs_f64() * 1000.0)
                    };
                    if mark_running {
                        self.inner.emit_model_state(
                            &spawned.model_id,
                            WorkerState::Running,
                            spawned.variant.footprint.clone(),
                        );
                    }
                    return Ok(WorkerLease {
                        inner: Arc::clone(&self.inner),
                        worker: spawned,
                        model_load_ms: load_ms,
                    });
                }
                AdmissionDecision::EvictAndAdmit { evict_model_ids } => {
                    for victim_id in evict_model_ids {
                        info!(
                            incoming = %resolved.entry.id,
                            victim = %victim_id,
                            "evicting idle worker under memory budget before load"
                        );
                        self.inner.stop_and_remove_worker(&victim_id).await;
                    }
                    continue;
                }
                AdmissionDecision::QueueWait { .. } => {
                    let rem = deadline.saturating_duration_since(tokio::time::Instant::now());
                    if rem.is_zero() {
                        return Err(self.inner.record_failure(
                            ctx,
                            Some(&resolved.entry.id),
                            operation,
                            FailureStage::SchedulerQueue,
                            ErrorCode::QueueTimeout,
                            "MEMORY_BUDGET_QUEUE_TIMEOUT",
                            "Timed out waiting for busy models to release memory budget.",
                            None,
                            start.elapsed().as_millis() as i64,
                            None,
                        ));
                    }
                    tokio::select! {
                        _ = self.inner.state_notify.notified() => {}
                        _ = tokio::time::sleep(rem) => {}
                    }
                    continue;
                }
                AdmissionDecision::RejectedExceedsBudget { missing_pools } => {
                    return Err(self.inner.record_failure(
                        ctx,
                        Some(&resolved.entry.id),
                        operation,
                        FailureStage::SchedulerQueue,
                        ErrorCode::InsufficientMemory,
                        "MODEL_EXCEEDS_HOST_BUDGET",
                        &format!(
                            "Model '{}' ({:?}) exceeds available host budget {:?} (overflowing: {:?}).",
                            resolved.entry.id,
                            resolved.variant.footprint,
                            budget_limits,
                            missing_pools
                        ),
                        None,
                        start.elapsed().as_millis() as i64,
                        None,
                    ));
                }
            }
        }
    }

    async fn acquire_compute_slot(
        &self,
        slot: ComputeSlot,
        model_id: &str,
        ctx: &RequestContext,
        operation: &str,
    ) -> Result<(SlotPermit, f64), ApiError> {
        let gate = match slot {
            ComputeSlot::Gpu { .. } => &self.inner.gpu_gate,
            ComputeSlot::Cpu => &self.inner.cpu_gate,
        };
        gate.acquire(ctx.priority, self.inner.queue_timeout)
            .await
            .map_err(|_| {
                self.inner.record_failure(
                    ctx,
                    Some(model_id),
                    operation,
                    FailureStage::SchedulerQueue,
                    ErrorCode::QueueTimeout,
                    "COMPUTE_SLOT_QUEUE_TIMEOUT",
                    "Timed out waiting in compute priority queue.",
                    None,
                    self.inner.queue_timeout.as_millis() as i64,
                    None,
                )
            })
    }

    async fn discard_failed_worker(&self, model_id: &str) {
        self.inner.stop_and_remove_worker(model_id).await;
    }

    pub async fn load_model(
        &self,
        model_id: &str,
        quant: Option<&str>,
        ctx: &RequestContext,
    ) -> Result<ModelStatusInfo, ApiError> {
        let resolved = self.resolve_model(model_id, quant, ctx, "load_model")?;
        let lease = self
            .acquire_worker_lease(&resolved, ctx, "load_model", false)
            .await?;
        drop(lease);
        self.list_models_status()
            .into_iter()
            .find(|m| m.id == model_id)
            .ok_or_else(|| {
                self.inner.record_failure(
                    ctx,
                    Some(model_id),
                    "load_model",
                    FailureStage::ModelPrepare,
                    ErrorCode::NotFound,
                    "UNKNOWN_MODEL_ID",
                    "Model vanished from registry.",
                    None,
                    0,
                    None,
                )
            })
    }

    pub async fn unload_model(
        &self,
        model_id: &str,
        ctx: &RequestContext,
    ) -> Result<ModelStatusInfo, ApiError> {
        let _ = self.inner.registry.find_model(model_id).ok_or_else(|| {
            self.inner.record_failure(
                ctx,
                Some(model_id),
                "unload_model",
                FailureStage::ModelPrepare,
                ErrorCode::NotFound,
                "UNKNOWN_MODEL_ID",
                &format!("Model '{model_id}' is not registered."),
                None,
                0,
                None,
            )
        })?;
        self.inner.stop_and_remove_worker(model_id).await;
        Ok(self
            .list_models_status()
            .into_iter()
            .find(|m| m.id == model_id)
            .unwrap())
    }

    pub async fn prewarm(
        &self,
        models: &[String],
        ctx: &RequestContext,
    ) -> Result<Vec<ModelStatusInfo>, ApiError> {
        let mut results = Vec::with_capacity(models.len());
        for model_id in models {
            results.push(self.load_model(model_id, None, ctx).await?);
        }
        Ok(results)
    }

    pub async fn unload_all(&self, include_pinned: bool) -> Vec<String> {
        let victims: Vec<String> = {
            let workers = self.inner.workers.lock().unwrap();
            workers
                .values()
                .filter(|w| {
                    include_pinned || w.mutable.lock().unwrap().pin_policy != PinPolicy::Pinned
                })
                .map(|w| w.model_id.clone())
                .collect()
        };
        for id in &victims {
            self.inner.stop_and_remove_worker(id).await;
        }
        victims
    }

    pub async fn chat_completion(
        &self,
        req: ChatCompletionRequest,
        ctx: RequestContext,
    ) -> Result<ChatCompletionResponse, ApiError> {
        self.inner.record_caller(&ctx.caller);
        let started = Instant::now();
        if req.messages.is_empty() {
            return Err(self.inner.record_failure(
                &ctx,
                Some(&req.model),
                "chat_completions",
                FailureStage::HttpAdmission,
                ErrorCode::InvalidRequest,
                "EMPTY_MESSAGES",
                "messages array must not be empty.",
                None,
                0,
                None,
            ));
        }

        let resolved = self.resolve_model(&req.model, None, &ctx, "chat_completions")?;
        if resolved.entry.capability != Capability::Llm {
            return Err(self.inner.record_failure(
                &ctx,
                Some(&req.model),
                "chat_completions",
                FailureStage::HttpAdmission,
                ErrorCode::InvalidRequest,
                "CAPABILITY_MISMATCH",
                &format!("Model '{}' is not an LLM.", req.model),
                None,
                0,
                None,
            ));
        }

        let (_slot, queue_ms) = self
            .acquire_compute_slot(
                resolved.variant.compute_slot,
                &resolved.entry.id,
                &ctx,
                "chat_completions",
            )
            .await?;
        let lease = self
            .acquire_worker_lease(&resolved, &ctx, "chat_completions", true)
            .await?;

        let worker_body = serde_json::json!({
            "model": resolved.entry.id,
            "messages": req.messages,
            "temperature": req.temperature.unwrap_or(0.0),
            "max_tokens": req.max_tokens.unwrap_or(512),
            "separate_reasoning": false,
            "prompt_cache_key": req.prompt_cache_key,
            "stream": false,
        });
        let bytes = serde_json::to_vec(&worker_body).unwrap();

        let resp = match post_json(
            lease.endpoint(),
            "/infer/chat",
            lease.token(),
            &ctx.request_id,
            &bytes,
        )
        .await
        {
            Ok(r) => r,
            Err(err) => {
                let pid = lease.pid();
                drop(lease);
                self.discard_failed_worker(&resolved.entry.id).await;
                return Err(self.inner.record_failure(
                    &ctx,
                    Some(&resolved.entry.id),
                    "chat_completions",
                    FailureStage::WorkerIo,
                    ErrorCode::WorkerCrashed,
                    "WORKER_IPC_FAILED",
                    &err,
                    None,
                    started.elapsed().as_millis() as i64,
                    Some(pid),
                ));
            }
        };

        if !(200..300).contains(&resp.status) {
            let pid = lease.pid();
            let err_msg = String::from_utf8_lossy(&resp.body).to_string();
            let fatal = resp.status >= 500;
            drop(lease);
            if fatal {
                self.discard_failed_worker(&resolved.entry.id).await;
            }
            return Err(self.inner.record_failure(
                &ctx,
                Some(&resolved.entry.id),
                "chat_completions",
                FailureStage::Inference,
                if fatal { ErrorCode::InferenceFailed } else { ErrorCode::InvalidRequest },
                "WORKER_HTTP_ERROR",
                &err_msg,
                None,
                started.elapsed().as_millis() as i64,
                Some(pid),
            ));
        }

        let raw_val: serde_json::Value = serde_json::from_slice(&resp.body).map_err(|e| {
            self.inner.record_failure(
                &ctx,
                Some(&resolved.entry.id),
                "chat_completions",
                FailureStage::ResultValidation,
                ErrorCode::InferenceFailed,
                "INVALID_WORKER_JSON",
                &format!("Failed parsing worker /infer/chat response: {e}"),
                None,
                started.elapsed().as_millis() as i64,
                Some(lease.pid()),
            )
        })?;

        let raw_text = raw_val
            .get("raw_text")
            .and_then(|v| v.as_str())
            .or_else(|| {
                raw_val
                    .get("choices")
                    .and_then(|c| c.get(0))
                    .and_then(|c| c.get("message"))
                    .and_then(|m| m.get("content"))
                    .and_then(|v| v.as_str())
            })
            .unwrap_or("")
            .to_string();

        let (reasoning, content) = split_cot_complete(&raw_text, req.separate_reasoning);

        let usage = raw_val
            .get("usage")
            .and_then(|u| serde_json::from_value::<UsageStats>(u.clone()).ok());
        let worker_timing = raw_val.get("x_acpm_timing");
        let prefill_ms = worker_timing
            .and_then(|t| t.get("prefill_ms"))
            .and_then(|v| v.as_f64());
        let decode_ms = worker_timing
            .and_then(|t| t.get("decode_ms"))
            .and_then(|v| v.as_f64())
            .unwrap_or(0.0);
        let kv_cache_hit = worker_timing
            .and_then(|t| t.get("kv_cache_hit"))
            .and_then(|v| v.as_bool());

        let finish_reason = raw_val
            .get("choices")
            .and_then(|c| c.get(0))
            .and_then(|c| c.get("finish_reason"))
            .and_then(|v| v.as_str())
            .unwrap_or("stop")
            .to_string();

        Ok(ChatCompletionResponse {
            id: raw_val
                .get("id")
                .and_then(|v| v.as_str())
                .map(ToString::to_string)
                .unwrap_or_else(|| format!("chatcmpl-{}", Uuid::new_v4().simple())),
            object: "chat.completion".to_string(),
            created: Utc::now().timestamp(),
            model: resolved.entry.id,
            choices: vec![ChatChoice {
                index: 0,
                message: ChatMessage {
                    role: "assistant".to_string(),
                    content,
                    reasoning_content: if reasoning.is_empty() {
                        None
                    } else {
                        Some(reasoning)
                    },
                },
                finish_reason,
            }],
            usage,
            x_acpm_timing: Some(TimingMetrics {
                queue_ms,
                model_load_ms: Some(lease.model_load_ms),
                prefill_ms,
                decode_ms,
                kv_cache_hit,
                voice_cache_hit: None,
            }),
        })
    }

    pub async fn chat_completion_stream(
        &self,
        req: ChatCompletionRequest,
        ctx: RequestContext,
    ) -> Result<mpsc::Receiver<Result<Event, Infallible>>, ApiError> {
        self.inner.record_caller(&ctx.caller);
        let started = Instant::now();
        if req.messages.is_empty() {
            return Err(self.inner.record_failure(
                &ctx,
                Some(&req.model),
                "chat_completions_stream",
                FailureStage::HttpAdmission,
                ErrorCode::InvalidRequest,
                "EMPTY_MESSAGES",
                "messages array must not be empty.",
                None,
                0,
                None,
            ));
        }

        let resolved = self.resolve_model(&req.model, None, &ctx, "chat_completions_stream")?;
        if resolved.entry.capability != Capability::Llm {
            return Err(self.inner.record_failure(
                &ctx,
                Some(&req.model),
                "chat_completions_stream",
                FailureStage::HttpAdmission,
                ErrorCode::InvalidRequest,
                "CAPABILITY_MISMATCH",
                &format!("Model '{}' is not an LLM.", req.model),
                None,
                0,
                None,
            ));
        }

        let (slot, queue_ms) = self
            .acquire_compute_slot(
                resolved.variant.compute_slot,
                &resolved.entry.id,
                &ctx,
                "chat_completions_stream",
            )
            .await?;
        let lease = self
            .acquire_worker_lease(&resolved, &ctx, "chat_completions_stream", true)
            .await?;

        let worker_body = serde_json::json!({
            "model": resolved.entry.id,
            "messages": req.messages,
            "temperature": req.temperature.unwrap_or(0.0),
            "max_tokens": req.max_tokens.unwrap_or(512),
            "separate_reasoning": false,
            "prompt_cache_key": req.prompt_cache_key,
            "stream": true,
        });
        let bytes = serde_json::to_vec(&worker_body).unwrap();

        let mut ndjson = match open_chat_stream(
            lease.endpoint(),
            "/infer/chat",
            lease.token(),
            &ctx.request_id,
            &bytes,
        )
        .await
        {
            Ok(s) => s,
            Err((status_opt, err_msg)) => {
                let pid = lease.pid();
                let fatal = status_opt.map(|s| s >= 500).unwrap_or(true);
                drop(lease);
                if fatal {
                    self.discard_failed_worker(&resolved.entry.id).await;
                }
                return Err(self.inner.record_failure(
                    &ctx,
                    Some(&resolved.entry.id),
                    "chat_completions_stream",
                    FailureStage::WorkerIo,
                    if fatal { ErrorCode::WorkerCrashed } else { ErrorCode::InvalidRequest },
                    "WORKER_STREAM_OPEN_FAILED",
                    &err_msg,
                    None,
                    started.elapsed().as_millis() as i64,
                    Some(pid),
                ));
            }
        };

        let (tx, rx) = mpsc::channel::<Result<Event, Infallible>>(64);
        let supervisor = self.clone();
        let model_id = resolved.entry.id;
        let separate_reasoning = req.separate_reasoning;

        tokio::spawn(async move {
            let _slot_guard = slot;
            let lease_guard = lease;
            let chat_id = format!("chatcmpl-{}", Uuid::new_v4().simple());
            let created = Utc::now().timestamp();
            let mut splitter: Option<CotStreamSplitter> = None;
            let mut sent_role = false;
            let mut done_timing: Option<TimingMetrics> = None;
            let mut done_usage: Option<UsageStats> = None;
            let mut client_disconnected = false;
            let mut worker_failed = false;

            while !client_disconnected {
                match ndjson.next_line().await {
                    Ok(Some(line)) => {
                        let Ok(ev) = serde_json::from_str::<serde_json::Value>(&line) else {
                            continue;
                        };
                        match ev.get("type").and_then(|v| v.as_str()).unwrap_or("") {
                            "start" => {
                                let starts_think = ev
                                    .get("prompt_starts_think")
                                    .and_then(|v| v.as_bool())
                                    .unwrap_or(false);
                                splitter = Some(CotStreamSplitter::new_with_initial_think(
                                    separate_reasoning,
                                    starts_think,
                                ));
                            }
                            "delta" => {
                                let text = ev.get("text").and_then(|v| v.as_str()).unwrap_or("");
                                let sp = splitter.get_or_insert_with(|| {
                                    CotStreamSplitter::new(separate_reasoning)
                                });
                                for chunk in sp.push(text) {
                                    if !emit_sse_cot_chunk(
                                        &tx,
                                        &chat_id,
                                        created,
                                        &model_id,
                                        chunk,
                                        &mut sent_role,
                                    )
                                    .await
                                    {
                                        client_disconnected = true;
                                        break;
                                    }
                                }
                            }
                            "done" => {
                                let prompt_tokens = ev
                                    .get("prompt_tokens")
                                    .and_then(|v| v.as_u64())
                                    .unwrap_or(0) as u32;
                                let completion_tokens = ev
                                    .get("completion_tokens")
                                    .and_then(|v| v.as_u64())
                                    .unwrap_or(0) as u32;
                                done_usage = Some(UsageStats {
                                    prompt_tokens,
                                    completion_tokens,
                                    total_tokens: prompt_tokens + completion_tokens,
                                });
                                done_timing = Some(TimingMetrics {
                                    queue_ms,
                                    model_load_ms: Some(lease_guard.model_load_ms),
                                    prefill_ms: ev.get("prefill_ms").and_then(|v| v.as_f64()),
                                    decode_ms: ev
                                        .get("decode_ms")
                                        .and_then(|v| v.as_f64())
                                        .unwrap_or(0.0),
                                    kv_cache_hit: ev.get("kv_cache_hit").and_then(|v| v.as_bool()),
                                    voice_cache_hit: None,
                                });
                                break;
                            }
                            "error" => {
                                worker_failed = true;
                                let detail = ev
                                    .get("detail")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("WORKER_STREAM_ERROR");
                                let msg = ev
                                    .get("message")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("Worker streaming error");
                                let api_err = supervisor.inner.record_failure(
                                    &ctx,
                                    Some(&model_id),
                                    "chat_completions_stream",
                                    FailureStage::Inference,
                                    ErrorCode::InferenceFailed,
                                    detail,
                                    msg,
                                    None,
                                    started.elapsed().as_millis() as i64,
                                    Some(lease_guard.pid()),
                                );
                                let err_payload = serde_json::json!({ "error": api_err });
                                let _ = tx
                                    .send(Ok(Event::default()
                                        .event("error")
                                        .data(err_payload.to_string())))
                                    .await;
                                break;
                            }
                            _ => {}
                        }
                    }
                    Ok(None) => break,
                    Err(err) => {
                        worker_failed = true;
                        let api_err = supervisor.inner.record_failure(
                            &ctx,
                            Some(&model_id),
                            "chat_completions_stream",
                            FailureStage::WorkerIo,
                            ErrorCode::WorkerCrashed,
                            "WORKER_STREAM_READ_FAILED",
                            &err,
                            None,
                            started.elapsed().as_millis() as i64,
                            Some(lease_guard.pid()),
                        );
                        let err_payload = serde_json::json!({ "error": api_err });
                        let _ = tx
                            .send(Ok(Event::default()
                                .event("error")
                                .data(err_payload.to_string())))
                            .await;
                        break;
                    }
                }
            }

            if !client_disconnected && !worker_failed {
                if let Some(sp) = splitter.as_mut() {
                    for chunk in sp.finish() {
                        if !emit_sse_cot_chunk(
                            &tx,
                            &chat_id,
                            created,
                            &model_id,
                            chunk,
                            &mut sent_role,
                        )
                        .await
                        {
                            client_disconnected = true;
                            break;
                        }
                    }
                }
                if !client_disconnected {
                    let mut final_obj = serde_json::json!({
                        "id": chat_id,
                        "object": "chat.completion.chunk",
                        "created": created,
                        "model": model_id,
                        "choices": [{
                            "index": 0,
                            "delta": {},
                            "finish_reason": "stop",
                        }],
                    });
                    if let Some(usage) = done_usage {
                        final_obj["usage"] = serde_json::to_value(usage).unwrap();
                    }
                    if let Some(timing) = done_timing {
                        final_obj["x_acpm_timing"] = serde_json::to_value(timing).unwrap();
                    }
                    let _ = tx
                        .send(Ok(Event::default().data(final_obj.to_string())))
                        .await;
                    let _ = tx.send(Ok(Event::default().data("[DONE]"))).await;
                }
            }

            drop(ndjson);
            drop(lease_guard);
            if worker_failed {
                supervisor.discard_failed_worker(&model_id).await;
            }
        });

        Ok(rx)
    }

    pub async fn vad(
        &self,
        req: VadRequest,
        ctx: RequestContext,
    ) -> Result<VadResponse, ApiError> {
        self.inner.record_caller(&ctx.caller);
        let started = Instant::now();
        let file_path = req.file_path.trim();
        if file_path.is_empty() || !Path::new(file_path).is_file() {
            return Err(self.inner.record_failure(
                &ctx,
                Some(&req.model),
                "vad",
                FailureStage::AudioValidation,
                ErrorCode::AudioValidationFailed,
                "AUDIO_FILE_NOT_FOUND",
                &format!("Audio file '{file_path}' does not exist or is unreadable."),
                None,
                0,
                None,
            ));
        }

        let resolved = self.resolve_model(&req.model, None, &ctx, "vad")?;
        if resolved.entry.capability != Capability::Vad {
            return Err(self.inner.record_failure(
                &ctx,
                Some(&req.model),
                "vad",
                FailureStage::HttpAdmission,
                ErrorCode::InvalidRequest,
                "CAPABILITY_MISMATCH",
                &format!("Model '{}' is not a VAD model.", req.model),
                None,
                0,
                None,
            ));
        }

        let (_slot, queue_ms) = self
            .acquire_compute_slot(resolved.variant.compute_slot, &resolved.entry.id, &ctx, "vad")
            .await?;
        let lease = self
            .acquire_worker_lease(&resolved, &ctx, "vad", true)
            .await?;

        let worker_body = serde_json::json!({
            "model": resolved.entry.id,
            "file_path": req.file_path,
            "min_speech_ms": req.min_speech_ms,
            "min_silence_ms": req.min_silence_ms,
        });
        let bytes = serde_json::to_vec(&worker_body).unwrap();

        let resp = match post_json(
            lease.endpoint(),
            "/infer/vad",
            lease.token(),
            &ctx.request_id,
            &bytes,
        )
        .await
        {
            Ok(r) => r,
            Err(err) => {
                let pid = lease.pid();
                drop(lease);
                self.discard_failed_worker(&resolved.entry.id).await;
                return Err(self.inner.record_failure(
                    &ctx,
                    Some(&resolved.entry.id),
                    "vad",
                    FailureStage::WorkerIo,
                    ErrorCode::WorkerCrashed,
                    "WORKER_IPC_FAILED",
                    &err,
                    None,
                    started.elapsed().as_millis() as i64,
                    Some(pid),
                ));
            }
        };

        if !(200..300).contains(&resp.status) {
            let pid = lease.pid();
            let err_msg = String::from_utf8_lossy(&resp.body).to_string();
            let fatal = resp.status >= 500;
            drop(lease);
            if fatal {
                self.discard_failed_worker(&resolved.entry.id).await;
            }
            return Err(self.inner.record_failure(
                &ctx,
                Some(&resolved.entry.id),
                "vad",
                FailureStage::Inference,
                if fatal {
                    ErrorCode::InferenceFailed
                } else {
                    ErrorCode::AudioValidationFailed
                },
                "WORKER_VAD_FAILED",
                &err_msg,
                None,
                started.elapsed().as_millis() as i64,
                Some(pid),
            ));
        }

        let mut parsed: VadResponse = serde_json::from_slice(&resp.body).map_err(|e| {
            self.inner.record_failure(
                &ctx,
                Some(&resolved.entry.id),
                "vad",
                FailureStage::ResultValidation,
                ErrorCode::InferenceFailed,
                "INVALID_VAD_JSON",
                &format!("Failed parsing worker VAD response: {e}"),
                None,
                started.elapsed().as_millis() as i64,
                Some(lease.pid()),
            )
        })?;

        let decode_ms = parsed
            .x_acpm_timing
            .as_ref()
            .map(|t| t.decode_ms)
            .unwrap_or(0.0);
        parsed.x_acpm_timing = Some(TimingMetrics {
            queue_ms,
            model_load_ms: Some(lease.model_load_ms),
            prefill_ms: None,
            decode_ms,
            kv_cache_hit: None,
            voice_cache_hit: None,
        });
        Ok(parsed)
    }

    async fn transcribe_single_file(
        &self,
        resolved: &ResolvedModel,
        req: &TranscriptionRequest,
        ctx: &RequestContext,
        started: Instant,
    ) -> Result<TranscriptionResponse, ApiError> {
        let (_slot, queue_ms) = self
            .acquire_compute_slot(
                resolved.variant.compute_slot,
                &resolved.entry.id,
                ctx,
                "transcriptions",
            )
            .await?;
        let lease = self
            .acquire_worker_lease(resolved, ctx, "transcriptions", true)
            .await?;

        let worker_body = serde_json::json!({
            "model": resolved.entry.id,
            "file_path": req.file_path,
            "language": req.language,
            "prompt": req.prompt,
        });
        let bytes = serde_json::to_vec(&worker_body).unwrap();

        let resp = match post_json(
            lease.endpoint(),
            "/infer/asr",
            lease.token(),
            &ctx.request_id,
            &bytes,
        )
        .await
        {
            Ok(r) => r,
            Err(err) => {
                let pid = lease.pid();
                drop(lease);
                self.discard_failed_worker(&resolved.entry.id).await;
                return Err(self.inner.record_failure(
                    ctx,
                    Some(&resolved.entry.id),
                    "transcriptions",
                    FailureStage::WorkerIo,
                    ErrorCode::WorkerCrashed,
                    "WORKER_IPC_FAILED",
                    &err,
                    None,
                    started.elapsed().as_millis() as i64,
                    Some(pid),
                ));
            }
        };

        if !(200..300).contains(&resp.status) {
            let pid = lease.pid();
            let err_msg = String::from_utf8_lossy(&resp.body).to_string();
            let fatal = resp.status >= 500;
            drop(lease);
            if fatal {
                self.discard_failed_worker(&resolved.entry.id).await;
            }
            return Err(self.inner.record_failure(
                ctx,
                Some(&resolved.entry.id),
                "transcriptions",
                FailureStage::Inference,
                if fatal { ErrorCode::InferenceFailed } else { ErrorCode::AudioValidationFailed },
                "WORKER_ASR_FAILED",
                &err_msg,
                None,
                started.elapsed().as_millis() as i64,
                Some(pid),
            ));
        }

        let mut parsed: TranscriptionResponse =
            serde_json::from_slice(&resp.body).map_err(|e| {
                self.inner.record_failure(
                    ctx,
                    Some(&resolved.entry.id),
                    "transcriptions",
                    FailureStage::ResultValidation,
                    ErrorCode::InferenceFailed,
                    "INVALID_ASR_JSON",
                    &format!("Failed parsing worker ASR response: {e}"),
                    None,
                    started.elapsed().as_millis() as i64,
                    Some(lease.pid()),
                )
            })?;

        let decode_ms = parsed
            .x_acpm_timing
            .as_ref()
            .map(|t| t.decode_ms)
            .unwrap_or(0.0);
        parsed.x_acpm_timing = Some(TimingMetrics {
            queue_ms,
            model_load_ms: Some(lease.model_load_ms),
            prefill_ms: None,
            decode_ms,
            kv_cache_hit: None,
            voice_cache_hit: None,
        });
        Ok(parsed)
    }

    pub async fn transcribe(
        &self,
        req: TranscriptionRequest,
        ctx: RequestContext,
    ) -> Result<TranscriptionResponse, ApiError> {
        self.inner.record_caller(&ctx.caller);
        let started = Instant::now();
        let file_path = req.file_path.trim();
        if file_path.is_empty() || !Path::new(file_path).is_file() {
            return Err(self.inner.record_failure(
                &ctx,
                Some(&req.model),
                "transcriptions",
                FailureStage::AudioValidation,
                ErrorCode::AudioValidationFailed,
                "AUDIO_FILE_NOT_FOUND",
                &format!("Audio file '{file_path}' does not exist or is unreadable."),
                None,
                0,
                None,
            ));
        }

        let resolved = self.resolve_model(&req.model, None, &ctx, "transcriptions")?;
        if resolved.entry.capability != Capability::Asr {
            return Err(self.inner.record_failure(
                &ctx,
                Some(&req.model),
                "transcriptions",
                FailureStage::HttpAdmission,
                ErrorCode::InvalidRequest,
                "CAPABILITY_MISMATCH",
                &format!("Model '{}' is not an ASR model.", req.model),
                None,
                0,
                None,
            ));
        }

        const VAD_CHUNK_THRESHOLD_MS: i64 = 28_000;
        const MAX_ASR_WINDOW_MS: i64 = 25_000;

        let vad_ready = req.vad_filter
            && self
                .resolve_model("speech-vad-pyannote", None, &ctx, "transcriptions")
                .is_ok();

        if vad_ready {
            // Fast path: standard WAV header already proves duration <= 28s, skipping VAD overhead.
            let known_short_wav = probe_wav_file_duration_ms(Path::new(file_path))
                .map(|dur| dur <= VAD_CHUNK_THRESHOLD_MS)
                .unwrap_or(false);
            if !known_short_wav {
                let vad_resp = self
                    .vad(
                        VadRequest {
                            model: "speech-vad-pyannote".to_string(),
                            file_path: req.file_path.clone(),
                            min_speech_ms: Some(250),
                            min_silence_ms: Some(500),
                        },
                        ctx.clone(),
                    )
                    .await?;

                if vad_resp.duration_ms > VAD_CHUNK_THRESHOLD_MS {
                    if vad_resp.segments.is_empty() {
                        return Ok(TranscriptionResponse {
                            text: String::new(),
                            language: req.language,
                            duration_ms: vad_resp.duration_ms,
                            segments: Vec::new(),
                            x_acpm_timing: vad_resp.x_acpm_timing,
                        });
                    }
                    let windows = pack_vad_windows(&vad_resp.segments, MAX_ASR_WINDOW_MS);
                    let src_path = PathBuf::from(file_path);
                    let windows_clone = windows.clone();
                    let sliced = tokio::task::spawn_blocking(move || {
                        slice_audio_windows_to_wavs(&src_path, &windows_clone)
                    })
                    .await
                    .map_err(|e| {
                        self.inner.record_failure(
                            &ctx,
                            Some(&resolved.entry.id),
                            "transcriptions",
                            FailureStage::AudioValidation,
                            ErrorCode::InferenceFailed,
                            "VAD_SLICE_PANIC",
                            &e.to_string(),
                            None,
                            started.elapsed().as_millis() as i64,
                            None,
                        )
                    })?
                    .map_err(|msg| {
                        self.inner.record_failure(
                            &ctx,
                            Some(&resolved.entry.id),
                            "transcriptions",
                            FailureStage::AudioValidation,
                            ErrorCode::AudioValidationFailed,
                            "VAD_SLICE_FAILED",
                            &msg,
                            None,
                            started.elapsed().as_millis() as i64,
                            None,
                        )
                    })?;

                    let temp_dir = sliced.temp_dir;
                    let mut combined_text = Vec::new();
                    let mut all_segments = Vec::new();
                    let mut detected_lang = req.language.clone();
                    let mut total_queue_ms = vad_resp
                        .x_acpm_timing
                        .as_ref()
                        .map(|t| t.queue_ms)
                        .unwrap_or(0.0);
                    let mut total_decode_ms = vad_resp
                        .x_acpm_timing
                        .as_ref()
                        .map(|t| t.decode_ms)
                        .unwrap_or(0.0);
                    let mut first_load_ms = None;

                    for (win, chunk_path) in sliced.chunks {
                        let chunk_req = TranscriptionRequest {
                            model: req.model.clone(),
                            file_path: chunk_path.to_string_lossy().into_owned(),
                            language: req.language.clone(),
                            vad_filter: false,
                            timestamps: req.timestamps,
                            prompt: req.prompt.clone(),
                        };
                        let chunk_res = self
                            .transcribe_single_file(&resolved, &chunk_req, &ctx, started)
                            .await;
                        let chunk_resp = match chunk_res {
                            Ok(r) => r,
                            Err(err) => {
                                let _ = std::fs::remove_dir_all(&temp_dir);
                                return Err(err);
                            }
                        };

                        if detected_lang.is_none() {
                            detected_lang = chunk_resp.language;
                        }
                        if let Some(t) = chunk_resp.x_acpm_timing {
                            total_queue_ms += t.queue_ms;
                            total_decode_ms += t.decode_ms;
                            if first_load_ms.is_none() {
                                first_load_ms = t.model_load_ms;
                            }
                        }
                        let trimmed = chunk_resp.text.trim();
                        if !trimmed.is_empty() {
                            combined_text.push(trimmed.to_string());
                        }
                        if chunk_resp.segments.is_empty() {
                            if !trimmed.is_empty() {
                                all_segments.push(TranscriptSegment {
                                    start_ms: win.start_ms,
                                    end_ms: win.end_ms,
                                    text: trimmed.to_string(),
                                });
                            }
                        } else {
                            for seg in chunk_resp.segments {
                                all_segments.push(TranscriptSegment {
                                    start_ms: win.start_ms + seg.start_ms,
                                    end_ms: (win.start_ms + seg.end_ms).min(win.end_ms),
                                    text: seg.text,
                                });
                            }
                        }
                        // Allow Interactive requests between long-audio chunks.
                        tokio::task::yield_now().await;
                    }
                    let _ = std::fs::remove_dir_all(&temp_dir);

                    return Ok(TranscriptionResponse {
                        text: combined_text.join(" "),
                        language: detected_lang,
                        duration_ms: vad_resp.duration_ms,
                        segments: all_segments,
                        x_acpm_timing: Some(TimingMetrics {
                            queue_ms: total_queue_ms,
                            model_load_ms: first_load_ms,
                            prefill_ms: None,
                            decode_ms: total_decode_ms,
                            kv_cache_hit: None,
                            voice_cache_hit: None,
                        }),
                    });
                }
            }
        }

        self.transcribe_single_file(&resolved, &req, &ctx, started)
            .await
    }

    pub async fn synthesize(
        &self,
        req: SpeechRequest,
        ctx: RequestContext,
    ) -> Result<SpeechOutput, ApiError> {
        self.inner.record_caller(&ctx.caller);
        let started = Instant::now();
        if req.input.trim().is_empty() {
            return Err(self.inner.record_failure(
                &ctx,
                Some(&req.model),
                "speech",
                FailureStage::HttpAdmission,
                ErrorCode::InvalidRequest,
                "EMPTY_INPUT_TEXT",
                "input text must not be empty.",
                None,
                0,
                None,
            ));
        }

        if let Some(ref_audio) = &req.reference_audio {
            if !ref_audio.trim().is_empty() && !Path::new(ref_audio).is_file() {
                return Err(self.inner.record_failure(
                    &ctx,
                    Some(&req.model),
                    "speech",
                    FailureStage::AudioValidation,
                    ErrorCode::AudioValidationFailed,
                    "REFERENCE_AUDIO_NOT_FOUND",
                    &format!("reference_audio '{ref_audio}' does not exist."),
                    None,
                    0,
                    None,
                ));
            }
        }

        if let Some(out_path) = &req.output_path {
            let p = Path::new(out_path);
            if out_path.trim().is_empty() {
                return Err(self.inner.record_failure(
                    &ctx,
                    Some(&req.model),
                    "speech",
                    FailureStage::HttpAdmission,
                    ErrorCode::InvalidRequest,
                    "INVALID_OUTPUT_PATH",
                    "output_path must not be empty.",
                    None,
                    0,
                    None,
                ));
            }
            if let Some(parent) = p.parent() {
                if !parent.as_os_str().is_empty() {
                    if let Err(e) = std::fs::create_dir_all(parent) {
                        return Err(self.inner.record_failure(
                            &ctx,
                            Some(&req.model),
                            "speech",
                            FailureStage::HttpAdmission,
                            ErrorCode::InvalidRequest,
                            "UNWRITABLE_OUTPUT_PATH",
                            &format!("Cannot create output directory '{}': {e}", parent.display()),
                            None,
                            0,
                            None,
                        ));
                    }
                }
            }
        }

        let resolved = self.resolve_model(&req.model, None, &ctx, "speech")?;
        if resolved.entry.capability != Capability::Tts {
            return Err(self.inner.record_failure(
                &ctx,
                Some(&req.model),
                "speech",
                FailureStage::HttpAdmission,
                ErrorCode::InvalidRequest,
                "CAPABILITY_MISMATCH",
                &format!("Model '{}' is not a TTS model.", req.model),
                None,
                0,
                None,
            ));
        }

        let (_slot, queue_ms) = self
            .acquire_compute_slot(resolved.variant.compute_slot, &resolved.entry.id, &ctx, "speech")
            .await?;
        let lease = self
            .acquire_worker_lease(&resolved, &ctx, "speech", true)
            .await?;

        let worker_body = serde_json::json!({
            "model": resolved.entry.id,
            "input": req.input,
            "voice": req.voice,
            "instruct": req.instruct,
            "reference_audio": req.reference_audio,
            "reference_text": req.reference_text,
            "x_vector_only_mode": req.x_vector_only_mode,
            "speed": req.speed,
            "response_format": req.response_format,
            "output_path": req.output_path,
        });
        let bytes = serde_json::to_vec(&worker_body).unwrap();

        let resp = match post_json(
            lease.endpoint(),
            "/infer/tts",
            lease.token(),
            &ctx.request_id,
            &bytes,
        )
        .await
        {
            Ok(r) => r,
            Err(err) => {
                let pid = lease.pid();
                drop(lease);
                self.discard_failed_worker(&resolved.entry.id).await;
                return Err(self.inner.record_failure(
                    &ctx,
                    Some(&resolved.entry.id),
                    "speech",
                    FailureStage::WorkerIo,
                    ErrorCode::WorkerCrashed,
                    "WORKER_IPC_FAILED",
                    &err,
                    None,
                    started.elapsed().as_millis() as i64,
                    Some(pid),
                ));
            }
        };

        if !(200..300).contains(&resp.status) {
            let pid = lease.pid();
            let err_msg = String::from_utf8_lossy(&resp.body).to_string();
            let fatal = resp.status >= 500;
            drop(lease);
            if fatal {
                self.discard_failed_worker(&resolved.entry.id).await;
            }
            return Err(self.inner.record_failure(
                &ctx,
                Some(&resolved.entry.id),
                "speech",
                FailureStage::Inference,
                if fatal { ErrorCode::InferenceFailed } else { ErrorCode::InvalidRequest },
                "WORKER_TTS_FAILED",
                &err_msg,
                None,
                started.elapsed().as_millis() as i64,
                Some(pid),
            ));
        }

        if req.output_path.is_some() {
            let mut file_resp: SpeechFileResponse =
                serde_json::from_slice(&resp.body).map_err(|e| {
                    self.inner.record_failure(
                        &ctx,
                        Some(&resolved.entry.id),
                        "speech",
                        FailureStage::ResultValidation,
                        ErrorCode::InferenceFailed,
                        "INVALID_TTS_JSON",
                        &format!("Failed parsing worker TTS response: {e}"),
                        None,
                        started.elapsed().as_millis() as i64,
                        Some(lease.pid()),
                    )
                })?;
            let decode_ms = file_resp
                .x_acpm_timing
                .as_ref()
                .map(|t| t.decode_ms)
                .unwrap_or(0.0);
            file_resp.x_acpm_timing = Some(TimingMetrics {
                queue_ms,
                model_load_ms: Some(lease.model_load_ms),
                prefill_ms: None,
                decode_ms,
                kv_cache_hit: None,
                voice_cache_hit: Some(file_resp.voice_cache_hit),
            });
            return Ok(SpeechOutput::File(file_resp));
        }

        let duration_ms = resp
            .headers
            .get("x-ai-audio-duration-ms")
            .and_then(|v| v.parse::<i64>().ok())
            .unwrap_or(0);
        let decode_ms = resp
            .headers
            .get("x-ai-timing-decode-ms")
            .and_then(|v| v.parse::<f64>().ok())
            .unwrap_or(0.0);
        let voice_cache_hit = resp
            .headers
            .get("x-ai-voice-cache-hit")
            .map(|v| v == "true")
            .unwrap_or(false);

        Ok(SpeechOutput::AudioBytes {
            wav: resp.body,
            duration_ms,
            decode_ms,
            voice_cache_hit,
            queue_ms,
            model_load_ms: lease.model_load_ms,
        })
    }

    pub fn start_reaper_task(&self, interval: Duration) -> tokio::task::JoinHandle<()> {
        let supervisor = self.clone();
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(interval);
            ticker.tick().await;
            loop {
                ticker.tick().await;
                supervisor.run_reaper_cycle().await;
            }
        })
    }

    pub async fn run_reaper_cycle(&self) {
        let pressure = self.inner.telemetry.memory_pressure();
        let now_ms = Utc::now().timestamp_millis();

        let workers_snapshot: Vec<Arc<ManagedWorker>> = {
            let guard = self.inner.workers.lock().unwrap();
            guard.values().cloned().collect()
        };

        let mut to_evict = Vec::new();
        for w in workers_snapshot {
            if let Ok(mem) = self.inner.telemetry.process_memory(w.pid) {
                if mem.total_mb() > 0 {
                    let mut st = w.mutable.lock().unwrap();
                    st.actual_memory = Some(mem);
                }
            }

            let (state, in_flight, last_active_at_ms, pin_policy, idle_timeout_sec) = {
                let st = w.mutable.lock().unwrap();
                (
                    st.state,
                    st.in_flight,
                    st.last_active_at_ms,
                    st.pin_policy,
                    st.idle_timeout_sec,
                )
            };
            if in_flight > 0 || state != WorkerState::Warm {
                continue;
            }

            if pressure == MemoryPressure::Critical {
                to_evict.push(w.model_id.clone());
                continue;
            }
            if pressure == MemoryPressure::Warn && w.priority != Priority::Interactive {
                to_evict.push(w.model_id.clone());
                continue;
            }
            if pressure == MemoryPressure::Warn && w.priority == Priority::Interactive {
                let _ = w.stdin_tx.send(WorkerCommand::TrimCache);
            }

            if pin_policy != PinPolicy::Pinned && idle_timeout_sec > 0 {
                let idle_ms = now_ms.saturating_sub(last_active_at_ms);
                if idle_ms >= (idle_timeout_sec as i64) * 1000 {
                    to_evict.push(w.model_id.clone());
                }
            }
        }

        for id in to_evict {
            info!(model = %id, ?pressure, "reaping idle worker");
            self.inner.stop_and_remove_worker(&id).await;
        }
    }

    pub async fn shutdown_all(&self) {
        let model_ids: Vec<String> = {
            let guard = self.inner.workers.lock().unwrap();
            guard.keys().cloned().collect()
        };
        for id in model_ids {
            self.inner.stop_and_remove_worker(&id).await;
        }
        let _ = std::fs::remove_dir_all(&self.inner.uds_dir);
    }
}

fn split_cot_complete(raw_text: &str, enabled: bool) -> (String, String) {
    let mut splitter = CotStreamSplitter::new(enabled);
    let mut reasoning = String::new();
    let mut content = String::new();
    for chunk in splitter.push(raw_text) {
        match chunk {
            CotChunk::Reasoning(r) => reasoning.push_str(&r),
            CotChunk::Content(c) => content.push_str(&c),
        }
    }
    for chunk in splitter.finish() {
        match chunk {
            CotChunk::Reasoning(r) => reasoning.push_str(&r),
            CotChunk::Content(c) => content.push_str(&c),
        }
    }
    (reasoning.trim().to_string(), content)
}

async fn emit_sse_cot_chunk(
    tx: &mpsc::Sender<Result<Event, Infallible>>,
    chat_id: &str,
    created: i64,
    model_id: &str,
    chunk: CotChunk,
    sent_role: &mut bool,
) -> bool {
    let mut delta = serde_json::Map::new();
    if !*sent_role {
        delta.insert("role".to_string(), serde_json::Value::String("assistant".to_string()));
        *sent_role = true;
    }
    match chunk {
        CotChunk::Reasoning(r) if !r.is_empty() => {
            delta.insert("reasoning_content".to_string(), serde_json::Value::String(r));
        }
        CotChunk::Content(c) if !c.is_empty() => {
            delta.insert("content".to_string(), serde_json::Value::String(c));
        }
        _ => return true,
    }
    let payload = serde_json::json!({
        "id": chat_id,
        "object": "chat.completion.chunk",
        "created": created,
        "model": model_id,
        "choices": [{
            "index": 0,
            "delta": delta,
            "finish_reason": serde_json::Value::Null,
        }],
    });
    tx.send(Ok(Event::default().data(payload.to_string())))
        .await
        .is_ok()
}

struct SlicedAudioChunks {
    temp_dir: PathBuf,
    chunks: Vec<(VadSegment, PathBuf)>,
}

fn parse_wav_chunks_from_slice(bytes: &[u8]) -> Option<(u16, u16, u32, Option<(usize, usize)>, u32)> {
    if bytes.len() < 12 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return None;
    }
    let mut pos = 12usize;
    let mut audio_format = 0u16;
    let mut channels = 0u16;
    let mut sample_rate = 0u32;
    let mut bits_per_sample = 0u16;
    let mut found_fmt = false;
    let mut data_range: Option<(usize, usize)> = None;
    let mut data_len_header = 0u32;

    while pos + 8 <= bytes.len() {
        let id = &bytes[pos..pos + 4];
        let size = u32::from_le_bytes(bytes[pos + 4..pos + 8].try_into().ok()?) as usize;
        let data_start = pos + 8;
        if id == b"fmt " {
            if data_start + size > bytes.len() || size < 16 {
                return None;
            }
            let chunk = &bytes[data_start..data_start + size];
            audio_format = u16::from_le_bytes(chunk[0..2].try_into().ok()?);
            channels = u16::from_le_bytes(chunk[2..4].try_into().ok()?);
            sample_rate = u32::from_le_bytes(chunk[4..8].try_into().ok()?);
            bits_per_sample = u16::from_le_bytes(chunk[14..16].try_into().ok()?);
            found_fmt = true;
        } else if id == b"data" {
            data_len_header = size as u32;
            let avail_end = data_start.saturating_add(size).min(bytes.len());
            data_range = Some((data_start, avail_end));
            break;
        }
        let padded = size + (size % 2);
        let Some(next) = data_start.checked_add(padded) else {
            break;
        };
        pos = next;
    }

    if !found_fmt || data_range.is_none() || sample_rate == 0 || channels == 0 || bits_per_sample == 0
    {
        return None;
    }
    Some((
        audio_format,
        (channels << 8) | bits_per_sample,
        sample_rate,
        data_range,
        data_len_header,
    ))
}

fn probe_wav_file_duration_ms(path: &Path) -> Option<i64> {
    use std::io::Read;
    let mut file = std::fs::File::open(path).ok()?;
    let mut buf = vec![0u8; 64 * 1024];
    let n = file.read(&mut buf).ok()?;
    buf.truncate(n);
    let (audio_format, chan_bits, sample_rate, _, data_len_header) =
        parse_wav_chunks_from_slice(&buf)?;
    if !(audio_format == 1 || audio_format == 3) {
        return None;
    }
    let channels = (chan_bits >> 8) as u64;
    let bits = (chan_bits & 0xff) as u64;
    let bytes_per_sec = sample_rate as u64 * channels * (bits / 8).max(1);
    if bytes_per_sec == 0 {
        return None;
    }
    Some(((data_len_header as u64 * 1000) / bytes_per_sec) as i64)
}

fn pack_vad_windows(segments: &[VadSegment], max_window_ms: i64) -> Vec<VadSegment> {
    let max_win = max_window_ms.max(1000);
    let mut split_segs = Vec::new();
    for seg in segments {
        if seg.end_ms <= seg.start_ms {
            continue;
        }
        let mut cursor = seg.start_ms;
        while cursor < seg.end_ms {
            let next_end = (cursor + max_win).min(seg.end_ms);
            split_segs.push(VadSegment {
                start_ms: cursor,
                end_ms: next_end,
            });
            cursor = next_end;
        }
    }

    let mut packed: Vec<VadSegment> = Vec::new();
    for seg in split_segs {
        if let Some(last) = packed.last_mut() {
            if seg.end_ms - last.start_ms <= max_win {
                last.end_ms = seg.end_ms;
                continue;
            }
        }
        packed.push(seg);
    }
    packed
}

fn decode_wav_mono_pcm16(bytes: &[u8]) -> Result<(u32, Vec<i16>), String> {
    if bytes.len() < 12 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return Err("Not a RIFF/WAVE file".to_string());
    }
    let mut pos = 12usize;
    let mut audio_format = 0u16;
    let mut channels = 0usize;
    let mut sample_rate = 0u32;
    let mut bits_per_sample = 0usize;
    let mut data_slice: Option<&[u8]> = None;

    while pos + 8 <= bytes.len() {
        let id = &bytes[pos..pos + 4];
        let size = u32::from_le_bytes(bytes[pos + 4..pos + 8].try_into().unwrap()) as usize;
        pos += 8;
        if pos + size > bytes.len() {
            return Err("Truncated WAV chunk".to_string());
        }
        let chunk = &bytes[pos..pos + size];
        if id == b"fmt " && chunk.len() >= 16 {
            audio_format = u16::from_le_bytes(chunk[0..2].try_into().unwrap());
            channels = u16::from_le_bytes(chunk[2..4].try_into().unwrap()) as usize;
            sample_rate = u32::from_le_bytes(chunk[4..8].try_into().unwrap());
            bits_per_sample = u16::from_le_bytes(chunk[14..16].try_into().unwrap()) as usize;
        } else if id == b"data" {
            data_slice = Some(chunk);
        }
        pos += size + (size % 2);
    }

    let data = data_slice.ok_or_else(|| "WAV missing data chunk".to_string())?;
    if sample_rate == 0 || channels == 0 || bits_per_sample == 0 {
        return Err("Invalid WAV fmt parameters".to_string());
    }

    let frame_bytes = channels * (bits_per_sample / 8);
    if frame_bytes == 0 {
        return Err("Invalid WAV frame size".to_string());
    }
    let num_frames = data.len() / frame_bytes;
    let mut mono = Vec::with_capacity(num_frames);

    match (audio_format, bits_per_sample) {
        (1, 16) => {
            for frame in data.chunks_exact(frame_bytes) {
                let mut acc = 0i32;
                for ch in 0..channels {
                    let s = i16::from_le_bytes(frame[ch * 2..ch * 2 + 2].try_into().unwrap());
                    acc += s as i32;
                }
                mono.push((acc / channels as i32) as i16);
            }
        }
        (3, 32) => {
            for frame in data.chunks_exact(frame_bytes) {
                let mut acc = 0.0f32;
                for ch in 0..channels {
                    let s = f32::from_le_bytes(frame[ch * 4..ch * 4 + 4].try_into().unwrap());
                    acc += s;
                }
                let scaled = (acc / channels as f32).clamp(-1.0, 1.0) * i16::MAX as f32;
                mono.push(scaled.round() as i16);
            }
        }
        _ => return Err(format!("Unsupported WAV format={audio_format} bits={bits_per_sample}")),
    }
    Ok((sample_rate, mono))
}

fn encode_mono_pcm16_wav(sample_rate: u32, samples: &[i16]) -> Vec<u8> {
    let data_bytes = (samples.len() * 2) as u32;
    let riff_size = 36 + data_bytes;
    let mut out = Vec::with_capacity(44 + data_bytes as usize);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&riff_size.to_le_bytes());
    out.extend_from_slice(b"WAVE");
    out.extend_from_slice(b"fmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&sample_rate.to_le_bytes());
    out.extend_from_slice(&(sample_rate * 2).to_le_bytes());
    out.extend_from_slice(&2u16.to_le_bytes());
    out.extend_from_slice(&16u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_bytes.to_le_bytes());
    for &s in samples {
        out.extend_from_slice(&s.to_le_bytes());
    }
    out
}

fn slice_audio_windows_to_wavs(
    src: &Path,
    windows: &[VadSegment],
) -> Result<SlicedAudioChunks, String> {
    let temp_dir = std::env::temp_dir().join(format!("acpmd-vad-chunks-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&temp_dir)
        .map_err(|e| format!("Failed creating VAD temp dir {}: {e}", temp_dir.display()))?;

    let decode_res = (|| -> Result<(u32, Vec<i16>), String> {
        if let Ok(raw) = std::fs::read(src) {
            if let Ok(decoded) = decode_wav_mono_pcm16(&raw) {
                return Ok(decoded);
            }
        }
        let norm_wav = temp_dir.join("normalized.wav");
        let output = std::process::Command::new("ffmpeg")
            .arg("-y")
            .arg("-v")
            .arg("error")
            .arg("-i")
            .arg(src)
            .arg("-ac")
            .arg("1")
            .arg("-ar")
            .arg("16000")
            .arg("-c:a")
            .arg("pcm_s16le")
            .arg(&norm_wav)
            .output()
            .map_err(|e| format!("Failed invoking ffmpeg to normalize long audio: {e}"))?;
        if !output.status.success() || !norm_wav.is_file() {
            return Err(format!(
                "Failed normalizing audio '{}': {}",
                src.display(),
                String::from_utf8_lossy(&output.stderr).trim()
            ));
        }
        let norm_bytes = std::fs::read(&norm_wav)
            .map_err(|e| format!("Failed reading normalized audio: {e}"))?;
        let _ = std::fs::remove_file(&norm_wav);
        decode_wav_mono_pcm16(&norm_bytes)
    })();

    let (sample_rate, mono_samples) = match decode_res {
        Ok(ok) => ok,
        Err(err) => {
            let _ = std::fs::remove_dir_all(&temp_dir);
            return Err(err);
        }
    };

    let mut chunks = Vec::with_capacity(windows.len());
    for (idx, win) in windows.iter().enumerate() {
        let start_idx = ((win.start_ms.max(0) as u64 * sample_rate as u64) / 1000) as usize;
        let end_idx = ((win.end_ms.max(0) as u64 * sample_rate as u64) / 1000) as usize;
        let clamped_start = start_idx.min(mono_samples.len());
        let clamped_end = end_idx.min(mono_samples.len());
        if clamped_end <= clamped_start {
            continue;
        }
        let wav_bytes = encode_mono_pcm16_wav(sample_rate, &mono_samples[clamped_start..clamped_end]);
        let chunk_path = temp_dir.join(format!("chunk_{idx:03}.wav"));
        if let Err(e) = std::fs::write(&chunk_path, wav_bytes) {
            let _ = std::fs::remove_dir_all(&temp_dir);
            return Err(format!("Failed writing audio chunk: {e}"));
        }
        chunks.push((win.clone(), chunk_path));
    }

    Ok(SlicedAudioChunks { temp_dir, chunks })
}

#[cfg(test)]
mod tests {
    use super::*;
    use acpm_pal::mock::MockTelemetry;
    use std::sync::Mutex as StdMutex;

    fn write_mock_worker_script(dir: &Path) -> PathBuf {
        let script = dir.join("mock_worker.py");
        let code = r#"#!/usr/bin/env python3
import json, os, signal, socket, sys, threading, time

args = sys.argv[1:]
def arg_val(flag, default=""):
    if flag in args:
        idx = args.index(flag)
        if idx + 1 < len(args):
            return args[idx + 1]
    return default

mode = arg_val("--mode", "llm")
ipc_path = arg_val("--ipc-path")
stop_event = threading.Event()

def emit(obj):
    sys.stdout.write("ACPM_FRAME\t" + json.dumps(obj) + "\n")
    sys.stdout.flush()

emit({"type": "state", "state": "STARTING", "ts_ms": 1})
emit({"type": "state", "state": "LOADING", "ts_ms": 2})

if os.path.exists(ipc_path):
    os.remove(ipc_path)
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(ipc_path)
srv.listen(8)
srv.settimeout(0.2)

emit({"type": "state", "state": "WARM", "ts_ms": 3, "model_load_ms": 12.5, "memory": {"unified_mb": 2048}})

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
        conn.close()
    except socket.timeout:
        pass
    except OSError:
        break

emit({"type": "state", "state": "UNLOADING", "ts_ms": 4})
srv.close()
if os.path.exists(ipc_path):
    os.remove(ipc_path)
sys.exit(0)
"#;
        std::fs::write(&script, code).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        script
    }

    fn setup_fake_model(dir: &Path, name: &str, quant_bits: Option<u64>) -> PathBuf {
        let mdir = dir.join(name);
        std::fs::create_dir_all(&mdir).unwrap();
        let cfg = match quant_bits {
            Some(bits) => format!(r#"{{"quantization":{{"bits":{bits}}}}}"#),
            None => r#"{"torch_dtype":"bfloat16"}"#.to_string(),
        };
        std::fs::write(mdir.join("config.json"), cfg).unwrap();
        std::fs::write(mdir.join("model.safetensors"), b"stub").unwrap();
        mdir
    }

    #[tokio::test]
    async fn priority_slot_gate_dispatches_interactive_ahead_of_batch() {
        let gate = PrioritySlotGate::new(1);
        let (first, _) = gate.acquire(Priority::Normal, Duration::from_secs(2)).await.unwrap();
        let order = Arc::new(StdMutex::new(Vec::<&'static str>::new()));

        let g1 = Arc::clone(&gate);
        let o1 = Arc::clone(&order);
        let h_batch = tokio::spawn(async move {
            let (_p, _) = g1.acquire(Priority::Batch, Duration::from_secs(2)).await.unwrap();
            o1.lock().unwrap().push("batch");
        });

        let g2 = Arc::clone(&gate);
        let o2 = Arc::clone(&order);
        let h_inter = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(15)).await;
            let (_p, _) = g2.acquire(Priority::Interactive, Duration::from_secs(2)).await.unwrap();
            o2.lock().unwrap().push("interactive");
        });

        tokio::time::sleep(Duration::from_millis(50)).await;
        drop(first);

        h_batch.await.unwrap();
        h_inter.await.unwrap();
        assert_eq!(*order.lock().unwrap(), vec!["interactive", "batch"]);
    }

    #[tokio::test]
    async fn idle_ttl_and_budget_eviction_manage_mock_workers() {
        let tmp = std::env::temp_dir().join(format!("acpmd-sup-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&tmp).unwrap();
        let mock_bin = write_mock_worker_script(&tmp);
        let llm_dir = setup_fake_model(&tmp, "llm-8bit", Some(8));
        let tts_dir = setup_fake_model(&tmp, "tts-bf16", None);

        let mut overrides = BTreeMap::new();
        overrides.insert(
            "yanmo-correct-4b-cot".to_string(),
            ModelOverrideConfig {
                path: llm_dir,
                quant: Some("8bit".to_string()),
                idle_timeout_sec: Some(1),
                pin_policy: None,
            },
        );
        overrides.insert(
            "qwen3-tts-1.7b".to_string(),
            ModelOverrideConfig {
                path: tts_dir,
                quant: Some("bf16".to_string()),
                idle_timeout_sec: Some(10),
                pin_policy: None,
            },
        );

        let registry = ModelRegistry::embedded_default().unwrap();
        let profile = MockTelemetry::mac_16gb().host_profile().unwrap();
        let paths = RuntimePaths::from_data_dir(&tmp);
        let diagnostics = Arc::new(DiagnosticsStore::open(&paths.diagnostics_db));

        // 13000 MB budget: LLM (5265) fits alone, TTS (12509) fits alone, together (17774) exceeds 13000 -> forces eviction!
        let supervisor = RuntimeSupervisor::new(
            registry,
            profile,
            paths,
            Arc::new(MockTelemetry::mac_16gb()),
            diagnostics,
            SupervisorConfig {
                worker_mlx_bin: Some(mock_bin),
                worker_speech_bin: None,
                model_overrides: overrides,
                budget_tier: BudgetTier::Balanced,
                budget_override_mb: Some(13000),
                default_idle_timeout_override: None,
                queue_timeout: Duration::from_secs(10),
                startup_timeout: Duration::from_secs(10),
            },
        );

        let ctx = RequestContext {
            request_id: "r1".to_string(),
            caller: "test".to_string(),
            priority: Priority::Interactive,
        };

        let llm_status = supervisor.load_model("yanmo-correct-4b-cot", None, &ctx).await.unwrap();
        assert_eq!(llm_status.state, WorkerState::Warm);

        // Loading TTS exceeds 13000 budget with LLM warm -> evicts LLM before loading TTS!
        let tts_status = supervisor.load_model("qwen3-tts-1.7b", None, &ctx).await.unwrap();
        assert_eq!(tts_status.state, WorkerState::Warm);

        let statuses = supervisor.list_models_status();
        let llm_after = statuses.iter().find(|m| m.id == "yanmo-correct-4b-cot").unwrap();
        assert_eq!(llm_after.state, WorkerState::Stopped);

        // Test idle TTL reaper on LLM after reloading it (idle_timeout_sec=1)
        supervisor.unload_all(true).await;
        supervisor.load_model("yanmo-correct-4b-cot", None, &ctx).await.unwrap();
        tokio::time::sleep(Duration::from_millis(1200)).await;
        supervisor.run_reaper_cycle().await;
        let llm_reaped = supervisor
            .list_models_status()
            .into_iter()
            .find(|m| m.id == "yanmo-correct-4b-cot")
            .unwrap();
        assert_eq!(llm_reaped.state, WorkerState::Stopped);

        supervisor.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&tmp);
    }

    fn write_vad_asr_mock_worker(dir: &Path, log_file: &Path) -> PathBuf {
        let script = dir.join("vad_asr_mock.py");
        let code = format!(
            r#"#!/usr/bin/env python3
import json, os, signal, socket, sys, threading

args = sys.argv[1:]
def arg_val(flag, default=""):
    if flag in args:
        idx = args.index(flag)
        if idx + 1 < len(args):
            return args[idx + 1]
    return default

mode = arg_val("--mode", "speech")
ipc_path = arg_val("--ipc-path")
log_path = {log_path:?}
stop_event = threading.Event()
asr_idx = [0]

def emit(obj):
    sys.stdout.write("ACPM_FRAME\t" + json.dumps(obj) + "\n")
    sys.stdout.flush()

emit({{"type": "state", "state": "STARTING", "ts_ms": 1}})
emit({{"type": "state", "state": "LOADING", "ts_ms": 2}})
if os.path.exists(ipc_path):
    os.remove(ipc_path)
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(ipc_path)
srv.listen(8)
srv.settimeout(0.1)
mem = {{"system_ram_mb": 140}} if mode == "speech" else {{"unified_mb": 2048}}
emit({{"type": "state", "state": "WARM", "ts_ms": 3, "model_load_ms": 4.0, "memory": mem}})

def handle_conn(conn):
    try:
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = conn.recv(4096)
            if not chunk:
                return
            buf += chunk
        head, rest = buf.split(b"\r\n\r\n", 1)
        lines = head.decode("utf-8", errors="replace").split("\r\n")
        path = lines[0].split(" ")[1]
        clen = 0
        for l in lines[1:]:
            if l.lower().startswith("content-length:"):
                clen = int(l.split(":", 1)[1].strip())
        while len(rest) < clen:
            chunk = conn.recv(4096)
            if not chunk:
                break
            rest += chunk
        payload = json.loads(rest[:clen].decode("utf-8"))

        if path == "/infer/vad":
            with open(log_path, "a", encoding="utf-8") as f:
                f.write(json.dumps({{"op": "vad", "file": payload["file_path"]}}) + "\n")
            resp = json.dumps({{
                "segments": [
                    {{"start_ms": 1000, "end_ms": 15000}},
                    {{"start_ms": 18000, "end_ms": 33000}}
                ],
                "duration_ms": 34000,
                "x_acpm_timing": {{"queue_ms": 0.0, "decode_ms": 15.0}}
            }}).encode("utf-8")
        elif path == "/infer/asr":
            asr_idx[0] += 1
            n = asr_idx[0]
            with open(log_path, "a", encoding="utf-8") as f:
                f.write(json.dumps({{"op": "asr", "file": payload["file_path"]}}) + "\n")
            resp = json.dumps({{
                "text": f"chunk-{{n}}",
                "language": "zh",
                "duration_ms": 14000,
                "segments": [{{"start_ms": 0, "end_ms": 5000, "text": f"chunk-{{n}}"}}],
                "x_acpm_timing": {{"queue_ms": 0.0, "decode_ms": 20.0}}
            }}).encode("utf-8")
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
srv.close()
if os.path.exists(ipc_path):
    os.remove(ipc_path)
sys.exit(0)
"#,
            log_path = log_file.to_string_lossy()
        );
        std::fs::write(&script, code).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        script
    }

    #[tokio::test]
    async fn long_audio_transcribe_uses_vad_chunking() {
        let tmp = std::env::temp_dir().join(format!("acpm-vad-chunk-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&tmp).unwrap();
        let log_file = tmp.join("calls.jsonl");
        let mock_bin = write_vad_asr_mock_worker(&tmp, &log_file);

        let vad_dir = tmp.join("vad-pyannote");
        std::fs::create_dir_all(&vad_dir).unwrap();
        std::fs::write(vad_dir.join("segmentation.onnx"), b"onnx-stub").unwrap();
        let asr_dir = setup_fake_model(&tmp, "asr-8bit", Some(8));

        let mut overrides = BTreeMap::new();
        overrides.insert(
            "speech-vad-pyannote".to_string(),
            ModelOverrideConfig {
                path: vad_dir,
                quant: None,
                idle_timeout_sec: Some(60),
                pin_policy: None,
            },
        );
        overrides.insert(
            "qwen3-asr-1.7b".to_string(),
            ModelOverrideConfig {
                path: asr_dir,
                quant: Some("8bit".to_string()),
                idle_timeout_sec: Some(60),
                pin_policy: None,
            },
        );

        let paths = RuntimePaths::from_data_dir(&tmp);
        let diagnostics = Arc::new(DiagnosticsStore::open(&paths.diagnostics_db));
        let supervisor = RuntimeSupervisor::new(
            ModelRegistry::embedded_default().unwrap(),
            MockTelemetry::mac_16gb().host_profile().unwrap(),
            paths,
            Arc::new(MockTelemetry::mac_16gb()),
            diagnostics,
            SupervisorConfig {
                worker_mlx_bin: Some(mock_bin.clone()),
                worker_speech_bin: Some(mock_bin),
                model_overrides: overrides,
                budget_tier: BudgetTier::Balanced,
                budget_override_mb: Some(12000),
                default_idle_timeout_override: None,
                queue_timeout: Duration::from_secs(10),
                startup_timeout: Duration::from_secs(10),
            },
        );

        // 34-second 16kHz WAV file (>28s threshold triggers CPU VAD + <=25s chunked ASR).
        let long_wav = tmp.join("long.wav");
        let wav_bytes = encode_mono_pcm16_wav(16_000, &vec![0i16; 16_000 * 34]);
        std::fs::write(&long_wav, wav_bytes).unwrap();

        let resp = supervisor
            .transcribe(
                TranscriptionRequest {
                    model: "qwen3-asr-1.7b".to_string(),
                    file_path: long_wav.to_string_lossy().into_owned(),
                    language: Some("zh".to_string()),
                    vad_filter: true,
                    timestamps: true,
                    prompt: None,
                },
                RequestContext {
                    request_id: "long-asr-1".to_string(),
                    caller: "test".to_string(),
                    priority: Priority::Interactive,
                },
            )
            .await
            .unwrap();

        assert_eq!(resp.text, "chunk-1 chunk-2");
        assert_eq!(resp.duration_ms, 34_000);
        assert_eq!(resp.segments.len(), 2);
        assert_eq!(resp.segments[0].start_ms, 1000);
        assert_eq!(resp.segments[0].end_ms, 6000);
        assert_eq!(resp.segments[1].start_ms, 18000);
        assert_eq!(resp.segments[1].end_ms, 23000);

        let calls: Vec<String> = std::fs::read_to_string(&log_file)
            .unwrap()
            .lines()
            .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
            .filter_map(|v| v.get("op").and_then(|s| s.as_str()).map(ToOwned::to_owned))
            .collect();
        assert_eq!(calls, vec!["vad", "asr", "asr"]);

        supervisor.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test]
    async fn updates_system_and_model_config_and_persists_to_disk() {
        let tmp = std::env::temp_dir().join(format!("acpm-cfg-live-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&tmp).unwrap();
        let paths = RuntimePaths::from_data_dir(&tmp);
        let diagnostics = Arc::new(DiagnosticsStore::open(&paths.diagnostics_db));
        let supervisor = RuntimeSupervisor::new(
            ModelRegistry::embedded_default().unwrap(),
            MockTelemetry::mac_16gb().host_profile().unwrap(),
            paths.clone(),
            Arc::new(MockTelemetry::mac_16gb()),
            diagnostics,
            SupervisorConfig {
                worker_mlx_bin: None,
                worker_speech_bin: None,
                model_overrides: BTreeMap::new(),
                budget_tier: BudgetTier::Balanced,
                budget_override_mb: None,
                default_idle_timeout_override: None,
                queue_timeout: Duration::from_secs(5),
                startup_timeout: Duration::from_secs(5),
            },
        );

        let updated_sys = supervisor
            .update_system_config(
                UpdateSystemConfigRequest {
                    budget_tier: Some(BudgetTier::Eco),
                    budget_override_mb: None,
                    clear_budget_override: false,
                },
                "http://127.0.0.1:18790".to_string(),
                Some("acpm.local".to_string()),
                Some("http://acpm.local:18790".to_string()),
            )
            .unwrap();
        assert_eq!(updated_sys.budget_tier, BudgetTier::Eco);
        assert_eq!(supervisor.system_status().budget, updated_sys.effective_budget);

        let ctx = RequestContext {
            request_id: "cfg-1".to_string(),
            caller: "test".to_string(),
            priority: Priority::Normal,
        };
        let model_info = supervisor
            .update_model_config(
                "yanmo-correct-4b-cot",
                UpdateModelConfigRequest {
                    pin_policy: Some(PinPolicy::Pinned),
                    idle_timeout_sec: Some(2400),
                    quant: Some("4bit".to_string()),
                    path: None,
                },
                &ctx,
            )
            .unwrap();
        assert_eq!(model_info.pin_policy, PinPolicy::Pinned);
        assert_eq!(model_info.idle_timeout_sec, 2400);
        assert!(model_info.available_quants.contains(&"4bit".to_string()));

        let reloaded = DaemonFileConfig::load_if_exists(&paths.config_json).unwrap();
        assert_eq!(reloaded.budget_tier, Some(BudgetTier::Eco));
        let ov = reloaded.model_overrides.get("yanmo-correct-4b-cot").unwrap();
        assert_eq!(ov.pin_policy, Some(PinPolicy::Pinned));
        assert_eq!(ov.idle_timeout_sec, Some(2400));
        assert_eq!(ov.quant.as_deref(), Some("4bit"));

        supervisor.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
