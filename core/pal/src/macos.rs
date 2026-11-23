use crate::{
    HostProfile, LocalTransportAuth, PalError, PowerEvent, PowerObserver, ProcessSupervisor,
    SystemTelemetry, WorkerProcessHandle,
};
use acpm_protocol::{MemoryPressure, ResourceVector, ThermalState, WorkerLaunchConfig};
use std::collections::BTreeMap;
use std::process::Command;

/// macOS 15+ Apple Silicon PAL implementation skeleton.
/// Phase 1 will bind `proc_pid_rusage` (`ri_phys_footprint`), Metal working set queries,
/// `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`, `LOCAL_PEERTOKEN`, and `NSWorkspace` notifications.
#[derive(Debug, Default)]
pub struct MacosTelemetry;

impl MacosTelemetry {
    pub fn new() -> Self {
        Self
    }

    fn query_sysctl_u64(key: &str) -> Option<u64> {
        let output = Command::new("sysctl").args(["-n", key]).output().ok()?;
        if !output.status.success() {
            return None;
        }
        String::from_utf8_lossy(&output.stdout).trim().parse::<u64>().ok()
    }
}

impl SystemTelemetry for MacosTelemetry {
    fn host_profile(&self) -> Result<HostProfile, PalError> {
        let mem_bytes = Self::query_sysctl_u64("hw.memsize").unwrap_or(16 * 1024 * 1024 * 1024);
        let total_mb = mem_bytes / (1024 * 1024);
        let cpu_cores = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(8);

        // Conservative fallback until Metal MTLDevice query is bound in Phase 1.
        let metal_ws_mb = (total_mb as f64 * 0.70) as u64;
        let arch = if cfg!(target_arch = "aarch64") {
            "darwin-arm64"
        } else {
            "darwin-x64"
        };

        Ok(HostProfile {
            platform: arch.to_string(),
            is_unified_memory: cfg!(target_arch = "aarch64"),
            total_system_ram_mb: total_mb,
            metal_recommended_max_ws_mb: Some(metal_ws_mb),
            gpu_vram_total_mb: BTreeMap::new(),
            cpu_cores,
        })
    }

    fn process_memory(&self, _pid: u32) -> Result<ResourceVector, PalError> {
        // Phase 1: invoke proc_pid_rusage(pid, RUSAGE_INFO_V4, ...) for ri_phys_footprint.
        Ok(ResourceVector::unified(0))
    }

    fn memory_pressure(&self) -> MemoryPressure {
        MemoryPressure::Normal
    }

    fn thermal_state(&self) -> ThermalState {
        ThermalState::Nominal
    }
}

#[derive(Debug, Default)]
pub struct MacosProcessSupervisor;

impl ProcessSupervisor for MacosProcessSupervisor {
    fn prepare_spawn(&self, _config: &WorkerLaunchConfig) -> Result<(), PalError> {
        Ok(())
    }

    fn force_terminate(&self, handle: &WorkerProcessHandle) -> Result<(), PalError> {
        let status = Command::new("kill")
            .args(["-KILL", &handle.pid.to_string()])
            .status()?;
        if status.success() {
            Ok(())
        } else {
            Err(PalError::Process(format!(
                "failed to terminate worker pid {}",
                handle.pid
            )))
        }
    }
}

#[derive(Debug, Default)]
pub struct MacosLocalTransportAuth;

impl LocalTransportAuth for MacosLocalTransportAuth {
    fn verify_native_caller(&self, caller_pid: u32) -> Result<String, PalError> {
        // Phase 1: validate Team ID via SecCodeCopyGuestWithAttributes from LOCAL_PEERTOKEN.
        Ok(format!("macos-pid-{caller_pid}"))
    }
}

#[derive(Debug, Default)]
pub struct MacosPowerObserver;

impl PowerObserver for MacosPowerObserver {
    fn poll_event(&self) -> Option<PowerEvent> {
        None
    }
}
