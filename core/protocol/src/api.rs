use crate::model::{Capability, PinPolicy, WorkerState};
use crate::resource::{BudgetTier, MemoryPressure, ResourceVector, ThermalState};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct TimingMetrics {
    #[serde(default)]
    pub queue_ms: f64,
    #[serde(default)]
    pub model_load_ms: Option<f64>,
    #[serde(default)]
    pub prefill_ms: Option<f64>,
    #[serde(default)]
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
    pub duration_ms: i64,
    pub sha256: String,
    pub created_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateVoiceRequest {
    pub name: String,
    pub reference_audio: String,
    #[serde(default)]
    pub reference_text: Option<String>,
    #[serde(default)]
    pub language: Option<String>,
    #[serde(default)]
    pub notes: Option<String>,
}

fn default_vad_model() -> String {
    "speech-vad-pyannote".to_string()
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VadRequest {
    #[serde(default = "default_vad_model")]
    pub model: String,
    pub file_path: String,
    #[serde(default)]
    pub min_speech_ms: Option<i64>,
    #[serde(default)]
    pub min_silence_ms: Option<i64>,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SpeechBatchStatus {
    Queued,
    Running,
    Paused,
    Completed,
    CompletedWithErrors,
    Cancelled,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SpeechBatchItemState {
    Pending,
    Running,
    Completed,
    Failed,
    Cancelled,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SpeechBatchItemInput {
    pub id: String,
    pub text: String,
    pub output_file: String,
    #[serde(default)]
    pub instruct: Option<String>,
}

fn default_tts_model() -> String {
    "qwen3-tts-1.7b".to_string()
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CreateSpeechBatchRequest {
    #[serde(default = "default_tts_model")]
    pub model: String,
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
    pub output_dir: String,
    pub items: Vec<SpeechBatchItemInput>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SpeechBatchItemStatus {
    pub id: String,
    pub output_path: String,
    pub status: SpeechBatchItemState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bytes: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub voice_cache_hit: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SpeechBatchState {
    pub batch_id: String,
    pub model: String,
    pub status: SpeechBatchStatus,
    pub total: usize,
    pub completed: usize,
    pub failed: usize,
    pub created_at: String,
    pub updated_at: String,
    pub items: Vec<SpeechBatchItemStatus>,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub idle_remaining_sec: Option<u64>,
    #[serde(default)]
    pub available_quants: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_path: Option<String>,
    pub memory: ResourceVector,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ModelDownloadStatus {
    Queued,
    Downloading,
    Verifying,
    Completed,
    Failed,
    Cancelled,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct StartDownloadRequest {
    #[serde(default)]
    pub quant: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelDownloadState {
    pub model_id: String,
    pub variant_id: String,
    pub status: ModelDownloadStatus,
    pub downloaded_bytes: u64,
    pub total_bytes: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_file: Option<String>,
    pub files_completed: usize,
    pub files_total: usize,
    pub sha256_verified: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    pub updated_at: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelConfigOverrideSummary {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub quant: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub idle_timeout_sec: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pin_policy: Option<PinPolicy>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SystemConfigResponse {
    pub budget_tier: BudgetTier,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub budget_override_mb: Option<u64>,
    pub effective_budget: ResourceVector,
    pub data_dir: String,
    pub models_dir: String,
    pub voices_dir: String,
    pub config_path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mdns_hostname: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mdns_base_url: Option<String>,
    pub http_base_url: String,
    #[serde(default)]
    pub model_overrides: BTreeMap<String, ModelConfigOverrideSummary>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct UpdateSystemConfigRequest {
    #[serde(default)]
    pub budget_tier: Option<BudgetTier>,
    #[serde(default)]
    pub budget_override_mb: Option<u64>,
    #[serde(default)]
    pub clear_budget_override: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct UpdateModelConfigRequest {
    #[serde(default)]
    pub pin_policy: Option<PinPolicy>,
    #[serde(default)]
    pub idle_timeout_sec: Option<u64>,
    #[serde(default)]
    pub quant: Option<String>,
    #[serde(default)]
    pub path: Option<String>,
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deserializes_partial_worker_timing_metrics() {
        let parsed: TimingMetrics =
            serde_json::from_str(r#"{"decode_ms":123.4}"#).expect("partial timing JSON");
        assert_eq!(parsed.queue_ms, 0.0);
        assert_eq!(parsed.decode_ms, 123.4);
        assert_eq!(parsed.model_load_ms, None);
    }
}
