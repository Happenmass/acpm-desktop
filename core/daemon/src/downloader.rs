use crate::supervisor::{RequestContext, RuntimeSupervisor};
use acpm_protocol::{
    ApiError, Capability, ErrorCode, FailureStage, ModelDownloadState, ModelDownloadStatus,
    ModelFile,
};
use acpm_registry::{ModelRegistry, RegistryError};
use chrono::Utc;
use futures_util::StreamExt;
use reqwest::{header, Client, StatusCode};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Component, Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::AsyncWriteExt;
use tokio::sync::watch;
use uuid::Uuid;

#[derive(Debug, Clone)]
pub enum DownloadError {
    InvalidRequest { code: &'static str, message: String },
    NotFound { code: &'static str, message: String },
    NotImplemented { code: &'static str, message: String },
    UnsupportedPlatform { message: String },
    Internal { code: &'static str, message: String },
}

impl DownloadError {
    pub fn into_api_error(self, request_id: &str) -> ApiError {
        match self {
            Self::InvalidRequest { code, message } => ApiError::new(
                ErrorCode::InvalidRequest,
                FailureStage::ModelPrepare,
                code,
                message,
                request_id,
            ),
            Self::NotFound { code, message } => ApiError::new(
                ErrorCode::NotFound,
                FailureStage::ModelPrepare,
                code,
                message,
                request_id,
            ),
            Self::NotImplemented { code, message } => ApiError::new(
                ErrorCode::NotImplemented,
                FailureStage::HttpAdmission,
                code,
                message,
                request_id,
            ),
            Self::UnsupportedPlatform { message } => ApiError::new(
                ErrorCode::UnsupportedPlatform,
                FailureStage::ModelPrepare,
                "UNSUPPORTED_PLATFORM",
                message,
                request_id,
            ),
            Self::Internal { code, message } => ApiError::new(
                ErrorCode::InferenceFailed,
                FailureStage::ModelPrepare,
                code,
                message,
                request_id,
            ),
        }
    }
}

struct DownloadEntry {
    state: Mutex<ModelDownloadState>,
    cancel_tx: watch::Sender<bool>,
}

impl DownloadEntry {
    fn snapshot(&self) -> ModelDownloadState {
        self.state.lock().unwrap().clone()
    }

    fn update_and_emit<F>(&self, supervisor: &RuntimeSupervisor, f: F) -> ModelDownloadState
    where
        F: FnOnce(&mut ModelDownloadState),
    {
        let snap = {
            let mut st = self.state.lock().unwrap();
            f(&mut st);
            st.updated_at = Utc::now().to_rfc3339();
            st.clone()
        };
        supervisor.emit_download_progress(&snap);
        snap
    }
}

#[derive(Serialize)]
struct CompleteMarker {
    model_id: String,
    variant_id: String,
    completed_at: String,
    files: Vec<String>,
}

#[derive(Clone)]
pub struct DownloadManager {
    supervisor: RuntimeSupervisor,
    client: Client,
    tasks: Arc<Mutex<BTreeMap<String, Arc<DownloadEntry>>>>,
}

impl DownloadManager {
    pub fn new(supervisor: RuntimeSupervisor) -> Self {
        let client = Client::builder()
            .user_agent("acpmd/0.1")
            .connect_timeout(Duration::from_secs(20))
            .build()
            .unwrap_or_else(|_| Client::new());
        Self {
            supervisor,
            client,
            tasks: Arc::new(Mutex::new(BTreeMap::new())),
        }
    }

    pub fn list_downloads(&self) -> Vec<ModelDownloadState> {
        self.tasks
            .lock()
            .unwrap()
            .values()
            .map(|e| e.snapshot())
            .collect()
    }

    pub fn get_download(&self, model_id: &str) -> Option<ModelDownloadState> {
        self.tasks
            .lock()
            .unwrap()
            .get(model_id)
            .map(|e| e.snapshot())
    }

    pub fn start_download(
        &self,
        model_id: &str,
        quant: Option<String>,
        request_id: String,
        caller: String,
    ) -> Result<ModelDownloadState, DownloadError> {
        let platform = self.supervisor.profile().platform.clone();
        let (entry, variant) = self
            .supervisor
            .registry()
            .resolve_variant(model_id, &platform, quant.as_deref())
            .map_err(|e| match e {
                RegistryError::ModelNotFound(id) => DownloadError::NotFound {
                    code: "UNKNOWN_MODEL_ID",
                    message: format!("Model '{id}' is not registered."),
                },
                RegistryError::UnsupportedPlatform {
                    model_id,
                    platform,
                } => DownloadError::UnsupportedPlatform {
                    message: format!("No compatible variant of '{model_id}' for '{platform}'."),
                },
                other => DownloadError::Internal {
                    code: "REGISTRY_ERROR",
                    message: other.to_string(),
                },
            })?;

        if entry.capability == Capability::Diarization {
            return Err(DownloadError::NotImplemented {
                code: "DIARIZATION_DEFERRED",
                message: "Speaker diarization is deferred in the current phase; only VAD is enabled."
                    .to_string(),
            });
        }
        if variant.files.is_empty() {
            return Err(DownloadError::InvalidRequest {
                code: "NO_VARIANT_FILES",
                message: format!(
                    "Variant '{}' has no downloadable files declared.",
                    variant.variant_id
                ),
            });
        }

        if let Some(existing) = self.tasks.lock().unwrap().get(model_id).cloned() {
            let cur = existing.snapshot();
            if matches!(
                cur.status,
                ModelDownloadStatus::Queued
                    | ModelDownloadStatus::Downloading
                    | ModelDownloadStatus::Verifying
            ) {
                return Ok(cur);
            }
        }

        let variant = variant.clone();
        let variant_dir = ModelRegistry::variant_dir(
            &self.supervisor.paths().models_dir,
            &entry.id,
            &variant,
        );
        let total_bytes: u64 = variant.files.iter().map(|f| f.size).sum();
        let files_total = variant.files.len();

        let initial = ModelDownloadState {
            model_id: entry.id.clone(),
            variant_id: variant.variant_id.clone(),
            status: ModelDownloadStatus::Queued,
            downloaded_bytes: 0,
            total_bytes,
            current_file: variant.files.first().map(|f| f.path.clone()),
            files_completed: 0,
            files_total,
            sha256_verified: false,
            error: None,
            updated_at: Utc::now().to_rfc3339(),
        };

        let (cancel_tx, cancel_rx) = watch::channel(false);
        let dl_entry = Arc::new(DownloadEntry {
            state: Mutex::new(initial.clone()),
            cancel_tx,
        });
        self.tasks
            .lock()
            .unwrap()
            .insert(entry.id.clone(), Arc::clone(&dl_entry));
        self.supervisor.emit_download_progress(&initial);

        let mgr = self.clone();
        let model_id_owned = entry.id.clone();
        tokio::spawn(async move {
            mgr.run_download_task(
                model_id_owned,
                variant.variant_id,
                variant.files,
                variant_dir,
                request_id,
                caller,
                dl_entry,
                cancel_rx,
            )
            .await;
        });

        Ok(initial)
    }

    #[allow(clippy::too_many_arguments)]
    async fn run_download_task(
        self,
        model_id: String,
        variant_id: String,
        files: Vec<ModelFile>,
        variant_dir: PathBuf,
        request_id: String,
        caller: String,
        entry: Arc<DownloadEntry>,
        mut cancel_rx: watch::Receiver<bool>,
    ) {
        if let Err(err) = std::fs::create_dir_all(&variant_dir) {
            entry.update_and_emit(&self.supervisor, |st| {
                st.status = ModelDownloadStatus::Failed;
                st.error = Some(format!(
                    "Failed creating model directory {}: {err}",
                    variant_dir.display()
                ));
            });
            return;
        }

        let mut completed_prefix_bytes = 0u64;
        for (idx, file_spec) in files.iter().enumerate() {
            if *cancel_rx.borrow() {
                entry.update_and_emit(&self.supervisor, |st| {
                    st.status = ModelDownloadStatus::Cancelled;
                });
                return;
            }

            let rel_path = match validate_safe_rel_path(&file_spec.path) {
                Ok(p) => p,
                Err(msg) => {
                    entry.update_and_emit(&self.supervisor, |st| {
                        st.status = ModelDownloadStatus::Failed;
                        st.error = Some(msg);
                    });
                    return;
                }
            };
            let dest_path = variant_dir.join(&rel_path);
            let part_path = partial_file_path(&dest_path);

            if let Some(parent) = dest_path.parent() {
                if let Err(err) = std::fs::create_dir_all(parent) {
                    entry.update_and_emit(&self.supervisor, |st| {
                        st.status = ModelDownloadStatus::Failed;
                        st.error = Some(format!("Failed creating file parent dir: {err}"));
                    });
                    return;
                }
            }

            // Skip files already present cleanly with verified size & SHA-256.
            if let Ok(meta) = std::fs::metadata(&dest_path) {
                if meta.is_file() && meta.len() == file_spec.size {
                    let check_path = dest_path.clone();
                    let expected_sha = file_spec.sha256.clone();
                    let matches = tokio::task::spawn_blocking(move || {
                        compute_file_sha256(&check_path)
                            .map(|h| h.eq_ignore_ascii_case(&expected_sha))
                            .unwrap_or(false)
                    })
                    .await
                    .unwrap_or(false);
                    if matches {
                        completed_prefix_bytes += file_spec.size;
                        entry.update_and_emit(&self.supervisor, |st| {
                            st.status = ModelDownloadStatus::Downloading;
                            st.downloaded_bytes = completed_prefix_bytes;
                            st.current_file = Some(file_spec.path.clone());
                            st.files_completed = idx + 1;
                        });
                        continue;
                    }
                }
            }

            let outcome = self
                .download_single_file(
                    &model_id,
                    file_spec,
                    &dest_path,
                    &part_path,
                    completed_prefix_bytes,
                    idx,
                    &request_id,
                    &caller,
                    &entry,
                    &mut cancel_rx,
                )
                .await;

            match outcome {
                FileOutcome::Completed => {
                    completed_prefix_bytes += file_spec.size;
                    entry.update_and_emit(&self.supervisor, |st| {
                        st.downloaded_bytes = completed_prefix_bytes;
                        st.files_completed = idx + 1;
                    });
                }
                FileOutcome::Cancelled => {
                    entry.update_and_emit(&self.supervisor, |st| {
                        st.status = ModelDownloadStatus::Cancelled;
                    });
                    return;
                }
                FileOutcome::Failed(err_msg) => {
                    entry.update_and_emit(&self.supervisor, |st| {
                        st.status = ModelDownloadStatus::Failed;
                        st.error = Some(err_msg);
                    });
                    return;
                }
            }
        }

        let marker = CompleteMarker {
            model_id: model_id.clone(),
            variant_id,
            completed_at: Utc::now().to_rfc3339(),
            files: files.iter().map(|f| f.path.clone()).collect(),
        };
        if let Err(err) = write_complete_marker(&variant_dir, &marker) {
            entry.update_and_emit(&self.supervisor, |st| {
                st.status = ModelDownloadStatus::Failed;
                st.error = Some(format!("Failed writing .complete.json: {err}"));
            });
            return;
        }

        entry.update_and_emit(&self.supervisor, |st| {
            st.status = ModelDownloadStatus::Completed;
            st.downloaded_bytes = st.total_bytes.max(completed_prefix_bytes);
            st.files_completed = st.files_total;
            st.sha256_verified = true;
            st.current_file = None;
            st.error = None;
        });
    }

    #[allow(clippy::too_many_arguments)]
    async fn download_single_file(
        &self,
        model_id: &str,
        file_spec: &ModelFile,
        dest_path: &Path,
        part_path: &Path,
        base_bytes: u64,
        file_idx: usize,
        request_id: &str,
        caller: &str,
        entry: &Arc<DownloadEntry>,
        cancel_rx: &mut watch::Receiver<bool>,
    ) -> FileOutcome {
        let mut existing_len = std::fs::metadata(part_path)
            .ok()
            .filter(|m| m.is_file())
            .map(|m| m.len())
            .unwrap_or(0);
        if existing_len > file_spec.size {
            let _ = std::fs::remove_file(part_path);
            existing_len = 0;
        }

        if existing_len < file_spec.size {
            let mut req_builder = self.client.get(&file_spec.url);
            if existing_len > 0 {
                req_builder = req_builder.header(header::RANGE, format!("bytes={existing_len}-"));
            }

            let resp = match tokio::select! {
                r = req_builder.send() => Some(r),
                _ = cancel_rx.changed() => None,
            } {
                Some(Ok(r)) => r,
                Some(Err(e)) => {
                    return FileOutcome::Failed(format!(
                        "HTTP request failed for '{}': {e}",
                        file_spec.path
                    ));
                }
                None => return FileOutcome::Cancelled,
            };

            let status = resp.status();
            let (mut file, mut written) = if status == StatusCode::PARTIAL_CONTENT && existing_len > 0
            {
                let f = match tokio::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(part_path)
                    .await
                {
                    Ok(f) => f,
                    Err(e) => return FileOutcome::Failed(format!("Failed opening part file: {e}")),
                };
                (f, existing_len)
            } else if status.is_success() {
                let f = match tokio::fs::File::create(part_path).await {
                    Ok(f) => f,
                    Err(e) => return FileOutcome::Failed(format!("Failed creating part file: {e}")),
                };
                (f, 0u64)
            } else {
                return FileOutcome::Failed(format!(
                    "Download failed for '{}' with HTTP status {}",
                    file_spec.path, status
                ));
            };

            entry.update_and_emit(&self.supervisor, |st| {
                st.status = ModelDownloadStatus::Downloading;
                st.downloaded_bytes = base_bytes + written;
                st.current_file = Some(file_spec.path.clone());
                st.files_completed = file_idx;
            });

            let mut stream = resp.bytes_stream();
            let mut last_emit_at = Instant::now();
            let mut last_emit_bytes = written;

            loop {
                tokio::select! {
                    changed = cancel_rx.changed() => {
                        if changed.is_ok() && *cancel_rx.borrow() {
                            let _ = file.flush().await;
                            return FileOutcome::Cancelled;
                        }
                    }
                    chunk_opt = stream.next() => {
                        match chunk_opt {
                            Some(Ok(chunk)) => {
                                if let Err(e) = file.write_all(&chunk).await {
                                    return FileOutcome::Failed(format!("Disk write failed for '{}': {e}", file_spec.path));
                                }
                                written += chunk.len() as u64;
                                if written.saturating_sub(last_emit_bytes) >= 256 * 1024 || last_emit_at.elapsed() >= Duration::from_millis(250) {
                                    last_emit_bytes = written;
                                    last_emit_at = Instant::now();
                                    entry.update_and_emit(&self.supervisor, |st| {
                                        st.status = ModelDownloadStatus::Downloading;
                                        st.downloaded_bytes = base_bytes + written;
                                    });
                                }
                            }
                            Some(Err(e)) => {
                                let _ = file.flush().await;
                                return FileOutcome::Failed(format!("Download stream error for '{}': {e}", file_spec.path));
                            }
                            None => break,
                        }
                    }
                }
            }

            if let Err(e) = file.flush().await {
                return FileOutcome::Failed(format!("Failed flushing '{}': {e}", file_spec.path));
            }
            drop(file);
        }

        if *cancel_rx.borrow() {
            return FileOutcome::Cancelled;
        }

        entry.update_and_emit(&self.supervisor, |st| {
            st.status = ModelDownloadStatus::Verifying;
            st.downloaded_bytes = base_bytes + file_spec.size;
            st.current_file = Some(file_spec.path.clone());
        });

        let actual_len = std::fs::metadata(part_path).map(|m| m.len()).unwrap_or(0);
        if actual_len != file_spec.size {
            let _ = std::fs::remove_file(part_path);
            let msg = format!(
                "SIZE_MISMATCH for '{}': expected {} bytes, got {} bytes.",
                file_spec.path, file_spec.size, actual_len
            );
            self.supervisor.record_external_failure(
                request_id,
                caller,
                Some(model_id),
                "model_download",
                FailureStage::ModelPrepare,
                ErrorCode::InvalidRequest,
                "SIZE_MISMATCH",
                &msg,
            );
            return FileOutcome::Failed(msg);
        }

        let check_part = part_path.to_path_buf();
        let actual_sha = match tokio::task::spawn_blocking(move || compute_file_sha256(&check_part))
            .await
        {
            Ok(Ok(s)) => s,
            Ok(Err(e)) => {
                let _ = std::fs::remove_file(part_path);
                return FileOutcome::Failed(format!("Failed hashing '{}': {e}", file_spec.path));
            }
            Err(e) => {
                let _ = std::fs::remove_file(part_path);
                return FileOutcome::Failed(format!("Hash task panicked: {e}"));
            }
        };

        if !actual_sha.eq_ignore_ascii_case(&file_spec.sha256) {
            let _ = std::fs::remove_file(part_path);
            let msg = format!(
                "SHA256_MISMATCH for '{}': expected {}, got {}.",
                file_spec.path, file_spec.sha256, actual_sha
            );
            self.supervisor.record_external_failure(
                request_id,
                caller,
                Some(model_id),
                "model_download",
                FailureStage::ModelPrepare,
                ErrorCode::InvalidRequest,
                "SHA256_MISMATCH",
                &msg,
            );
            return FileOutcome::Failed(msg);
        }

        if let Err(e) = std::fs::rename(part_path, dest_path) {
            return FileOutcome::Failed(format!(
                "Failed promoting '{}' into place: {e}",
                file_spec.path
            ));
        }

        FileOutcome::Completed
    }

    pub fn cancel_download(&self, model_id: &str) -> Result<ModelDownloadState, DownloadError> {
        let entry = self
            .tasks
            .lock()
            .unwrap()
            .get(model_id)
            .cloned()
            .ok_or_else(|| DownloadError::NotFound {
                code: "DOWNLOAD_NOT_FOUND",
                message: format!("No download task found for '{model_id}'."),
            })?;
        let current = entry.snapshot();
        if matches!(
            current.status,
            ModelDownloadStatus::Completed
                | ModelDownloadStatus::Failed
                | ModelDownloadStatus::Cancelled
        ) {
            return Ok(current);
        }
        let _ = entry.cancel_tx.send(true);
        Ok(entry.update_and_emit(&self.supervisor, |st| {
            st.status = ModelDownloadStatus::Cancelled;
        }))
    }

    pub fn cancel_all_active(&self) {
        let entries: Vec<Arc<DownloadEntry>> =
            self.tasks.lock().unwrap().values().cloned().collect();
        for entry in entries {
            let _ = entry.cancel_tx.send(true);
        }
    }

    pub async fn delete_model(
        &self,
        model_id: &str,
        quant: Option<&str>,
        ctx: &RequestContext,
    ) -> Result<(), DownloadError> {
        let Some(_entry) = self.supervisor.registry().find_model(model_id) else {
            return Err(DownloadError::NotFound {
                code: "UNKNOWN_MODEL_ID",
                message: format!("Model '{model_id}' is not registered."),
            });
        };

        let _ = self.cancel_download(model_id);
        let managed_root = self.supervisor.paths().models_dir.join(model_id);

        if self.supervisor.is_external_model_path(model_id) && !managed_root.exists() {
            return Err(DownloadError::InvalidRequest {
                code: "EXTERNAL_MODEL_PATH_PROTECTED",
                message: format!(
                    "Model '{model_id}' points to an external local path; only daemon-managed downloads under '{}' can be deleted.",
                    self.supervisor.paths().models_dir.display()
                ),
            });
        }

        let _ = self.supervisor.unload_model(model_id, ctx).await;

        if let Some(q) = quant {
            if let Ok((_, variant)) = self.supervisor.registry().resolve_variant(
                model_id,
                &self.supervisor.profile().platform,
                Some(q),
            ) {
                let vdir = ModelRegistry::variant_dir(
                    &self.supervisor.paths().models_dir,
                    model_id,
                    variant,
                );
                if vdir.exists() {
                    std::fs::remove_dir_all(&vdir).map_err(|e| DownloadError::Internal {
                        code: "MODEL_DELETE_FAILED",
                        message: format!("Failed deleting '{}': {e}", vdir.display()),
                    })?;
                }
            }
            if managed_root.is_dir() {
                let is_empty = std::fs::read_dir(&managed_root)
                    .map(|mut it| it.next().is_none())
                    .unwrap_or(false);
                if is_empty {
                    let _ = std::fs::remove_dir(&managed_root);
                }
            }
        } else if managed_root.exists() {
            std::fs::remove_dir_all(&managed_root).map_err(|e| DownloadError::Internal {
                code: "MODEL_DELETE_FAILED",
                message: format!("Failed deleting '{}': {e}", managed_root.display()),
            })?;
        }

        self.tasks.lock().unwrap().remove(model_id);
        Ok(())
    }
}

enum FileOutcome {
    Completed,
    Cancelled,
    Failed(String),
}

fn partial_file_path(dest: &Path) -> PathBuf {
    let fname = dest
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("model.bin");
    dest.with_file_name(format!("{fname}.part"))
}

fn validate_safe_rel_path(raw: &str) -> Result<PathBuf, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err("Empty model file path in manifest.".to_string());
    }
    let path = Path::new(trimmed);
    if path.is_absolute() {
        return Err(format!("Absolute path forbidden in model manifest: '{trimmed}'"));
    }
    let mut clean = PathBuf::new();
    for comp in path.components() {
        match comp {
            Component::Normal(p) => clean.push(p),
            Component::CurDir => {}
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => {
                return Err(format!("Path traversal forbidden in manifest: '{trimmed}'"));
            }
        }
    }
    if clean.as_os_str().is_empty() {
        return Err(format!("Invalid relative file path: '{trimmed}'"));
    }
    Ok(clean)
}

fn compute_file_sha256(path: &Path) -> std::io::Result<String> {
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 64 * 1024];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    let digest = hasher.finalize();
    let mut hex = String::with_capacity(digest.len() * 2);
    for b in digest {
        hex.push_str(&format!("{b:02x}"));
    }
    Ok(hex)
}

fn write_complete_marker(variant_dir: &Path, marker: &CompleteMarker) -> std::io::Result<()> {
    let target = variant_dir.join(".complete.json");
    let tmp = variant_dir.join(format!(".complete.json.tmp.{}", Uuid::new_v4()));
    let bytes = serde_json::to_vec_pretty(marker)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    std::fs::write(&tmp, bytes)?;
    std::fs::rename(&tmp, &target)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::ModelOverrideConfig;
    use crate::diagnostics::DiagnosticsStore;
    use crate::supervisor::SupervisorConfig;
    use acpm_pal::mock::MockTelemetry;
    use acpm_pal::{RuntimePaths, SystemTelemetry};
    use acpm_protocol::{BudgetTier, Priority};
    use axum::body::Body;
    use axum::extract::State as AxumState;
    use axum::http::{HeaderMap as AxumHeaders, Response};
    use axum::routing::get;
    use axum::Router;
    use std::sync::atomic::{AtomicBool, Ordering};
    use tokio::net::TcpListener;

    #[derive(Clone)]
    struct RangeServerState {
        payload: Arc<Vec<u8>>,
        saw_range_resume: Arc<AtomicBool>,
    }

    async fn serve_weights(
        AxumState(state): AxumState<RangeServerState>,
        headers: AxumHeaders,
    ) -> Response<Body> {
        if let Some(range_val) = headers.get(header::RANGE).and_then(|v| v.to_str().ok()) {
            if let Some(rest) = range_val.strip_prefix("bytes=") {
                if let Some(start_str) = rest.strip_suffix('-') {
                    if let Ok(start) = start_str.parse::<usize>() {
                        if start < state.payload.len() {
                            state.saw_range_resume.store(true, Ordering::SeqCst);
                            let slice = state.payload[start..].to_vec();
                            let total = state.payload.len();
                            return Response::builder()
                                .status(StatusCode::PARTIAL_CONTENT)
                                .header(
                                    header::CONTENT_RANGE,
                                    format!("bytes {start}-{}/{total}", total - 1),
                                )
                                .body(Body::from(slice))
                                .unwrap();
                        }
                    }
                }
            }
        }
        Response::builder()
            .status(StatusCode::OK)
            .body(Body::from(state.payload.as_ref().clone()))
            .unwrap()
    }

    fn sha256_hex(data: &[u8]) -> String {
        let digest = Sha256::digest(data);
        let mut s = String::with_capacity(64);
        for b in digest {
            s.push_str(&format!("{b:02x}"));
        }
        s
    }

    fn test_manifest_json(url: &str, size: usize, sha256: &str) -> String {
        format!(
            r#"{{
  "schema_version": 1,
  "models": [
    {{
      "id": "speech-vad-pyannote",
      "capability": "vad",
      "display_name": "Test VAD",
      "description": "Test",
      "features": {{"supports_cot": false, "supports_prompt_cache": false, "supports_voice_clone": false}},
      "lifecycle": {{"default_priority": "normal", "idle_timeout_sec": 300, "pin_policy": "auto"}},
      "variants": [
        {{
          "variant_id": "any-cpu-onnx",
          "platform": "any",
          "accelerator": "cpu",
          "engine": "onnx",
          "compute_slot": {{"type": "cpu"}},
          "footprint": {{"unified_mb": 140, "system_ram_mb": 140}},
          "disk_mb": 1,
          "files": [
            {{
              "path": "segmentation.onnx",
              "size": {size},
              "sha256": "{sha256}",
              "url": "{url}"
            }}
          ]
        }}
      ]
    }}
  ]
}}"#
        )
    }

    async fn spawn_range_server(payload: Vec<u8>) -> (String, Arc<AtomicBool>, tokio::task::JoinHandle<()>) {
        let saw_range = Arc::new(AtomicBool::new(false));
        let st = RangeServerState {
            payload: Arc::new(payload),
            saw_range_resume: Arc::clone(&saw_range),
        };
        let app = Router::new()
            .route("/segmentation.onnx", get(serve_weights))
            .with_state(st);
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let handle = tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });
        (format!("http://{addr}/segmentation.onnx"), saw_range, handle)
    }

    fn make_supervisor(tmp: &Path, manifest_json: &str) -> RuntimeSupervisor {
        let registry = ModelRegistry::from_json_str(manifest_json).unwrap();
        let paths = RuntimePaths::from_data_dir(tmp);
        let diagnostics = Arc::new(DiagnosticsStore::open(&paths.diagnostics_db));
        RuntimeSupervisor::new(
            registry,
            MockTelemetry::mac_16gb().host_profile().unwrap(),
            paths,
            Arc::new(MockTelemetry::mac_16gb()),
            diagnostics,
            SupervisorConfig {
                worker_mlx_bin: None,
                worker_speech_bin: None,
                model_overrides: BTreeMap::<String, ModelOverrideConfig>::new(),
                budget_tier: BudgetTier::Balanced,
                budget_override_mb: None,
                default_idle_timeout_override: None,
                queue_timeout: Duration::from_secs(5),
                startup_timeout: Duration::from_secs(5),
            },
        )
    }

    #[tokio::test]
    async fn resumes_partial_download_and_verifies_sha256_then_deletes() {
        let tmp = std::env::temp_dir().join(format!("acpm-dl-ok-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&tmp).unwrap();

        let payload: Vec<u8> = (0..128 * 1024).map(|i| (i % 251) as u8).collect();
        let expected_sha = sha256_hex(&payload);
        let (url, saw_range, srv_handle) = spawn_range_server(payload.clone()).await;

        let manifest = test_manifest_json(&url, payload.len(), &expected_sha);
        let supervisor = make_supervisor(&tmp, &manifest);
        let downloader = DownloadManager::new(supervisor.clone());

        // Seed first half as an interrupted .part file to exercise HTTP Range resume.
        let vdir = tmp.join("models/speech-vad-pyannote/any-cpu-onnx");
        std::fs::create_dir_all(&vdir).unwrap();
        let half = payload.len() / 2;
        std::fs::write(vdir.join("segmentation.onnx.part"), &payload[..half]).unwrap();

        let started = downloader
            .start_download(
                "speech-vad-pyannote",
                None,
                "dl-1".to_string(),
                "test".to_string(),
            )
            .unwrap();
        assert_eq!(started.model_id, "speech-vad-pyannote");

        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        let final_st = loop {
            let st = downloader.get_download("speech-vad-pyannote").unwrap();
            if matches!(
                st.status,
                ModelDownloadStatus::Completed
                    | ModelDownloadStatus::Failed
                    | ModelDownloadStatus::Cancelled
            ) {
                break st;
            }
            assert!(tokio::time::Instant::now() < deadline, "download timed out");
            tokio::time::sleep(Duration::from_millis(20)).await;
        };

        assert_eq!(final_st.status, ModelDownloadStatus::Completed);
        assert!(final_st.sha256_verified);
        assert!(saw_range.load(Ordering::SeqCst));
        assert_eq!(std::fs::read(vdir.join("segmentation.onnx")).unwrap(), payload);
        assert!(vdir.join(".complete.json").is_file());
        assert!(!vdir.join("segmentation.onnx.part").exists());

        let models = supervisor.list_models_status();
        assert!(models.iter().find(|m| m.id == "speech-vad-pyannote").unwrap().installed);

        let ctx = RequestContext {
            request_id: "del-1".to_string(),
            caller: "test".to_string(),
            priority: Priority::Normal,
        };
        downloader
            .delete_model("speech-vad-pyannote", None, &ctx)
            .await
            .unwrap();
        assert!(!tmp.join("models/speech-vad-pyannote").exists());

        srv_handle.abort();
        supervisor.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test]
    async fn rejects_sha256_mismatch_and_cleans_corrupt_part_file() {
        let tmp = std::env::temp_dir().join(format!("acpm-dl-bad-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&tmp).unwrap();

        let payload = vec![7u8; 4096];
        let (url, _, srv_handle) = spawn_range_server(payload.clone()).await;
        let bad_sha = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
        let manifest = test_manifest_json(&url, payload.len(), bad_sha);
        let supervisor = make_supervisor(&tmp, &manifest);
        let downloader = DownloadManager::new(supervisor.clone());

        downloader
            .start_download(
                "speech-vad-pyannote",
                None,
                "dl-bad".to_string(),
                "test".to_string(),
            )
            .unwrap();

        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        let final_st = loop {
            let st = downloader.get_download("speech-vad-pyannote").unwrap();
            if matches!(
                st.status,
                ModelDownloadStatus::Completed
                    | ModelDownloadStatus::Failed
                    | ModelDownloadStatus::Cancelled
            ) {
                break st;
            }
            assert!(tokio::time::Instant::now() < deadline, "download timed out");
            tokio::time::sleep(Duration::from_millis(20)).await;
        };

        assert_eq!(final_st.status, ModelDownloadStatus::Failed);
        assert!(final_st
            .error
            .as_deref()
            .unwrap_or("")
            .contains("SHA256_MISMATCH"));
        let vdir = tmp.join("models/speech-vad-pyannote/any-cpu-onnx");
        assert!(!vdir.join("segmentation.onnx.part").exists());
        assert!(!vdir.join("segmentation.onnx").exists());
        assert!(!vdir.join(".complete.json").exists());
        assert_eq!(supervisor.recent_failures(5)[0].detail, "SHA256_MISMATCH");

        srv_handle.abort();
        supervisor.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
