use acpm_protocol::{BudgetTier, Capability, ModelEntry, ModelVariant, PinPolicy};
use acpm_registry::{ModelRegistry, RegistryError};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ModelOverrideConfig {
    #[serde(default)]
    pub path: PathBuf,
    #[serde(default)]
    pub quant: Option<String>,
    #[serde(default)]
    pub idle_timeout_sec: Option<u64>,
    #[serde(default)]
    pub pin_policy: Option<PinPolicy>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct DaemonFileConfig {
    #[serde(default)]
    pub budget_tier: Option<BudgetTier>,
    #[serde(default)]
    pub budget_override_mb: Option<u64>,
    #[serde(default)]
    pub worker_mlx_bin: Option<PathBuf>,
    #[serde(default)]
    pub worker_speech_bin: Option<PathBuf>,
    #[serde(default)]
    pub model_overrides: BTreeMap<String, ModelOverrideConfig>,
}

impl DaemonFileConfig {
    pub fn load_if_exists(path: &Path) -> Result<Self, String> {
        if !path.exists() {
            return Ok(Self::default());
        }
        let raw = std::fs::read_to_string(path)
            .map_err(|e| format!("failed to read config {}: {e}", path.display()))?;
        serde_json::from_str(&raw)
            .map_err(|e| format!("failed to parse config {}: {e}", path.display()))
    }

    pub fn save_atomic(&self, path: &Path) -> Result<(), String> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("failed creating config dir {}: {e}", parent.display()))?;
        }
        let tmp = path.with_extension(format!("json.tmp.{}", std::process::id()));
        let payload = serde_json::to_vec_pretty(self)
            .map_err(|e| format!("failed serializing config: {e}"))?;
        std::fs::write(&tmp, payload)
            .map_err(|e| format!("failed writing temp config {}: {e}", tmp.display()))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
        }
        std::fs::rename(&tmp, path)
            .map_err(|e| format!("failed replacing config {}: {e}", path.display()))?;
        Ok(())
    }
}

#[derive(Debug, Clone)]
pub struct ResolvedModel {
    pub entry: ModelEntry,
    pub variant: ModelVariant,
    pub model_dir: PathBuf,
    pub idle_timeout_sec: u64,
    pub pin_policy: PinPolicy,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResolveModelError {
    NotFound(String),
    UnsupportedPlatform { model_id: String, platform: String },
    NotInstalled { model_id: String, variant_id: String, expected_path: PathBuf },
}

/// Parses `--model-path` arguments formatted as `<model_id>=<dir>` or `<model_id>:<quant>=<dir>`.
pub fn parse_model_path_arg(raw: &str) -> Result<(String, Option<String>, PathBuf), String> {
    let (lhs, rhs) = raw
        .split_once('=')
        .ok_or_else(|| format!("expected '<model_id>[:<quant>]=<path>', got '{raw}'"))?;
    let path_str = rhs.trim();
    if path_str.is_empty() {
        return Err(format!("empty model path in '{raw}'"));
    }
    let lhs_trimmed = lhs.trim();
    let (model_id, quant) = match lhs_trimmed.split_once(':') {
        Some((id, q)) => {
            let id = id.trim();
            let q = q.trim();
            if id.is_empty() || q.is_empty() {
                return Err(format!("invalid model selector '{lhs_trimmed}' in '{raw}'"));
            }
            (id.to_string(), Some(q.to_string()))
        }
        None => {
            if lhs_trimmed.is_empty() {
                return Err(format!("empty model_id in '{raw}'"));
            }
            (lhs_trimmed.to_string(), None)
        }
    };
    Ok((model_id, quant, PathBuf::from(path_str)))
}

/// Infers quantization label (`4bit`, `8bit`, `bf16`) from a local MLX model directory.
pub fn detect_quant_from_dir(dir: &Path) -> Option<String> {
    let cfg_path = dir.join("config.json");
    if let Ok(raw) = std::fs::read_to_string(&cfg_path) {
        if let Ok(val) = serde_json::from_str::<serde_json::Value>(&raw) {
            let bits = val
                .get("quantization")
                .and_then(|q| q.get("bits"))
                .and_then(|b| b.as_u64())
                .or_else(|| {
                    val.get("quantization_config")
                        .and_then(|q| q.get("bits"))
                        .and_then(|b| b.as_u64())
                });
            if let Some(b) = bits {
                return Some(format!("{b}bit"));
            }
            let dtype = val
                .get("torch_dtype")
                .or_else(|| val.get("dtype"))
                .and_then(|d| d.as_str())
                .unwrap_or("")
                .to_ascii_lowercase();
            if dtype.contains("bfloat16") || dtype.contains("bf16") {
                return Some("bf16".to_string());
            }
        }
    }

    let name_lower = dir
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    if name_lower.contains("bf16") {
        Some("bf16".to_string())
    } else if name_lower.contains("8bit") || name_lower.contains("mlx8") {
        Some("8bit".to_string())
    } else if name_lower.contains("4bit") || name_lower.contains("mlx4") {
        Some("4bit".to_string())
    } else {
        None
    }
}

pub fn is_local_model_dir_ready(dir: &Path) -> bool {
    if !dir.is_dir() || !dir.join("config.json").is_file() {
        return false;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return false;
    };
    entries.flatten().any(|entry| {
        let p = entry.path();
        p.extension()
            .and_then(|ext| ext.to_str())
            .map(|ext| ext.eq_ignore_ascii_case("safetensors"))
            .unwrap_or(false)
    })
}

pub fn is_local_model_dir_ready_for(capability: Capability, dir: &Path) -> bool {
    match capability {
        Capability::Vad => {
            dir.is_dir()
                && (dir.join("segmentation.onnx").is_file() || dir.join("model.onnx").is_file())
        }
        Capability::Diarization => false,
        Capability::Llm | Capability::Asr | Capability::Tts => is_local_model_dir_ready(dir),
    }
}

fn find_worker_binary(
    cli_override: Option<PathBuf>,
    file_override: Option<PathBuf>,
    env_var: &str,
    exe_sibling_name: &str,
    rel_candidates: &[&str],
) -> Option<PathBuf> {
    if let Some(path) = cli_override.filter(|p| p.is_file()) {
        return Some(path);
    }
    if let Ok(env_path) = std::env::var(env_var) {
        let p = PathBuf::from(env_path);
        if p.is_file() {
            return Some(p);
        }
    }
    if let Some(path) = file_override.filter(|p| p.is_file()) {
        return Some(path);
    }

    let mut search_roots = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        if let Some(exe_dir) = exe.parent() {
            let sibling = exe_dir.join(exe_sibling_name);
            if sibling.is_file() {
                return Some(sibling);
            }
            for ancestor in exe_dir.ancestors().take(6) {
                search_roots.push(ancestor.to_path_buf());
            }
        }
    }
    if let Ok(cwd) = std::env::current_dir() {
        for ancestor in cwd.ancestors().take(4) {
            search_roots.push(ancestor.to_path_buf());
        }
    }

    for root in search_roots {
        for rel in rel_candidates {
            let candidate = root.join(rel);
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }

    None
}

pub fn resolve_worker_mlx_bin(
    cli_override: Option<PathBuf>,
    file_override: Option<PathBuf>,
) -> Option<PathBuf> {
    find_worker_binary(
        cli_override,
        file_override,
        "ACPM_WORKER_MLX_BIN",
        "acpm-worker-mlx",
        &[
            "workers/macos-mlx/.build/release/acpm-worker-mlx",
            "workers/macos-mlx/.build/arm64-apple-macosx/release/acpm-worker-mlx",
            "workers/macos-mlx/.build/debug/acpm-worker-mlx",
            "workers/macos-mlx/.build/arm64-apple-macosx/debug/acpm-worker-mlx",
        ],
    )
}

pub fn resolve_worker_speech_bin(
    cli_override: Option<PathBuf>,
    file_override: Option<PathBuf>,
) -> Option<PathBuf> {
    find_worker_binary(
        cli_override,
        file_override,
        "ACPM_WORKER_SPEECH_BIN",
        "acpm-worker-speech",
        &[
            "core/target/release/acpm-worker-speech",
            "core/target/debug/acpm-worker-speech",
            "target/release/acpm-worker-speech",
            "target/debug/acpm-worker-speech",
        ],
    )
}

pub fn resolve_sherpa_lib_dir() -> Option<PathBuf> {
    if let Ok(raw) = std::env::var("ACPM_SHERPA_LIB_DIR") {
        let p = PathBuf::from(raw);
        if p.is_dir() {
            return Some(p);
        }
    }

    let mut search_roots = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        if let Some(exe_dir) = exe.parent() {
            let bundled = exe_dir.join("../Frameworks");
            if bundled.join("libonnxruntime.dylib").is_file()
                || bundled.join("libonnxruntime.so").is_file()
            {
                return Some(bundled);
            }
        }
        for ancestor in exe.ancestors().take(6) {
            search_roots.push(ancestor.to_path_buf());
        }
    }
    if let Ok(cwd) = std::env::current_dir() {
        for ancestor in cwd.ancestors().take(4) {
            search_roots.push(ancestor.to_path_buf());
        }
    }

    for root in search_roots {
        let cand = root.join(".cache/sherpa-onnx/v2.0.3/lib");
        if cand.join("libonnxruntime.dylib").is_file() || cand.join("libonnxruntime.so").is_file() {
            return Some(cand);
        }
    }
    None
}

pub fn find_bundled_model_dir_relative_to(exe_path: &Path, model_id: &str) -> Option<PathBuf> {
    let dir = exe_path
        .parent()?
        .parent()?
        .join("Resources")
        .join("models")
        .join(model_id);
    if dir.is_dir() {
        Some(dir)
    } else {
        None
    }
}

pub fn find_bundled_model_dir(model_id: &str) -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    find_bundled_model_dir_relative_to(&exe, model_id)
}

pub fn extract_hf_repo_id(url: &str) -> Option<String> {
    let trimmed = url.trim();
    let rest = trimmed
        .strip_prefix("https://huggingface.co/")
        .or_else(|| trimmed.strip_prefix("http://huggingface.co/"))
        .or_else(|| trimmed.strip_prefix("https://hf-mirror.com/"))?;
    let mut parts = rest.split('/').filter(|p| !p.is_empty());
    let org = parts.next()?;
    let repo = parts.next()?;
    let action = parts.next()?;
    if action != "resolve" && action != "blob" && action != "tree" {
        return None;
    }
    Some(format!("{org}/{repo}"))
}

pub fn default_hf_hub_dir() -> Option<PathBuf> {
    if let Ok(raw) = std::env::var("HF_HUB_CACHE") {
        let p = PathBuf::from(raw);
        if p.is_dir() {
            return Some(p);
        }
    }
    if let Ok(raw) = std::env::var("HF_HOME") {
        let p = PathBuf::from(raw).join("hub");
        if p.is_dir() {
            return Some(p);
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        let p = PathBuf::from(home).join(".cache/huggingface/hub");
        if p.is_dir() {
            return Some(p);
        }
    }
    None
}

pub fn find_hf_hub_snapshot(hf_hub_dir: &Path, repo_id: &str) -> Option<PathBuf> {
    let (org, repo) = repo_id.split_once('/')?;
    let repo_dir = hf_hub_dir.join(format!("models--{org}--{repo}"));
    if !repo_dir.is_dir() {
        return None;
    }
    let snapshots_dir = repo_dir.join("snapshots");
    if !snapshots_dir.is_dir() {
        return None;
    }

    let ref_main = repo_dir.join("refs").join("main");
    if let Ok(raw_rev) = std::fs::read_to_string(&ref_main) {
        let rev = raw_rev.trim();
        if !rev.is_empty() && !rev.contains('/') && !rev.contains('\\') {
            let candidate = snapshots_dir.join(rev);
            if candidate.is_dir() {
                return Some(candidate);
            }
        }
    }

    let mut snaps: Vec<(std::time::SystemTime, PathBuf)> = std::fs::read_dir(&snapshots_dir)
        .ok()?
        .flatten()
        .filter_map(|entry| {
            let p = entry.path();
            if !p.is_dir() {
                return None;
            }
            let modified = entry
                .metadata()
                .and_then(|m| m.modified())
                .unwrap_or(std::time::SystemTime::UNIX_EPOCH);
            Some((modified, p))
        })
        .collect();
    snaps.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| b.1.cmp(&a.1)));
    snaps.into_iter().next().map(|(_, p)| p)
}

fn find_hf_hub_dir_for_variant(
    hf_hub_dir: &Path,
    capability: Capability,
    variant: &ModelVariant,
) -> Option<PathBuf> {
    for file in &variant.files {
        if let Some(repo_id) = extract_hf_repo_id(&file.url) {
            if let Some(snap) = find_hf_hub_snapshot(hf_hub_dir, &repo_id) {
                if is_local_model_dir_ready_for(capability, &snap) {
                    return Some(snap);
                }
            }
        }
    }
    None
}

fn check_variant_without_override(
    registry: &ModelRegistry,
    models_dir: &Path,
    hf_hub_dir: Option<&Path>,
    entry: &ModelEntry,
    variant: &ModelVariant,
) -> (PathBuf, bool) {
    let dir = ModelRegistry::variant_dir(models_dir, &entry.id, variant);
    let ready = match entry.capability {
        Capability::Diarization => false,
        Capability::Vad => is_local_model_dir_ready_for(Capability::Vad, &dir),
        Capability::Llm | Capability::Asr | Capability::Tts => {
            registry.is_variant_installed(models_dir, &entry.id, variant)
                || is_local_model_dir_ready_for(entry.capability, &dir)
        }
    };
    if ready {
        return (dir, true);
    }

    if entry.capability != Capability::Diarization {
        if let Some(bundled) = find_bundled_model_dir(&entry.id) {
            if is_local_model_dir_ready_for(entry.capability, &bundled) {
                return (bundled, true);
            }
        }
        if let Some(hf_dir) = hf_hub_dir {
            if let Some(hf_snap) = find_hf_hub_dir_for_variant(hf_dir, entry.capability, variant) {
                return (hf_snap, true);
            }
        }
    }

    (dir, false)
}

pub fn inspect_model_installation(
    registry: &ModelRegistry,
    platform: &str,
    models_dir: &Path,
    overrides: &BTreeMap<String, ModelOverrideConfig>,
    model_id: &str,
    requested_quant: Option<&str>,
    default_idle_override: Option<u64>,
) -> Result<(ResolvedModel, bool), ResolveModelError> {
    let default_hf = default_hf_hub_dir();
    inspect_model_installation_with_hf_hub(
        registry,
        platform,
        models_dir,
        overrides,
        model_id,
        requested_quant,
        default_idle_override,
        default_hf.as_deref(),
    )
}

#[allow(clippy::too_many_arguments)]
pub fn inspect_model_installation_with_hf_hub(
    registry: &ModelRegistry,
    platform: &str,
    models_dir: &Path,
    overrides: &BTreeMap<String, ModelOverrideConfig>,
    model_id: &str,
    requested_quant: Option<&str>,
    default_idle_override: Option<u64>,
    hf_hub_dir: Option<&Path>,
) -> Result<(ResolvedModel, bool), ResolveModelError> {
    let override_cfg = overrides.get(model_id);
    let effective_quant_owned: Option<String> = requested_quant
        .map(ToString::to_string)
        .or_else(|| override_cfg.and_then(|c| c.quant.clone()))
        .or_else(|| {
            override_cfg
                .filter(|c| !c.path.as_os_str().is_empty())
                .and_then(|c| detect_quant_from_dir(&c.path))
        });

    let (entry, initial_variant) = match registry.resolve_variant(
        model_id,
        platform,
        effective_quant_owned.as_deref(),
    ) {
        Ok(pair) => pair,
        Err(RegistryError::ModelNotFound(id)) => return Err(ResolveModelError::NotFound(id)),
        Err(RegistryError::UnsupportedPlatform { model_id, platform }) => {
            return Err(ResolveModelError::UnsupportedPlatform { model_id, platform });
        }
        Err(_) => return Err(ResolveModelError::NotFound(model_id.to_string())),
    };

    let mut chosen_variant = initial_variant;
    let (model_dir, installed) =
        if let Some(ov) = override_cfg.filter(|c| !c.path.as_os_str().is_empty()) {
            let ready = is_local_model_dir_ready_for(entry.capability, &ov.path);
            (ov.path.clone(), ready)
        } else {
            let (primary_dir, primary_ready) =
                check_variant_without_override(registry, models_dir, hf_hub_dir, entry, chosen_variant);
            if !primary_ready
                && effective_quant_owned.is_none()
                && entry.capability != Capability::Diarization
            {
                let mut fallback_hit: Option<(&ModelVariant, PathBuf)> = None;
                for alt in entry.variants.iter().filter(|v| {
                    (v.platform == platform || v.platform == "any")
                        && v.variant_id != chosen_variant.variant_id
                }) {
                    let (alt_dir, alt_ready) =
                        check_variant_without_override(registry, models_dir, hf_hub_dir, entry, alt);
                    if alt_ready {
                        fallback_hit = Some((alt, alt_dir));
                        break;
                    }
                }
                if let Some((alt_variant, alt_dir)) = fallback_hit {
                    chosen_variant = alt_variant;
                    (alt_dir, true)
                } else {
                    (primary_dir, false)
                }
            } else {
                (primary_dir, primary_ready)
            }
        };

    let idle_timeout_sec = override_cfg
        .and_then(|ov| ov.idle_timeout_sec)
        .or(default_idle_override)
        .unwrap_or(entry.lifecycle.idle_timeout_sec);
    let pin_policy = override_cfg
        .and_then(|ov| ov.pin_policy)
        .unwrap_or(entry.lifecycle.pin_policy);

    Ok((
        ResolvedModel {
            entry: entry.clone(),
            variant: chosen_variant.clone(),
            model_dir,
            idle_timeout_sec,
            pin_policy,
        },
        installed,
    ))
}

pub fn resolve_installed_model(
    registry: &ModelRegistry,
    platform: &str,
    models_dir: &Path,
    overrides: &BTreeMap<String, ModelOverrideConfig>,
    model_id: &str,
    requested_quant: Option<&str>,
    default_idle_override: Option<u64>,
) -> Result<ResolvedModel, ResolveModelError> {
    let (resolved, installed) = inspect_model_installation(
        registry,
        platform,
        models_dir,
        overrides,
        model_id,
        requested_quant,
        default_idle_override,
    )?;
    if !installed {
        return Err(ResolveModelError::NotInstalled {
            model_id: resolved.entry.id,
            variant_id: resolved.variant.variant_id,
            expected_path: resolved.model_dir,
        });
    }
    Ok(resolved)
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    #[test]
    fn parses_model_path_arguments_with_optional_quant() {
        let (id, q, p) = parse_model_path_arg("yanmo-correct-4b-cot=/tmp/llm").unwrap();
        assert_eq!(id, "yanmo-correct-4b-cot");
        assert_eq!(q, None);
        assert_eq!(p, PathBuf::from("/tmp/llm"));

        let (id2, q2, p2) = parse_model_path_arg("qwen3-tts-1.7b:bf16=/tmp/tts").unwrap();
        assert_eq!(id2, "qwen3-tts-1.7b");
        assert_eq!(q2.as_deref(), Some("bf16"));
        assert_eq!(p2, PathBuf::from("/tmp/tts"));

        assert!(parse_model_path_arg("broken").is_err());
        assert!(parse_model_path_arg("model:=").is_err());
    }

    #[test]
    fn detects_quant_and_readiness_from_local_directory() {
        let dir = std::env::temp_dir().join(format!("acpmd-cfg-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("config.json"),
            r#"{"model_type":"qwen3_5","quantization":{"bits":8,"group_size":64}}"#,
        )
        .unwrap();
        assert_eq!(detect_quant_from_dir(&dir).as_deref(), Some("8bit"));
        assert!(!is_local_model_dir_ready(&dir));

        std::fs::write(dir.join("model.safetensors"), b"stub").unwrap();
        assert!(is_local_model_dir_ready(&dir));

        let bf16_dir = dir.join("bf16-test");
        std::fs::create_dir_all(&bf16_dir).unwrap();
        std::fs::write(bf16_dir.join("config.json"), r#"{"torch_dtype":"bfloat16"}"#).unwrap();
        assert_eq!(detect_quant_from_dir(&bf16_dir).as_deref(), Some("bf16"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn finds_bundled_vad_model_relative_to_app_helper_exe() {
        let root = std::env::temp_dir().join(format!("acpm-bundle-vad-test-{}", Uuid::new_v4()));
        let helpers_exe = root.join("AcpmRuntime.app/Contents/Helpers/acpmd");
        let vad_dir = root.join("AcpmRuntime.app/Contents/Resources/models/speech-vad-pyannote");
        std::fs::create_dir_all(helpers_exe.parent().unwrap()).unwrap();
        std::fs::create_dir_all(&vad_dir).unwrap();
        std::fs::write(&helpers_exe, b"exe").unwrap();
        std::fs::write(vad_dir.join("segmentation.onnx"), b"onnx").unwrap();

        let found = find_bundled_model_dir_relative_to(&helpers_exe, "speech-vad-pyannote")
            .expect("bundled VAD directory should be found");
        assert_eq!(found, vad_dir);
        assert!(is_local_model_dir_ready_for(Capability::Vad, &found));

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn discovers_model_from_standard_hf_hub_refs_main_snapshot() {
        let root = std::env::temp_dir().join(format!("acpm-hf-hub-test-{}", Uuid::new_v4()));
        let models_dir = root.join("managed_models");
        let hf_hub = root.join("hf_hub");
        let repo_cache = hf_hub.join("models--Happenmasss--yanmo-correct-4b-cot-mlx-8bit");
        let snap_rev = "0123456789abcdef0123456789abcdef01234567";
        let snap_dir = repo_cache.join("snapshots").join(snap_rev);
        std::fs::create_dir_all(repo_cache.join("refs")).unwrap();
        std::fs::create_dir_all(&snap_dir).unwrap();
        std::fs::write(repo_cache.join("refs/main"), snap_rev).unwrap();
        std::fs::write(
            snap_dir.join("config.json"),
            r#"{"model_type":"qwen3_5","quantization":{"bits":8,"group_size":64}}"#,
        )
        .unwrap();
        std::fs::write(snap_dir.join("model.safetensors"), b"weights").unwrap();

        let test_manifest = r#"{
          "schema_version": 1,
          "models": [{
            "id": "yanmo-correct-4b-cot",
            "capability": "llm",
            "display_name": "Yanmo 4B CoT",
            "description": "test",
            "features": {"supports_cot": true, "supports_prompt_cache": true, "supports_voice_clone": false},
            "lifecycle": {"default_priority": "interactive", "idle_timeout_sec": 1200, "pin_policy": "auto", "kv_cache_slots": 4, "voice_cache_slots": 0},
            "variants": [
              {
                "variant_id": "darwin-arm64-mlx-4bit",
                "platform": "darwin-arm64",
                "accelerator": "mlx",
                "quant": "4bit",
                "engine": "mlx-swift",
                "compute_slot": {"type": "gpu", "device_id": 0},
                "footprint": {"unified_mb": 2950},
                "disk_mb": 2480,
                "files": [{"path": "config.json", "size": 10, "sha256": "0", "url": "https://models.example.invalid/4bit/config.json"}]
              },
              {
                "variant_id": "darwin-arm64-mlx-8bit",
                "platform": "darwin-arm64",
                "accelerator": "mlx",
                "quant": "8bit",
                "engine": "mlx-swift",
                "compute_slot": {"type": "gpu", "device_id": 0},
                "footprint": {"unified_mb": 5265},
                "disk_mb": 4282,
                "files": [{"path": "config.json", "size": 10, "sha256": "0", "url": "https://huggingface.co/Happenmasss/yanmo-correct-4b-cot-mlx-8bit/resolve/main/config.json"}]
              }
            ]
          }]
        }"#;

        let registry = ModelRegistry::from_json_str(test_manifest).unwrap();
        let (resolved, installed) = inspect_model_installation_with_hf_hub(
            &registry,
            "darwin-arm64",
            &models_dir,
            &BTreeMap::new(),
            "yanmo-correct-4b-cot",
            None,
            None,
            Some(&hf_hub),
        )
        .unwrap();

        assert!(installed);
        assert_eq!(resolved.variant.variant_id, "darwin-arm64-mlx-8bit");
        assert_eq!(resolved.model_dir, snap_dir);

        let _ = std::fs::remove_dir_all(&root);
    }
}
