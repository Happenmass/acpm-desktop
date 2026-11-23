use acpm_protocol::DiagnosticFailure;
use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use tracing::warn;

const MAX_FAILURE_ENTRIES: usize = 100;

/// Metadata-only ring buffer for recent inference/supervisor failures.
/// Never stores prompts, audio payloads, or model outputs.
pub struct DiagnosticsStore {
    path: PathBuf,
    entries: Mutex<VecDeque<DiagnosticFailure>>,
}

impl DiagnosticsStore {
    pub fn open(path: impl AsRef<Path>) -> Self {
        let path = path.as_ref().to_path_buf();
        let initial = Self::load_existing(&path);
        Self {
            path,
            entries: Mutex::new(initial),
        }
    }

    fn load_existing(path: &Path) -> VecDeque<DiagnosticFailure> {
        let Ok(raw) = std::fs::read_to_string(path) else {
            return VecDeque::new();
        };
        let Ok(mut items) = serde_json::from_str::<VecDeque<DiagnosticFailure>>(&raw) else {
            return VecDeque::new();
        };
        while items.len() > MAX_FAILURE_ENTRIES {
            items.pop_front();
        }
        items
    }

    pub fn record(&self, failure: DiagnosticFailure) {
        let snapshot: Vec<DiagnosticFailure> = {
            let Ok(mut guard) = self.entries.lock() else {
                return;
            };
            if guard.len() >= MAX_FAILURE_ENTRIES {
                guard.pop_front();
            }
            guard.push_back(failure);
            guard.iter().cloned().collect()
        };

        if let Err(err) = self.persist(&snapshot) {
            warn!(error = %err, "failed to persist redacted diagnostics");
        }
    }

    pub fn recent(&self, limit: usize) -> Vec<DiagnosticFailure> {
        let Ok(guard) = self.entries.lock() else {
            return Vec::new();
        };
        guard.iter().rev().take(limit).cloned().collect()
    }

    fn persist(&self, snapshot: &[DiagnosticFailure]) -> std::io::Result<()> {
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let tmp = self
            .path
            .with_extension(format!("json.tmp.{}", std::process::id()));
        let json = serde_json::to_vec_pretty(snapshot)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        std::fs::write(&tmp, json)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
        }
        std::fs::rename(&tmp, &self.path)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use acpm_protocol::{ErrorCode, FailureStage};
    use uuid::Uuid;

    #[test]
    fn keeps_bounded_ring_and_persists_redacted_records() {
        let dir = std::env::temp_dir().join(format!("acpmd-diag-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let db_path = dir.join("diagnostics.json");

        let store = DiagnosticsStore::open(&db_path);
        for i in 0..105 {
            store.record(DiagnosticFailure {
                timestamp_ms: i,
                request_id: format!("req-{i}"),
                caller: "test".to_string(),
                model_id: Some("yanmo-correct-4b-cot".to_string()),
                operation: "chat_completions".to_string(),
                stage: FailureStage::Inference,
                code: ErrorCode::InferenceFailed,
                detail: "SYNTHETIC".to_string(),
                native_code: None,
                elapsed_ms: 10,
                worker_pid: Some(42),
            });
        }

        let latest = store.recent(20);
        assert_eq!(latest.len(), 20);
        assert_eq!(latest[0].request_id, "req-104");

        let reloaded = DiagnosticsStore::open(&db_path);
        assert_eq!(reloaded.recent(200).len(), 100);
        assert_eq!(reloaded.recent(1)[0].request_id, "req-104");

        let _ = std::fs::remove_dir_all(&dir);
    }
}
