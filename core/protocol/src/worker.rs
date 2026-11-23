use crate::error::FailureStage;
use crate::model::WorkerState;
use crate::resource::ResourceVector;
use serde::{Deserialize, Serialize};

pub const FRAME_PREFIX: &str = "ACPM_FRAME\t";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkerMode {
    Llm,
    Asr,
    Tts,
    Speech,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum WorkerFrame {
    State {
        state: WorkerState,
        #[serde(default)]
        ts_ms: i64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        model_load_ms: Option<f64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        memory: Option<ResourceVector>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        ipc_endpoint: Option<String>,
    },
    Metric {
        memory: ResourceVector,
        #[serde(default)]
        kv_cache_entries: usize,
        #[serde(default)]
        voice_cache_entries: usize,
    },
    Error {
        stage: FailureStage,
        detail: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        native_code: Option<String>,
        #[serde(default)]
        fatal: bool,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "cmd", rename_all = "snake_case")]
pub enum WorkerCommand {
    Shutdown,
    TrimCache,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkerLaunchConfig {
    pub mode: WorkerMode,
    pub model_id: String,
    pub model_dir: String,
    pub ipc_path: String,
    pub auth_token_env: String,
    pub memory_limit_mb: u64,
    pub threads: usize,
}
