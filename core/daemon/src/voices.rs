use acpm_protocol::{ApiError, ErrorCode, FailureStage, VoiceProfile};
use chrono::Utc;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, RwLock};
use tracing::warn;
use uuid::Uuid;

const MIN_VOICE_DURATION_MS: i64 = 100;
const MAX_VOICE_DURATION_MS: i64 = 600_000;

#[derive(Debug, Clone)]
pub struct ResolvedSpeechVoice {
    pub voice: Option<String>,
    pub reference_audio: Option<String>,
    pub reference_text: Option<String>,
}

#[derive(Debug, Clone)]
pub enum VoiceStoreError {
    InvalidInput { code: &'static str, message: String },
    InvalidAudio { code: &'static str, message: String },
    Internal { message: String },
}

impl VoiceStoreError {
    pub fn into_api_error(self, request_id: &str) -> ApiError {
        match self {
            Self::InvalidInput { code, message } => ApiError::new(
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
            Self::Internal { message } => ApiError::new(
                ErrorCode::InferenceFailed,
                FailureStage::HttpAdmission,
                "VOICE_STORE_ERROR",
                message,
                request_id,
            ),
        }
    }
}

#[derive(Clone)]
pub struct VoiceStore {
    voices_dir: PathBuf,
    entries: Arc<RwLock<BTreeMap<String, VoiceProfile>>>,
    write_lock: Arc<std::sync::Mutex<()>>,
}

impl VoiceStore {
    pub fn open(voices_dir: impl Into<PathBuf>) -> Result<Self, String> {
        let voices_dir = voices_dir.into();
        std::fs::create_dir_all(&voices_dir)
            .map_err(|e| format!("failed creating voices_dir {}: {e}", voices_dir.display()))?;

        let mut entries = BTreeMap::new();
        let read_dir = std::fs::read_dir(&voices_dir)
            .map_err(|e| format!("failed scanning voices_dir {}: {e}", voices_dir.display()))?;

        for dir_entry in read_dir.flatten() {
            let path = dir_entry.path();
            if !path.is_dir() {
                continue;
            }
            let Some(dir_name) = path.file_name().and_then(|s| s.to_str()) else {
                continue;
            };
            if dir_name.starts_with('.') || !is_valid_voice_id(dir_name) {
                continue;
            }
            let meta_path = path.join("meta.json");
            let wav_path = path.join("ref.wav");
            if !meta_path.is_file() || !wav_path.is_file() {
                continue;
            }
            match std::fs::read_to_string(&meta_path)
                .ok()
                .and_then(|raw| serde_json::from_str::<VoiceProfile>(&raw).ok())
            {
                Some(mut profile) => {
                    if profile.voice_id != dir_name {
                        profile.voice_id = dir_name.to_string();
                    }
                    entries.insert(profile.voice_id.clone(), profile);
                }
                None => {
                    warn!(dir = %path.display(), "ignoring unreadable voice metadata directory");
                }
            }
        }

        Ok(Self {
            voices_dir,
            entries: Arc::new(RwLock::new(entries)),
            write_lock: Arc::new(std::sync::Mutex::new(())),
        })
    }

    pub async fn register_from_file(
        &self,
        name: String,
        src_path: &Path,
        reference_text: Option<String>,
        language: Option<String>,
        notes: Option<String>,
    ) -> Result<VoiceProfile, VoiceStoreError> {
        let name = clean_required_name(&name)?;
        if !src_path.is_file() {
            return Err(VoiceStoreError::InvalidAudio {
                code: "REFERENCE_AUDIO_NOT_FOUND",
                message: format!("Reference audio '{}' does not exist.", src_path.display()),
            });
        }
        let src_bytes = std::fs::read(src_path).map_err(|e| VoiceStoreError::InvalidAudio {
            code: "REFERENCE_AUDIO_UNREADABLE",
            message: format!("Failed reading '{}': {e}", src_path.display()),
        })?;
        let filename_hint = src_path
            .file_name()
            .and_then(|s| s.to_str())
            .map(ToOwned::to_owned);
        self.register_from_bytes(
            name,
            filename_hint.as_deref(),
            src_bytes,
            reference_text,
            language,
            notes,
        )
        .await
    }

    pub async fn register_from_bytes(
        &self,
        name: String,
        filename_hint: Option<&str>,
        audio_bytes: Vec<u8>,
        reference_text: Option<String>,
        language: Option<String>,
        notes: Option<String>,
    ) -> Result<VoiceProfile, VoiceStoreError> {
        let name = clean_required_name(&name)?;
        if audio_bytes.is_empty() {
            return Err(VoiceStoreError::InvalidAudio {
                code: "EMPTY_REFERENCE_AUDIO",
                message: "Uploaded reference audio is empty.".to_string(),
            });
        }

        let reference_text = normalize_opt_string(reference_text);
        let language = normalize_opt_string(language);
        let notes = normalize_opt_string(notes);
        let ext = filename_hint
            .and_then(|f| Path::new(f).extension().and_then(|e| e.to_str()))
            .filter(|e| e.chars().all(|c| c.is_ascii_alphanumeric()) && e.len() <= 10)
            .unwrap_or("bin")
            .to_string();

        let store = self.clone();
        tokio::task::spawn_blocking(move || {
            let (wav_bytes, duration_ms) = normalize_to_wav_and_duration(&audio_bytes, &ext)?;
            if duration_ms < MIN_VOICE_DURATION_MS || duration_ms > MAX_VOICE_DURATION_MS {
                return Err(VoiceStoreError::InvalidAudio {
                    code: "INVALID_REFERENCE_AUDIO_DURATION",
                    message: format!(
                        "Reference audio duration ({duration_ms} ms) must be between {MIN_VOICE_DURATION_MS} ms and {MAX_VOICE_DURATION_MS} ms."
                    ),
                });
            }

            let sha256 = compute_sha256_hex(&wav_bytes);
            let short = Uuid::new_v4().simple().to_string();
            let voice_id = format!("v_{}", &short[..12]);

            let profile = VoiceProfile {
                voice_id: voice_id.clone(),
                name,
                reference_text,
                language,
                notes,
                duration_ms,
                sha256,
                created_at: Utc::now().to_rfc3339(),
            };

            let _guard = store.write_lock.lock().unwrap();
            let stage_dir = store.voices_dir.join(format!(".tmp-{voice_id}"));
            let final_dir = store.voices_dir.join(&voice_id);
            if stage_dir.exists() {
                let _ = std::fs::remove_dir_all(&stage_dir);
            }
            std::fs::create_dir_all(&stage_dir).map_err(|e| VoiceStoreError::Internal {
                message: format!("Failed creating staging dir {}: {e}", stage_dir.display()),
            })?;

            let write_res = (|| -> Result<(), VoiceStoreError> {
                std::fs::write(stage_dir.join("ref.wav"), &wav_bytes).map_err(|e| {
                    VoiceStoreError::Internal {
                        message: format!("Failed writing ref.wav: {e}"),
                    }
                })?;
                let meta_json =
                    serde_json::to_vec_pretty(&profile).map_err(|e| VoiceStoreError::Internal {
                        message: format!("Failed serializing voice metadata: {e}"),
                    })?;
                std::fs::write(stage_dir.join("meta.json"), meta_json).map_err(|e| {
                    VoiceStoreError::Internal {
                        message: format!("Failed writing meta.json: {e}"),
                    }
                })?;
                if final_dir.exists() {
                    let _ = std::fs::remove_dir_all(&final_dir);
                }
                std::fs::rename(&stage_dir, &final_dir).map_err(|e| VoiceStoreError::Internal {
                    message: format!("Failed committing voice dir: {e}"),
                })?;
                Ok(())
            })();

            if let Err(err) = write_res {
                let _ = std::fs::remove_dir_all(&stage_dir);
                return Err(err);
            }

            store
                .entries
                .write()
                .unwrap()
                .insert(voice_id, profile.clone());
            Ok(profile)
        })
        .await
        .map_err(|e| VoiceStoreError::Internal {
            message: format!("Voice registration worker panicked: {e}"),
        })?
    }

    pub fn list(&self) -> Vec<VoiceProfile> {
        let mut items: Vec<VoiceProfile> = self
            .entries
            .read()
            .unwrap()
            .values()
            .cloned()
            .collect();
        items.sort_by(|a, b| {
            b.created_at
                .cmp(&a.created_at)
                .then_with(|| a.voice_id.cmp(&b.voice_id))
        });
        items
    }

    pub fn get(&self, voice_id: &str) -> Option<(VoiceProfile, PathBuf)> {
        if !is_valid_voice_id(voice_id) {
            return None;
        }
        let guard = self.entries.read().unwrap();
        let profile = guard.get(voice_id)?.clone();
        let wav_path = self.voices_dir.join(voice_id).join("ref.wav");
        if wav_path.is_file() {
            Some((profile, wav_path))
        } else {
            None
        }
    }

    pub fn sample_path(&self, voice_id: &str) -> Option<PathBuf> {
        self.get(voice_id).map(|(_, path)| path)
    }

    pub fn delete(&self, voice_id: &str) -> Result<bool, VoiceStoreError> {
        if !is_valid_voice_id(voice_id) {
            return Err(VoiceStoreError::InvalidInput {
                code: "INVALID_VOICE_ID",
                message: format!("Invalid voice_id '{voice_id}'."),
            });
        }
        let _guard = self.write_lock.lock().unwrap();
        let existed_in_map = self.entries.write().unwrap().remove(voice_id).is_some();
        let dir = self.voices_dir.join(voice_id);
        let existed_on_disk = dir.exists();
        if existed_on_disk {
            std::fs::remove_dir_all(&dir).map_err(|e| VoiceStoreError::Internal {
                message: format!("Failed deleting voice '{}': {e}", dir.display()),
            })?;
        }
        Ok(existed_in_map || existed_on_disk)
    }

    pub fn resolve_for_speech(
        &self,
        voice: Option<String>,
        reference_audio: Option<String>,
        reference_text: Option<String>,
    ) -> Result<ResolvedSpeechVoice, VoiceStoreError> {
        let explicit_ref = normalize_opt_string(reference_audio);
        let explicit_text = normalize_opt_string(reference_text);
        let clean_voice = normalize_opt_string(voice);

        if let Some(ref_audio) = explicit_ref {
            let p = Path::new(&ref_audio);
            if !p.is_file() {
                return Err(VoiceStoreError::InvalidAudio {
                    code: "REFERENCE_AUDIO_NOT_FOUND",
                    message: format!("reference_audio '{ref_audio}' does not exist."),
                });
            }
            return Ok(ResolvedSpeechVoice {
                voice: clean_voice,
                reference_audio: Some(ref_audio),
                reference_text: explicit_text,
            });
        }

        if let Some(ref voice_id) = clean_voice {
            if let Some((profile, ref_wav_path)) = self.get(voice_id) {
                return Ok(ResolvedSpeechVoice {
                    voice: None,
                    reference_audio: Some(ref_wav_path.to_string_lossy().into_owned()),
                    reference_text: explicit_text.or(profile.reference_text),
                });
            }
        }

        Ok(ResolvedSpeechVoice {
            voice: clean_voice,
            reference_audio: None,
            reference_text: explicit_text,
        })
    }
}

fn clean_required_name(raw: &str) -> Result<String, VoiceStoreError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(VoiceStoreError::InvalidInput {
            code: "MISSING_VOICE_NAME",
            message: "Voice 'name' must not be empty.".to_string(),
        });
    }
    if trimmed.len() > 120 {
        return Err(VoiceStoreError::InvalidInput {
            code: "VOICE_NAME_TOO_LONG",
            message: "Voice 'name' must be at most 120 characters.".to_string(),
        });
    }
    Ok(trimmed.to_string())
}

fn normalize_opt_string(v: Option<String>) -> Option<String> {
    v.map(|s| s.trim().to_string()).filter(|s| !s.is_empty())
}

fn is_valid_voice_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

fn compute_sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut hex = String::with_capacity(digest.len() * 2);
    for b in digest {
        hex.push_str(&format!("{b:02x}"));
    }
    hex
}

fn wav_duration_ms(bytes: &[u8]) -> Result<i64, String> {
    if bytes.len() < 12 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return Err("Not a RIFF/WAVE header".to_string());
    }

    let mut pos = 12usize;
    let mut sample_rate = 0u32;
    let mut channels = 0u16;
    let mut bits_per_sample = 0u16;
    let mut audio_format = 0u16;
    let mut data_len = 0u64;
    let mut found_fmt = false;
    let mut found_data = false;

    while pos + 8 <= bytes.len() {
        let chunk_id = &bytes[pos..pos + 4];
        let chunk_size = u32::from_le_bytes(bytes[pos + 4..pos + 8].try_into().unwrap()) as usize;
        pos += 8;
        if pos + chunk_size > bytes.len() {
            return Err("Truncated WAV chunk".to_string());
        }
        let chunk = &bytes[pos..pos + chunk_size];
        if chunk_id == b"fmt " {
            if chunk.len() < 16 {
                return Err("WAV fmt chunk too short".to_string());
            }
            audio_format = u16::from_le_bytes(chunk[0..2].try_into().unwrap());
            channels = u16::from_le_bytes(chunk[2..4].try_into().unwrap());
            sample_rate = u32::from_le_bytes(chunk[4..8].try_into().unwrap());
            bits_per_sample = u16::from_le_bytes(chunk[14..16].try_into().unwrap());
            found_fmt = true;
        } else if chunk_id == b"data" {
            data_len = chunk.len() as u64;
            found_data = true;
        }
        pos += chunk_size + (chunk_size % 2);
    }

    if !found_fmt || !found_data || sample_rate == 0 || channels == 0 || bits_per_sample == 0 {
        return Err("Missing WAV fmt or data chunk".to_string());
    }
    if !(audio_format == 1 || audio_format == 3) {
        return Err(format!("Unsupported WAV format tag {audio_format}"));
    }
    let bytes_per_sec =
        sample_rate as u64 * channels as u64 * (bits_per_sample as u64 / 8).max(1);
    if bytes_per_sec == 0 {
        return Err("Invalid WAV byte rate".to_string());
    }
    let duration_ms = ((data_len.saturating_mul(1000)) / bytes_per_sec) as i64;
    Ok(duration_ms)
}

fn normalize_to_wav_and_duration(
    raw: &[u8],
    ext_hint: &str,
) -> Result<(Vec<u8>, i64), VoiceStoreError> {
    if let Ok(dur_ms) = wav_duration_ms(raw) {
        return Ok((raw.to_vec(), dur_ms));
    }

    let tmp_dir = std::env::temp_dir().join(format!("acpm-voice-norm-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&tmp_dir).map_err(|e| VoiceStoreError::Internal {
        message: format!("Failed creating temp normalization dir: {e}"),
    })?;
    let src_file = tmp_dir.join(format!("input.{ext_hint}"));
    let dst_file = tmp_dir.join("normalized.wav");

    let res = (|| -> Result<(Vec<u8>, i64), VoiceStoreError> {
        std::fs::write(&src_file, raw).map_err(|e| VoiceStoreError::Internal {
            message: format!("Failed writing temp audio file: {e}"),
        })?;
        let output = Command::new("ffmpeg")
            .arg("-y")
            .arg("-v")
            .arg("error")
            .arg("-i")
            .arg(&src_file)
            .arg("-ac")
            .arg("1")
            .arg("-ar")
            .arg("24000")
            .arg("-c:a")
            .arg("pcm_s16le")
            .arg(&dst_file)
            .output()
            .map_err(|e| VoiceStoreError::InvalidAudio {
                code: "AUDIO_DECODE_FAILED",
                message: format!(
                    "Input is not a valid PCM/float WAV and ffmpeg could not run to decode it: {e}"
                ),
            })?;

        if !output.status.success() || !dst_file.is_file() {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            return Err(VoiceStoreError::InvalidAudio {
                code: "AUDIO_DECODE_FAILED",
                message: if stderr.is_empty() {
                    "Unsupported or corrupt reference audio file.".to_string()
                } else {
                    format!("Failed decoding reference audio: {stderr}")
                },
            });
        }

        let wav_bytes = std::fs::read(&dst_file).map_err(|e| VoiceStoreError::Internal {
            message: format!("Failed reading normalized WAV: {e}"),
        })?;
        let dur_ms = wav_duration_ms(&wav_bytes).map_err(|e| VoiceStoreError::InvalidAudio {
            code: "INVALID_WAV_OUTPUT",
            message: e,
        })?;
        Ok((wav_bytes, dur_ms))
    })();

    let _ = std::fs::remove_dir_all(&tmp_dir);
    res
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_pcm16_wav(sample_rate: u32, num_samples: usize) -> Vec<u8> {
        let data_bytes = (num_samples * 2) as u32;
        let riff_size = 36 + data_bytes;
        let mut out = Vec::with_capacity(44 + num_samples * 2);
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
        for i in 0..num_samples {
            let s = if (i / 100) % 2 == 0 { 1200i16 } else { -1200i16 };
            out.extend_from_slice(&s.to_le_bytes());
        }
        out
    }

    #[tokio::test]
    async fn register_list_resolve_persist_and_delete() {
        let dir = std::env::temp_dir().join(format!("acpm-voices-test-{}", Uuid::new_v4()));
        let store = VoiceStore::open(&dir).unwrap();
        let wav = make_pcm16_wav(24_000, 24_000); // 1000 ms

        let created = store
            .register_from_bytes(
                "Narrator".to_string(),
                Some("sample.wav"),
                wav,
                Some("你好，世界".to_string()),
                Some("zh".to_string()),
                Some("warm studio".to_string()),
            )
            .await
            .unwrap();

        assert!(created.voice_id.starts_with("v_"));
        assert_eq!(created.duration_ms, 1000);
        assert_eq!(created.notes.as_deref(), Some("warm studio"));
        assert_eq!(created.sha256.len(), 64);

        // Re-open fresh store from disk to verify persistence across restarts.
        let reopened = VoiceStore::open(&dir).unwrap();
        let listed = reopened.list();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].voice_id, created.voice_id);

        // Registered voice_id resolves to stored ref.wav + reference_text and clears preset voice.
        let resolved = reopened
            .resolve_for_speech(Some(created.voice_id.clone()), None, None)
            .unwrap();
        assert!(resolved.voice.is_none());
        assert!(resolved
            .reference_audio
            .as_deref()
            .unwrap()
            .ends_with("ref.wav"));
        assert_eq!(resolved.reference_text.as_deref(), Some("你好，世界"));

        // Unknown voice string (e.g. built-in speaker preset) passes through untouched.
        let preset = reopened
            .resolve_for_speech(Some("Vivian".to_string()), None, None)
            .unwrap();
        assert_eq!(preset.voice.as_deref(), Some("Vivian"));
        assert!(preset.reference_audio.is_none());

        assert!(reopened.delete(&created.voice_id).unwrap());
        assert!(!reopened.delete(&created.voice_id).unwrap());
        assert!(reopened.list().is_empty());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn rejects_empty_or_corrupt_audio_and_path_traversal() {
        let dir = std::env::temp_dir().join(format!("acpm-voices-err-{}", Uuid::new_v4()));
        let store = VoiceStore::open(&dir).unwrap();

        let empty_err = store
            .register_from_bytes("Bad".to_string(), None, vec![], None, None, None)
            .await;
        assert!(empty_err.is_err());

        let tiny_wav = make_pcm16_wav(16_000, 160); // 10 ms < MIN_VOICE_DURATION_MS
        let short_err = store
            .register_from_bytes("Short".to_string(), Some("a.wav"), tiny_wav, None, None, None)
            .await;
        assert!(short_err.is_err());

        let traversal = store.delete("../escape");
        assert!(traversal.is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }
}
