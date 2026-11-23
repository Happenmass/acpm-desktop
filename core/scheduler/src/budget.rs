use acpm_protocol::{MemoryPool, PinPolicy, Priority, ResourceVector};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LoadedWorkerSnapshot {
    pub model_id: String,
    pub variant_id: String,
    pub footprint: ResourceVector,
    pub actual_memory: Option<ResourceVector>,
    pub in_flight: usize,
    pub pin_policy: PinPolicy,
    pub priority: Priority,
    pub last_active_at_ms: i64,
}

impl LoadedWorkerSnapshot {
    pub fn effective_memory(&self) -> &ResourceVector {
        self.actual_memory.as_ref().unwrap_or(&self.footprint)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdmissionRequest {
    pub model_id: String,
    pub footprint: ResourceVector,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AdmissionDecision {
    AdmitImmediate,
    EvictAndAdmit { evict_model_ids: Vec<String> },
    QueueWait { missing_pools: Vec<MemoryPool> },
    RejectedExceedsBudget { missing_pools: Vec<MemoryPool> },
}

/// Evaluates whether an incoming worker load fits within multi-pool resource budgets,
/// selecting lowest-priority idle LRU victims across overflowing pools when needed.
pub fn plan_admission(
    budget: &ResourceVector,
    loaded: &[LoadedWorkerSnapshot],
    incoming: &AdmissionRequest,
) -> AdmissionDecision {
    if !incoming.footprint.fits_within(budget) {
        return AdmissionDecision::RejectedExceedsBudget {
            missing_pools: incoming.footprint.overflowing_pools(budget),
        };
    }

    let current_used = loaded
        .iter()
        .fold(ResourceVector::default(), |acc, worker| {
            acc.add(worker.effective_memory())
        });
    let mut projected = current_used.add(&incoming.footprint);
    if projected.fits_within(budget) {
        return AdmissionDecision::AdmitImmediate;
    }

    let mut candidates: Vec<&LoadedWorkerSnapshot> = loaded
        .iter()
        .filter(|worker| {
            worker.in_flight == 0 && worker.pin_policy.eviction_rank().is_some()
        })
        .collect();

    candidates.sort_by_key(|worker| {
        (
            worker.pin_policy.eviction_rank().unwrap_or(u8::MAX),
            worker.priority.retention_rank(),
            worker.last_active_at_ms,
            worker.model_id.as_str(),
        )
    });

    let mut evict_model_ids = Vec::new();
    for victim in candidates {
        let missing = projected.overflowing_pools(budget);
        if missing.is_empty() {
            break;
        }
        let victim_mem = victim.effective_memory();
        if !victim_mem.touches_any_pool(&missing) {
            continue;
        }
        projected = projected.saturating_sub(victim_mem);
        evict_model_ids.push(victim.model_id.clone());
        if projected.fits_within(budget) {
            return AdmissionDecision::EvictAndAdmit { evict_model_ids };
        }
    }

    AdmissionDecision::QueueWait {
        missing_pools: projected.overflowing_pools(budget),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn worker(
        id: &str,
        mem: ResourceVector,
        priority: Priority,
        pin_policy: PinPolicy,
        in_flight: usize,
        last_active_at_ms: i64,
    ) -> LoadedWorkerSnapshot {
        LoadedWorkerSnapshot {
            model_id: id.to_string(),
            variant_id: "test".to_string(),
            footprint: mem,
            actual_memory: None,
            in_flight,
            pin_policy,
            priority,
            last_active_at_ms,
        }
    }

    #[test]
    fn admits_immediately_when_within_unified_budget() {
        let budget = ResourceVector::unified(7500);
        let loaded = vec![worker(
            "qwen3-asr-0.6b",
            ResourceVector::unified(950),
            Priority::Interactive,
            PinPolicy::Auto,
            0,
            100,
        )];
        let incoming = AdmissionRequest {
            model_id: "yanmo-correct-4b-cot".to_string(),
            footprint: ResourceVector::unified(2950),
        };
        assert_eq!(
            plan_admission(&budget, &loaded, &incoming),
            AdmissionDecision::AdmitImmediate
        );
    }

    #[test]
    fn evicts_batch_ephemeral_before_interactive_on_16gb_mac() {
        let budget = ResourceVector::unified(7000);
        let loaded = vec![
            worker(
                "yanmo-correct-4b-cot",
                ResourceVector::unified(2950),
                Priority::Interactive,
                PinPolicy::Auto,
                0,
                50, // older, but interactive priority protects it over batch
            ),
            worker(
                "qwen3-tts-1.7b",
                ResourceVector::unified(3250),
                Priority::Batch,
                PinPolicy::Ephemeral,
                0,
                200,
            ),
        ];
        let incoming = AdmissionRequest {
            model_id: "qwen3-asr-0.6b".to_string(),
            footprint: ResourceVector::unified(950),
        };
        assert_eq!(
            plan_admission(&budget, &loaded, &incoming),
            AdmissionDecision::EvictAndAdmit {
                evict_model_ids: vec!["qwen3-tts-1.7b".to_string()]
            }
        );
    }

    #[test]
    fn waits_when_required_memory_is_held_by_busy_or_pinned_workers() {
        let budget = ResourceVector::unified(5000);
        let loaded = vec![
            worker(
                "yanmo-correct-4b-cot",
                ResourceVector::unified(2950),
                Priority::Interactive,
                PinPolicy::Pinned,
                0,
                10,
            ),
            worker(
                "qwen3-tts-0.6b",
                ResourceVector::unified(1650),
                Priority::Batch,
                PinPolicy::Ephemeral,
                1, // busy running one sentence
                20,
            ),
        ];
        let incoming = AdmissionRequest {
            model_id: "qwen3-asr-0.6b".to_string(),
            footprint: ResourceVector::unified(950),
        };
        assert_eq!(
            plan_admission(&budget, &loaded, &incoming),
            AdmissionDecision::QueueWait {
                missing_pools: vec![MemoryPool::Unified]
            }
        );
    }

    #[test]
    fn rejects_single_model_larger_than_total_budget() {
        let budget = ResourceVector::unified(4000);
        let incoming = AdmissionRequest {
            model_id: "yanmo-correct-4b-cot".to_string(),
            footprint: ResourceVector::unified(4900),
        };
        assert_eq!(
            plan_admission(&budget, &[], &incoming),
            AdmissionDecision::RejectedExceedsBudget {
                missing_pools: vec![MemoryPool::Unified]
            }
        );
    }

    #[test]
    fn windows_dual_pool_ignores_cpu_ram_worker_when_only_vram_overflows() {
        let budget = ResourceVector::system_and_gpu(12000, 0, 8000);
        let loaded = vec![
            worker(
                "speech-speaker-eres2net",
                ResourceVector::system_and_gpu(300, 0, 0),
                Priority::Batch,
                PinPolicy::Ephemeral,
                0,
                10,
            ),
            worker(
                "qwen3-tts-1.7b",
                ResourceVector::system_and_gpu(650, 0, 4800),
                Priority::Batch,
                PinPolicy::Ephemeral,
                0,
                50,
            ),
        ];
        let incoming = AdmissionRequest {
            model_id: "yanmo-correct-4b-cot".to_string(),
            footprint: ResourceVector::system_and_gpu(650, 0, 3800),
        };
        assert_eq!(
            plan_admission(&budget, &loaded, &incoming),
            AdmissionDecision::EvictAndAdmit {
                evict_model_ids: vec!["qwen3-tts-1.7b".to_string()]
            }
        );
    }
}
