use acpm_pal::HostProfile;
use acpm_protocol::{
    BudgetTier, ModelEntry, ModelVariant, RegistryManifest, ResourceBudget, ResourceVector,
};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use thiserror::Error;

const EMBEDDED_MANIFEST_JSON: &str = include_str!("../../../manifests/registry.example.json");

#[derive(Debug, Error)]
pub enum RegistryError {
    #[error("failed to parse registry manifest: {0}")]
    InvalidManifest(#[from] serde_json::Error),
    #[error("failed to read manifest file: {0}")]
    Io(#[from] std::io::Error),
    #[error("model '{0}' not found in registry")]
    ModelNotFound(String),
    #[error("no compatible variant of '{model_id}' for platform '{platform}'")]
    UnsupportedPlatform { model_id: String, platform: String },
}

#[derive(Debug, Clone)]
pub struct ModelRegistry {
    manifest: RegistryManifest,
}

impl ModelRegistry {
    pub fn from_json_str(raw: &str) -> Result<Self, RegistryError> {
        let manifest: RegistryManifest = serde_json::from_str(raw)?;
        Ok(Self { manifest })
    }

    pub fn from_file(path: &Path) -> Result<Self, RegistryError> {
        let raw = std::fs::read_to_string(path)?;
        Self::from_json_str(&raw)
    }

    pub fn embedded_default() -> Result<Self, RegistryError> {
        Self::from_json_str(EMBEDDED_MANIFEST_JSON)
    }

    pub fn models(&self) -> &[ModelEntry] {
        &self.manifest.models
    }

    pub fn find_model(&self, model_id: &str) -> Option<&ModelEntry> {
        self.manifest.models.iter().find(|entry| entry.id == model_id)
    }

    pub fn resolve_variant(
        &self,
        model_id: &str,
        platform: &str,
        preferred_quant: Option<&str>,
    ) -> Result<(&ModelEntry, &ModelVariant), RegistryError> {
        let entry = self
            .find_model(model_id)
            .ok_or_else(|| RegistryError::ModelNotFound(model_id.to_string()))?;

        let matching: Vec<&ModelVariant> = entry
            .variants
            .iter()
            .filter(|v| v.platform == platform || v.platform == "any")
            .collect();

        if matching.is_empty() {
            return Err(RegistryError::UnsupportedPlatform {
                model_id: model_id.to_string(),
                platform: platform.to_string(),
            });
        }

        if let Some(quant) = preferred_quant {
            if let Some(exact) = matching
                .iter()
                .copied()
                .find(|v| v.quant.as_deref() == Some(quant))
            {
                return Ok((entry, exact));
            }
        }

        let platform_preferred = matching
            .iter()
            .copied()
            .find(|v| v.platform == platform)
            .unwrap_or(matching[0]);

        Ok((entry, platform_preferred))
    }

    pub fn variant_dir(models_root: &Path, model_id: &str, variant: &ModelVariant) -> PathBuf {
        models_root.join(model_id).join(&variant.variant_id)
    }

    pub fn is_variant_installed(&self, models_root: &Path, model_id: &str, variant: &ModelVariant) -> bool {
        let dir = Self::variant_dir(models_root, model_id, variant);
        if !dir.is_dir() {
            return false;
        }
        variant.files.iter().all(|file| {
            let path = dir.join(&file.path);
            match std::fs::metadata(&path) {
                Ok(meta) => meta.is_file() && meta.len() == file.size,
                Err(_) => false,
            }
        })
    }
}

pub fn compute_default_budget(profile: &HostProfile, tier: BudgetTier) -> ResourceBudget {
    if profile.is_unified_memory {
        let (ram_ratio, ws_ratio) = match tier {
            BudgetTier::Eco => (0.30, 0.55),
            BudgetTier::Balanced => (0.48, 0.72),
            BudgetTier::Performance => (0.65, 0.85),
        };
        let ram_cap = (profile.total_system_ram_mb as f64 * ram_ratio) as u64;
        let ws_cap = profile
            .metal_recommended_max_ws_mb
            .map(|ws| (ws as f64 * ws_ratio) as u64)
            .unwrap_or(ram_cap);
        ResourceBudget {
            tier,
            limits: ResourceVector::unified(ram_cap.min(ws_cap)),
            max_concurrent_gpu: 1,
            max_concurrent_cpu: (profile.cpu_cores / 2).clamp(1, 4),
        }
    } else {
        let (ram_ratio, vram_ratio) = match tier {
            BudgetTier::Eco => (0.25, 0.65),
            BudgetTier::Balanced => (0.35, 0.80),
            BudgetTier::Performance => (0.50, 0.90),
        };
        let mut gpu_limits = BTreeMap::new();
        for (dev, total_vram) in &profile.gpu_vram_total_mb {
            gpu_limits.insert(*dev, (*total_vram as f64 * vram_ratio) as u64);
        }
        ResourceBudget {
            tier,
            limits: ResourceVector {
                unified_mb: 0,
                system_ram_mb: (profile.total_system_ram_mb as f64 * ram_ratio) as u64,
                gpu_vram_mb: gpu_limits,
            },
            max_concurrent_gpu: 1,
            max_concurrent_cpu: (profile.cpu_cores / 2).clamp(1, 4),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HardwareRecommendation {
    pub profile_label: String,
    pub recommended_asr: &'static str,
    pub recommended_llm_quant: &'static str,
    pub recommended_tts: &'static str,
    pub allows_dual_hot_residency: bool,
}

pub fn recommend_for_host(profile: &HostProfile) -> HardwareRecommendation {
    if profile.is_unified_memory {
        if profile.total_system_ram_mb < 12 * 1024 {
            HardwareRecommendation {
                profile_label: "Apple Silicon (<=8GB Unified)".to_string(),
                recommended_asr: "qwen3-asr-0.6b",
                recommended_llm_quant: "4bit",
                recommended_tts: "qwen3-tts-0.6b",
                allows_dual_hot_residency: false,
            }
        } else if profile.total_system_ram_mb < 22 * 1024 {
            HardwareRecommendation {
                profile_label: "Apple Silicon (16GB Unified)".to_string(),
                recommended_asr: "qwen3-asr-0.6b",
                recommended_llm_quant: "4bit",
                recommended_tts: "qwen3-tts-0.6b",
                allows_dual_hot_residency: true,
            }
        } else {
            HardwareRecommendation {
                profile_label: "Apple Silicon (24GB+ Unified)".to_string(),
                recommended_asr: "qwen3-asr-1.7b",
                recommended_llm_quant: "4bit",
                recommended_tts: "qwen3-tts-1.7b",
                allows_dual_hot_residency: true,
            }
        }
    } else {
        let vram_mb = profile.gpu_vram_total_mb.get(&0).copied().unwrap_or(0);
        HardwareRecommendation {
            profile_label: format!("Discrete CUDA ({vram_mb} MB VRAM)"),
            recommended_asr: if vram_mb >= 11 * 1024 {
                "qwen3-asr-1.7b"
            } else {
                "qwen3-asr-0.6b"
            },
            recommended_llm_quant: "q4_k_m",
            recommended_tts: if vram_mb >= 11 * 1024 {
                "qwen3-tts-1.7b"
            } else {
                "qwen3-tts-0.6b"
            },
            allows_dual_hot_residency: vram_mb >= 10 * 1024,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use acpm_pal::mock::MockTelemetry;
    use acpm_pal::SystemTelemetry;

    #[test]
    fn parses_embedded_manifest_and_resolves_cross_platform_variants() {
        let registry = ModelRegistry::embedded_default().expect("embedded manifest should parse");
        assert!(registry.models().len() >= 7);

        let (_, mac_llm) = registry
            .resolve_variant("yanmo-correct-4b-cot", "darwin-arm64", Some("4bit"))
            .expect("mac 4bit variant");
        assert_eq!(mac_llm.engine, "mlx-swift");
        assert_eq!(mac_llm.footprint.unified_mb, 2950);

        let (_, win_llm) = registry
            .resolve_variant("yanmo-correct-4b-cot", "windows-x64", None)
            .expect("windows variant");
        assert_eq!(win_llm.engine, "cuda-llamacpp");
        assert_eq!(win_llm.footprint.gpu_vram_mb.get(&0).copied(), Some(3100));

        let (_, vad_mac) = registry
            .resolve_variant("speech-vad-pyannote", "darwin-arm64", None)
            .expect("platform=any variant resolves on mac");
        assert_eq!(vad_mac.engine, "sherpa-onnx");
        assert_eq!(vad_mac.files[0].size, 5_992_913);
    }

    #[test]
    fn computes_platform_budgets_and_hardware_tiers() {
        let mac16 = MockTelemetry::mac_16gb().host_profile().unwrap();
        let b16 = compute_default_budget(&mac16, BudgetTier::Balanced);
        assert!(b16.limits.unified_mb > 7000 && b16.limits.unified_mb < 9000);
        assert_eq!(recommend_for_host(&mac16).recommended_asr, "qwen3-asr-0.6b");

        let mac36 = MockTelemetry::mac_36gb().host_profile().unwrap();
        let rec36 = recommend_for_host(&mac36);
        assert_eq!(rec36.recommended_asr, "qwen3-asr-1.7b");
        assert_eq!(rec36.recommended_tts, "qwen3-tts-1.7b");

        let win12 = MockTelemetry::windows_cuda_12gb().host_profile().unwrap();
        let b_win = compute_default_budget(&win12, BudgetTier::Balanced);
        assert_eq!(b_win.limits.gpu_vram_mb.get(&0).copied(), Some(9830));
    }
}
