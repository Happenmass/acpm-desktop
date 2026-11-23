#[cfg(target_os = "macos")]
pub mod macos;
pub mod mock;
#[cfg(target_os = "windows")]
pub mod windows;

use acpm_protocol::{
    MemoryPressure, ResourceVector, ThermalState, WorkerLaunchConfig,
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum PalError {
    #[error("platform io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("process supervision error: {0}")]
    Process(String),
    #[error("authentication error: {0}")]
    Auth(String),
    #[error("unsupported platform operation: {0}")]
    Unsupported(String),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostProfile {
    pub platform: String,
    pub is_unified_memory: bool,
    pub total_system_ram_mb: u64,
    pub metal_recommended_max_ws_mb: Option<u64>,
    pub gpu_vram_total_mb: BTreeMap<u32, u64>,
    pub cpu_cores: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimePaths {
    pub data_dir: PathBuf,
    pub runtime_json: PathBuf,
    pub native_ipc_path: PathBuf,
    pub config_json: PathBuf,
    pub diagnostics_db: PathBuf,
    pub models_dir: PathBuf,
    pub voices_dir: PathBuf,
}

impl RuntimePaths {
    pub fn from_data_dir(data_dir: impl AsRef<Path>) -> Self {
        let base = data_dir.as_ref().to_path_buf();
        #[cfg(target_os = "windows")]
        let ipc_path = PathBuf::from(r"\\.\pipe\acpm-desktop-daemon");
        #[cfg(not(target_os = "windows"))]
        let ipc_path = base.join("daemon.sock");

        Self {
            runtime_json: base.join("runtime.json"),
            native_ipc_path: ipc_path,
            config_json: base.join("config.json"),
            diagnostics_db: base.join("diagnostics.db"),
            models_dir: base.join("models"),
            voices_dir: base.join("voices"),
            data_dir: base,
        }
    }

    pub fn default_for_current_os() -> Self {
        #[cfg(target_os = "macos")]
        {
            if let Some(home) = std::env::var_os("HOME") {
                let dir = PathBuf::from(home)
                    .join("Library")
                    .join("Application Support")
                    .join("acpm-desktop");
                return Self::from_data_dir(dir);
            }
        }
        #[cfg(target_os = "windows")]
        {
            if let Some(local_app_data) = std::env::var_os("LOCALAPPDATA") {
                let dir = PathBuf::from(local_app_data).join("acpm-desktop");
                return Self::from_data_dir(dir);
            }
        }
        Self::from_data_dir(std::env::temp_dir().join("acpm-desktop"))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PowerEvent {
    WillSleep,
    ScreenLocked,
    DidWake,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkerProcessHandle {
    pub pid: u32,
    pub model_id: String,
    pub ipc_path: String,
}

pub trait SystemTelemetry: Send + Sync {
    fn host_profile(&self) -> Result<HostProfile, PalError>;
    fn process_memory(&self, pid: u32) -> Result<ResourceVector, PalError>;
    fn memory_pressure(&self) -> MemoryPressure;
    fn thermal_state(&self) -> ThermalState;
}

pub trait ProcessSupervisor: Send + Sync {
    fn prepare_spawn(&self, config: &WorkerLaunchConfig) -> Result<(), PalError>;
    fn force_terminate(&self, handle: &WorkerProcessHandle) -> Result<(), PalError>;
}

pub trait LocalTransportAuth: Send + Sync {
    fn verify_native_caller(&self, caller_pid: u32) -> Result<String, PalError>;
}

pub trait PowerObserver: Send + Sync {
    fn poll_event(&self) -> Option<PowerEvent>;
}

pub fn default_telemetry() -> Box<dyn SystemTelemetry> {
    #[cfg(target_os = "macos")]
    {
        return Box::new(macos::MacosTelemetry::new());
    }
    #[cfg(target_os = "windows")]
    {
        return Box::new(windows::WindowsTelemetry::new());
    }
    #[allow(unreachable_code)]
    Box::new(mock::MockTelemetry::mac_16gb())
}
