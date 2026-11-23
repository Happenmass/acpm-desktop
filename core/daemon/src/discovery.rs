use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuntimeDiscovery {
    pub version: u32,
    pub pid: u32,
    pub started_at: String,
    pub http_base_url: String,
    pub native_ipc_path: String,
    pub token: String,
    pub platform: String,
    pub capabilities: Vec<String>,
}

impl RuntimeDiscovery {
    pub fn new(
        http_base_url: String,
        native_ipc_path: String,
        token: String,
        platform: String,
    ) -> Self {
        Self {
            version: 1,
            pid: std::process::id(),
            started_at: Utc::now().to_rfc3339(),
            http_base_url,
            native_ipc_path,
            token,
            platform,
            capabilities: vec![
                "llm".to_string(),
                "asr".to_string(),
                "tts".to_string(),
                "vad".to_string(),
                "diarization".to_string(),
            ],
        }
    }
}

pub struct DiscoveryGuard {
    path: PathBuf,
}

impl DiscoveryGuard {
    pub fn write_atomic(path: &Path, info: &RuntimeDiscovery) -> io::Result<Self> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let tmp_name = format!(
            "{}.tmp.{}",
            path.file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("runtime.json"),
            std::process::id()
        );
        let tmp_path = path.with_file_name(tmp_name);
        let payload = serde_json::to_vec_pretty(info)
            .map_err(|err| io::Error::new(io::ErrorKind::InvalidData, err))?;
        fs::write(&tmp_path, payload)?;

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&tmp_path, fs::Permissions::from_mode(0o600))?;
        }

        fs::rename(&tmp_path, path)?;
        Ok(Self {
            path: path.to_path_buf(),
        })
    }
}

impl Drop for DiscoveryGuard {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}
