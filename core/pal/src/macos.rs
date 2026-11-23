use crate::{
    HostProfile, LocalTransportAuth, PalError, PowerEvent, PowerObserver, ProcessSupervisor,
    SystemTelemetry, WorkerProcessHandle,
};
use acpm_protocol::{MemoryPressure, ResourceVector, ThermalState, WorkerLaunchConfig};
use std::collections::BTreeMap;
use std::ffi::CString;
use std::mem;
use std::process::Command;

/// macOS 15+ Apple Silicon PAL implementation backed by `proc_pid_rusage`
/// (`ri_phys_footprint`) and `sysctlbyname` memory pressure queries.
#[derive(Debug, Default)]
pub struct MacosTelemetry;

impl MacosTelemetry {
    pub fn new() -> Self {
        Self
    }

    fn query_sysctl_u64(key: &str) -> Option<u64> {
        let c_key = CString::new(key).ok()?;
        let mut value: u64 = 0;
        let mut size = mem::size_of::<u64>();
        let rc = unsafe {
            libc::sysctlbyname(
                c_key.as_ptr(),
                (&mut value as *mut u64).cast::<libc::c_void>(),
                &mut size,
                std::ptr::null_mut(),
                0,
            )
        };
        if rc == 0 && size == mem::size_of::<u64>() {
            return Some(value);
        }

        let output = Command::new("sysctl").args(["-n", key]).output().ok()?;
        if !output.status.success() {
            return None;
        }
        String::from_utf8_lossy(&output.stdout).trim().parse::<u64>().ok()
    }

    fn query_sysctl_i32(key: &str) -> Option<i32> {
        let c_key = CString::new(key).ok()?;
        let mut value: i32 = 0;
        let mut size = mem::size_of::<i32>();
        let rc = unsafe {
            libc::sysctlbyname(
                c_key.as_ptr(),
                (&mut value as *mut i32).cast::<libc::c_void>(),
                &mut size,
                std::ptr::null_mut(),
                0,
            )
        };
        if rc == 0 && size == mem::size_of::<i32>() {
            Some(value)
        } else {
            None
        }
    }
}

impl SystemTelemetry for MacosTelemetry {
    fn host_profile(&self) -> Result<HostProfile, PalError> {
        let mem_bytes = Self::query_sysctl_u64("hw.memsize").unwrap_or(16 * 1024 * 1024 * 1024);
        let total_mb = mem_bytes / (1024 * 1024);
        let cpu_cores = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(8);

        // Apple Silicon recommended working-set ratio (~70% of physical RAM).
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

    fn process_memory(&self, pid: u32) -> Result<ResourceVector, PalError> {
        let mut info: libc::rusage_info_v4 = unsafe { mem::zeroed() };
        let rc = unsafe {
            libc::proc_pid_rusage(
                pid as libc::c_int,
                libc::RUSAGE_INFO_V4,
                (&mut info as *mut libc::rusage_info_v4).cast::<libc::rusage_info_t>(),
            )
        };
        if rc != 0 {
            return Err(PalError::Process(format!(
                "proc_pid_rusage({pid}) failed: {}",
                std::io::Error::last_os_error()
            )));
        }
        let unified_mb = info.ri_phys_footprint / (1024 * 1024);
        Ok(ResourceVector::unified(unified_mb))
    }

    fn memory_pressure(&self) -> MemoryPressure {
        match Self::query_sysctl_i32("kern.memorystatus_vm_pressure_level") {
            Some(level) if level >= 4 => MemoryPressure::Critical,
            Some(2) => MemoryPressure::Warn,
            _ => MemoryPressure::Normal,
        }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn queries_host_profile_and_self_physical_footprint() {
        let telemetry = MacosTelemetry::new();
        let profile = telemetry.host_profile().expect("host_profile should succeed");
        assert!(profile.total_system_ram_mb > 0);
        if cfg!(target_arch = "aarch64") {
            assert!(profile.is_unified_memory);
            assert_eq!(profile.platform, "darwin-arm64");
        }

        let self_mem = telemetry
            .process_memory(std::process::id())
            .expect("proc_pid_rusage for current process should succeed");
        assert!(self_mem.unified_mb > 0, "expected positive ri_phys_footprint MB");
        let _ = telemetry.memory_pressure();
    }
}
