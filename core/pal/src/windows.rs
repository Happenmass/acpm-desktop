use crate::{
    HostProfile, LocalTransportAuth, PalError, PowerEvent, PowerObserver, ProcessSupervisor,
    SystemTelemetry, WorkerProcessHandle,
};
use acpm_protocol::{MemoryPressure, ResourceVector, ThermalState, WorkerLaunchConfig};
use std::collections::BTreeMap;

/// Windows x64 + CUDA PAL implementation placeholder.
/// Future implementation will load `nvml.dll` dynamically for multi-GPU VRAM telemetry,
/// assign workers to a Win32 Job Object (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`),
/// and authenticate Named Pipe callers via user SID ACL + Authenticode verification.
#[derive(Debug, Default)]
pub struct WindowsTelemetry;

impl WindowsTelemetry {
    pub fn new() -> Self {
        Self
    }
}

impl SystemTelemetry for WindowsTelemetry {
    fn host_profile(&self) -> Result<HostProfile, PalError> {
        let mut gpu = BTreeMap::new();
        gpu.insert(0, 12288);
        Ok(HostProfile {
            platform: "windows-x64".to_string(),
            is_unified_memory: false,
            total_system_ram_mb: 32768,
            metal_recommended_max_ws_mb: None,
            gpu_vram_total_mb: gpu,
            cpu_cores: std::thread::available_parallelism()
                .map(|n| n.get())
                .unwrap_or(8),
        })
    }

    fn process_memory(&self, _pid: u32) -> Result<ResourceVector, PalError> {
        Ok(ResourceVector::default())
    }

    fn memory_pressure(&self) -> MemoryPressure {
        MemoryPressure::Normal
    }

    fn thermal_state(&self) -> ThermalState {
        ThermalState::Nominal
    }
}

#[derive(Debug, Default)]
pub struct WindowsProcessSupervisor;

impl ProcessSupervisor for WindowsProcessSupervisor {
    fn prepare_spawn(&self, _config: &WorkerLaunchConfig) -> Result<(), PalError> {
        Ok(())
    }

    fn force_terminate(&self, _handle: &WorkerProcessHandle) -> Result<(), PalError> {
        Err(PalError::Unsupported(
            "Windows Job Object termination not yet implemented".to_string(),
        ))
    }
}

#[derive(Debug, Default)]
pub struct WindowsLocalTransportAuth;

impl LocalTransportAuth for WindowsLocalTransportAuth {
    fn verify_native_caller(&self, caller_pid: u32) -> Result<String, PalError> {
        Ok(format!("windows-pid-{caller_pid}"))
    }
}

#[derive(Debug, Default)]
pub struct WindowsPowerObserver;

impl PowerObserver for WindowsPowerObserver {
    fn poll_event(&self) -> Option<PowerEvent> {
        None
    }
}
