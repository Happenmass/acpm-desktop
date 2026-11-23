use crate::model::{Capability, PinPolicy, WorkerState};
use crate::resource::{MemoryPressure, ResourceVector, ThermalState};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct TimingMetrics {
    pub queue_ms: f64,
    pub model_load_ms: Option<f64>,
    pub prefill_ms: Option<f64>,
    pub decode_ms: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kv_cache_hit: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub voice_cache_hit: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChatMessage {
    pub role: String,
    pub content: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reasoning_content: Option<String>,
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChatCompletionRequest {
    pub model: String,
    pub messages: Vec<ChatMessage>,
    #[serde(default)]
    pub stream: bool,
    #[serde(default)]
    pub temperature: Option<f32>,
    #[serde(default)]
    pub max_tokens: Option<u32>,
    #[serde(default = "default_true")]
    pub separate_reasoning: bool,
    #[serde(default)]
    pub prompt_cache_key: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChatChoice {
    pub index: u32,
    pub message: ChatMessage,
    pub finish_reason: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UsageStats {
    pub prompt_tokens: u32,
    pub completion_tokens: u32,
    pub total_tokens: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChatCompletionResponse {
    pub id: String,
    pub object: String,
    pub created: i64,
    pub model: String,
    pub choices: Vec<ChatChoice>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usage: Option<UsageStats>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub x_acpm_timing: Option<TimingMetrics>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TranscriptionRequest {
    pub model: String,
    pub file_path: String,
    #[serde(default)]
    pub language: Option<String>,
    #[serde(default = "default_true")]
    pub vad_filter: bool,
    #[serde(default = "default_true")]
    pub timestamps: bool,
    #[serde(default)]
    pub prompt: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TranscriptSegment {
    pub start_ms: i64,
    pub end_ms: i64,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TranscriptionResponse {
    pub text: String,
    pub language: Option<String>,
    pub duration_ms: i64,
    #[serde(default)]
    pub segments: Vec<TranscriptSegment>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub x_acpm_timing: Option<TimingMetrics>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SpeechRequest {
    pub model: String,
    pub input: String,
    #[serde(default)]
    pub voice: Option<String>,
    #[serde(default)]
    pub instruct: Option<String>,
    #[serde(default)]
    pub reference_audio: Option<String>,
    #[serde(default)]
    pub reference_text: Option<String>,
    #[serde(default)]
    pub x_vector_only_mode: bool,
    #[serde(default)]
    pub speed: Option<f32>,
    #[serde(default)]
    pub response_format: Option<String>,
    #[serde(default)]
    pub output_path: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SpeechFileResponse {
    pub output_path: String,
    pub bytes: u64,
    pub sample_rate: u32,
    pub duration_ms: i64,
    pub voice_cache_hit: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub x_acpm_timing: Option<TimingMetrics>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VoiceProfile {
    pub voice_id: String,
    pub name: String,
    pub reference_text: Option<String>,
    pub language: Option<String>,
    pub duration_ms: i64,
    pub sha256: String,
    pub created_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VadSegment {
    pub start_ms: i64,
    pub end_ms: i64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VadResponse {
    pub segments: Vec<VadSegment>,
    pub duration_ms: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub x_acpm_timing: Option<TimingMetrics>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SpeakerTurn {
    pub start_ms: i64,
    pub end_ms: i64,
    pub speaker: i32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DiarizationResponse {
    pub turns: Vec<SpeakerTurn>,
    pub speaker_count: usize,
    pub warning: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub x_acpm_timing: Option<TimingMetrics>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelStatusInfo {
    pub id: String,
    pub capability: Capability,
    pub display_name: String,
    pub selected_variant: Option<String>,
    pub installed: bool,
    pub state: WorkerState,
    pub pin_policy: PinPolicy,
    pub idle_timeout_sec: u64,
    pub memory: ResourceVector,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SystemStatusResponse {
    pub platform: String,
    pub pid: u32,
    pub budget: ResourceVector,
    pub used: ResourceVector,
    pub memory_pressure: MemoryPressure,
    pub thermal_state: ThermalState,
    pub loaded_models: Vec<ModelStatusInfo>,
    pub active_requests: usize,
    pub queued_requests: usize,
    pub caller_counts: BTreeMap<String, u64>,
}
