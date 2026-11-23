use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MemoryPool {
    Unified,
    SystemRam,
    GpuVram(u32),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ComputeSlot {
    Gpu { device_id: u32 },
    Cpu,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Priority {
    Interactive,
    #[default]
    Normal,
    Batch,
}

impl Priority {
    /// Lower rank means earlier eviction and lower scheduling priority.
    pub fn retention_rank(&self) -> u8 {
        match self {
            Self::Batch => 0,
            Self::Normal => 1,
            Self::Interactive => 2,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum MemoryPressure {
    #[default]
    Normal,
    Warn,
    Critical,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum ThermalState {
    #[default]
    Nominal,
    Fair,
    Serious,
    Critical,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum BudgetTier {
    Eco,
    #[default]
    Balanced,
    Performance,
}

fn is_zero(value: &u64) -> bool {
    *value == 0
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResourceVector {
    #[serde(default, skip_serializing_if = "is_zero")]
    pub unified_mb: u64,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub system_ram_mb: u64,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub gpu_vram_mb: BTreeMap<u32, u64>,
}

impl ResourceVector {
    pub fn unified(mb: u64) -> Self {
        Self {
            unified_mb: mb,
            ..Self::default()
        }
    }

    pub fn system_and_gpu(system_ram_mb: u64, device_id: u32, gpu_vram_mb: u64) -> Self {
        let mut gpu = BTreeMap::new();
        if gpu_vram_mb > 0 {
            gpu.insert(device_id, gpu_vram_mb);
        }
        Self {
            unified_mb: 0,
            system_ram_mb,
            gpu_vram_mb: gpu,
        }
    }

    pub fn add(&self, other: &Self) -> Self {
        let mut gpu = self.gpu_vram_mb.clone();
        for (dev, mb) in &other.gpu_vram_mb {
            *gpu.entry(*dev).or_insert(0) += *mb;
        }
        Self {
            unified_mb: self.unified_mb.saturating_add(other.unified_mb),
            system_ram_mb: self.system_ram_mb.saturating_add(other.system_ram_mb),
            gpu_vram_mb: gpu,
        }
    }

    pub fn saturating_sub(&self, other: &Self) -> Self {
        let mut gpu = self.gpu_vram_mb.clone();
        for (dev, mb) in &other.gpu_vram_mb {
            if let Some(existing) = gpu.get_mut(dev) {
                *existing = existing.saturating_sub(*mb);
                if *existing == 0 {
                    gpu.remove(dev);
                }
            }
        }
        Self {
            unified_mb: self.unified_mb.saturating_sub(other.unified_mb),
            system_ram_mb: self.system_ram_mb.saturating_sub(other.system_ram_mb),
            gpu_vram_mb: gpu,
        }
    }

    pub fn fits_within(&self, budget: &Self) -> bool {
        if self.unified_mb > budget.unified_mb {
            return false;
        }
        if self.system_ram_mb > budget.system_ram_mb {
            return false;
        }
        for (dev, req_mb) in &self.gpu_vram_mb {
            let cap_mb = budget.gpu_vram_mb.get(dev).copied().unwrap_or(0);
            if *req_mb > cap_mb {
                return false;
            }
        }
        true
    }

    pub fn overflowing_pools(&self, budget: &Self) -> Vec<MemoryPool> {
        let mut pools = Vec::new();
        if self.unified_mb > budget.unified_mb {
            pools.push(MemoryPool::Unified);
        }
        if self.system_ram_mb > budget.system_ram_mb {
            pools.push(MemoryPool::SystemRam);
        }
        for (dev, req_mb) in &self.gpu_vram_mb {
            let cap_mb = budget.gpu_vram_mb.get(dev).copied().unwrap_or(0);
            if *req_mb > cap_mb {
                pools.push(MemoryPool::GpuVram(*dev));
            }
        }
        pools
    }

    pub fn touches_any_pool(&self, pools: &[MemoryPool]) -> bool {
        pools.iter().any(|pool| match pool {
            MemoryPool::Unified => self.unified_mb > 0,
            MemoryPool::SystemRam => self.system_ram_mb > 0,
            MemoryPool::GpuVram(dev) => self.gpu_vram_mb.get(dev).copied().unwrap_or(0) > 0,
        })
    }

    pub fn total_mb(&self) -> u64 {
        let gpu_sum: u64 = self.gpu_vram_mb.values().sum();
        self.unified_mb
            .saturating_add(self.system_ram_mb)
            .saturating_add(gpu_sum)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResourceBudget {
    pub tier: BudgetTier,
    pub limits: ResourceVector,
    pub max_concurrent_gpu: usize,
    pub max_concurrent_cpu: usize,
}
