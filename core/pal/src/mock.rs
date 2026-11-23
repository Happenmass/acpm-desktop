use crate::{HostProfile, PalError, SystemTelemetry};
use acpm_protocol::{MemoryPressure, ResourceVector, ThermalState};
use std::collections::BTreeMap;

#[derive(Debug, Clone)]
pub struct MockTelemetry {
    pub profile: HostProfile,
    pub pressure: MemoryPressure,
    pub thermal: ThermalState,
}

impl MockTelemetry {
    pub fn mac_16gb() -> Self {
        Self {
            profile: HostProfile {
                platform: "darwin-arm64".to_string(),
                is_unified_memory: true,
                total_system_ram_mb: 16384,
                metal_recommended_max_ws_mb: Some(11468),
                gpu_vram_total_mb: BTreeMap::new(),
                cpu_cores: 8,
            },
            pressure: MemoryPressure::Normal,
            thermal: ThermalState::Nominal,
        }
    }

    pub fn mac_36gb() -> Self {
        Self {
            profile: HostProfile {
                platform: "darwin-arm64".to_string(),
                is_unified_memory: true,
                total_system_ram_mb: 36864,
                metal_recommended_max_ws_mb: Some(27648),
                gpu_vram_total_mb: BTreeMap::new(),
                cpu_cores: 14,
            },
            pressure: MemoryPressure::Normal,
            thermal: ThermalState::Nominal,
        }
    }

    pub fn windows_cuda_12gb() -> Self {
        let mut gpu = BTreeMap::new();
        gpu.insert(0, 12288);
        Self {
            profile: HostProfile {
                platform: "windows-x64".to_string(),
                is_unified_memory: false,
                total_system_ram_mb: 32768,
                metal_recommended_max_ws_mb: None,
                gpu_vram_total_mb: gpu,
                cpu_cores: 16,
            },
            pressure: MemoryPressure::Normal,
            thermal: ThermalState::Nominal,
        }
    }
}

impl SystemTelemetry for MockTelemetry {
    fn host_profile(&self) -> Result<HostProfile, PalError> {
        Ok(self.profile.clone())
    }

    fn process_memory(&self, _pid: u32) -> Result<ResourceVector, PalError> {
        Ok(ResourceVector::default())
    }

    fn memory_pressure(&self) -> MemoryPressure {
        self.pressure
    }

    fn thermal_state(&self) -> ThermalState {
        self.thermal
    }
}
