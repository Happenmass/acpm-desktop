use crate::resource::{ComputeSlot, Priority, ResourceVector};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Capability {
    Llm,
    Asr,
    Tts,
    Vad,
    Diarization,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum WorkerState {
    #[default]
    Stopped,
    Starting,
    Loading,
    Warm,
    Running,
    Unloading,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum PinPolicy {
    #[default]
    Auto,
    Pinned,
    Ephemeral,
}

impl PinPolicy {
    /// Lower rank is evicted earlier. Pinned models must never be evicted automatically.
    pub fn eviction_rank(&self) -> Option<u8> {
        match self {
            Self::Ephemeral => Some(0),
            Self::Auto => Some(1),
            Self::Pinned => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelFeatures {
    #[serde(default)]
    pub supports_cot: bool,
    #[serde(default)]
    pub supports_prompt_cache: bool,
    #[serde(default)]
    pub supports_voice_clone: bool,
    #[serde(default)]
    pub sample_rate_hz: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LifecyclePolicy {
    #[serde(default)]
    pub default_priority: Priority,
    pub idle_timeout_sec: u64,
    #[serde(default)]
    pub pin_policy: PinPolicy,
    #[serde(default)]
    pub kv_cache_slots: usize,
    #[serde(default)]
    pub voice_cache_slots: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelFile {
    pub path: String,
    pub size: u64,
    pub sha256: String,
    pub url: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelVariant {
    pub variant_id: String,
    pub platform: String,
    pub accelerator: String,
    #[serde(default)]
    pub quant: Option<String>,
    pub engine: String,
    pub compute_slot: ComputeSlot,
    pub footprint: ResourceVector,
    pub disk_mb: u64,
    pub files: Vec<ModelFile>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelEntry {
    pub id: String,
    pub capability: Capability,
    pub display_name: String,
    pub description: String,
    pub features: ModelFeatures,
    pub lifecycle: LifecyclePolicy,
    pub variants: Vec<ModelVariant>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RegistryManifest {
    pub schema_version: u32,
    pub models: Vec<ModelEntry>,
}
