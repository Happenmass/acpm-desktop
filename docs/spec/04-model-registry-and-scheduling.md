# 04 — 模型清单、资源调度与诊断存储规范

本规范定义跨平台模型清单 `registry.json` Schema、多资源池准入与驱逐算法、硬件自动分档以及脱敏诊断隐私边界。

---

## 1. 逻辑模型清单规范（`registry.json`）

调用方永远使用稳定的**逻辑模型 ID**（如 `yanmo-correct-4b-cot`、`qwen3-asr-0.6b`）。`acpm-registry` 在运行时根据当前 OS/架构/加速器和用户量化偏好自动解析到对应物理变体（`variant`）。

### 1.1 清单字段定义

```json
{
  "schema_version": 1,
  "models": [
    {
      "id": "yanmo-correct-4b-cot",
      "capability": "llm",
      "display_name": "Yanmo 4B CoT 后纠错",
      "description": "面向语音输入后纠错优化的本地 4B CoT 模型",
      "features": {
        "supports_cot": true,
        "supports_prompt_cache": true
      },
      "lifecycle": {
        "default_priority": "interactive",
        "idle_timeout_sec": 1200,
        "pin_policy": "auto",
        "kv_cache_slots": 4
      },
      "variants": [
        {
          "variant_id": "darwin-arm64-mlx-4bit",
          "platform": "darwin-arm64",
          "accelerator": "mlx",
          "quant": "4bit",
          "engine": "mlx-swift",
          "compute_slot": { "type": "gpu", "device_id": 0 },
          "footprint": { "unified_mb": 2950 },
          "disk_mb": 2450,
          "files": [
            {
              "path": "config.json",
              "size": 1024,
              "sha256": "...",
              "url": "https://example.invalid/models/yanmo-correct-4b-cot-mlx-4bit/config.json"
            }
          ]
        }
      ]
    }
  ]
}
```

### 1.2 原子校验与断点下载规则

1. **变体目录**：`<model_root>/<logical_id>/<variant_id>/`。
2. **断点续传**：所有文件下载先写入 `<file>.part`；支持 HTTP `Range` 续传。
3. **强制校验**：下载完成后比对 `size` 与 `sha256`，全部文件通过校验后再写入 `.complete.json` 标记；校验失败立即清理损坏分片并上报 `MODEL_PREPARE / SHA256_MISMATCH`。
4. **平台无关权重**：`platform: "any"`（例如 `speech-vad-pyannote` 与 `speech-speaker-eres2net` 的 ONNX 文件）在 macOS 与 Windows 共用同一份校验清单。

---

## 2. 资源预算、准入与驱逐算法

### 2.1 默认内存/显存预算计算

| 运行档位 | macOS Apple Silicon (`Unified`) | Windows CUDA (`GpuVram(d)` / `SystemRam`) |
| --- | --- | --- |
| **节能 (Eco)** | `min(total_ram * 0.30, metal_max_ws * 0.55)` | `vram_total * 0.65` / `ram_total * 0.25` |
| **均衡 (Balanced, 默认)** | `min(total_ram * 0.48, metal_max_ws * 0.72)` | `vram_total * 0.80` / `ram_total * 0.35` |
| **性能 (Performance)** | `min(total_ram * 0.65, metal_max_ws * 0.85)` | `vram_total * 0.90` / `ram_total * 0.50` |

> 示例：36GB Apple Silicon（如 M3 Max），`Balanced` 默认可用模型预算约为 17–18 GB，可轻松让 4B CoT + Qwen3-ASR 1.7B + Qwen3-TTS 1.7B 同时保持热态，同时不挤占系统与浏览器工作内存；16GB 机型默认预算约 7.5–8 GB。

### 2.2 准入与驱逐算法（`plan_admission`）

当请求需要加载尚未处于 `WARM`/`RUNNING` 的目标模型变体 $M_{\text{in}}$（资源需求向量 $R_{\text{in}}$）时：

1. **检查超限**：如果 $R_{\text{in}}[p] > B[p]$（单模型即超过总预算），直接拒绝加载，返回 `507 INSUFFICIENT_MEMORY` 并在控制台给出小量化/小尺寸推荐。
2. **尝试直接准入**：若对所有池均有 $U[p] + R_{\text{in}}[p] \le B[p]$，返回 `AdmitImmediate`。
3. **筛选可驱逐候选集**：在当前已加载 Worker 中过滤出满足以下条件者：
   - 与 $R_{\text{in}}$ 在至少一个紧缺内存池存在交集；
   - 当前无正在执行的推理（`in_flight == 0`）；
   - 未被固定（`pin_policy != Pinned`）。
4. **驱逐排序键（从小到大优先淘汰）**：
   `(pin_rank, priority_rank, last_active_at_ms)`
   - 其中 `pin_rank`：`Ephemeral(0) < Auto(1)`；
   - `priority_rank`：`Batch(0) < Normal(1) < Interactive(2)`（优先腾退批量 TTS 等批处理模型，最大程度保护输入法用的 ASR 与 4B LLM）；
   - 同优先级按 `last_active_at_ms` 最久未使用（LRU）淘汰。
5. **决策结果**：
   - 累加淘汰候选释放的内存后若可满足准入，返回 `EvictAndAdmit(evict_list)`，由调度器先优雅关停待驱逐 Worker 并确认退出后再拉起 $M_{\text{in}}$；
   - 若因其余模型均为 `RUNNING`（忙）或 `Pinned` 导致仍不够，返回 `QueueWait`，等待在跑句/窗完成后再重新评估，避免强行加载触发系统 Swap 抖动。

### 2.3 空闲回收与系统信号响应

| 事件 | 默认动作 |
| --- | --- |
| **空闲超时（Idle TTL）** | 默认：`llm`/`asr` **1200s**（20 分钟）、`tts` **180s**（3 分钟）、`vad`/`diarization` **300s**（5 分钟）。可在控制台按模型微调或设为 `pinned`。 |
| **内存压力 `WARN`** | 立即卸载所有 `priority != interactive` 的空闲 Worker；向仍在运行或保活的 Worker 发送 `{"cmd":"trim_cache"}`。 |
| **内存压力 `CRITICAL`** | 立即卸载**全部**空闲 Worker（包含交互模型），暂停一切 `batch` 新任务冷启动。 |
| **系统休眠 / 锁屏** | 卸载全部非 `pinned` 空闲 Worker，防止唤醒后内存抢占卡顿。 |
| **机身热状态 `SERIOUS`/`CRITICAL`** | 向 `batch` 任务插入动态冷却间隔（例如每句/每窗间隔 300–800ms），不限速 `interactive` 短请求。 |

---

## 3. 硬件自动分档推荐

首次启动与控制台模型页根据当前机器参数给出推荐组合（用户始终拥有最终选择权）：

- **Apple Silicon 8GB**：仅允许单模型互斥加载；默认推荐 `qwen3-asr-0.6b` + `yanmo-correct-4b-cot (4bit)`（轮替加载），提示大概率无法热驻留双模型。
- **Apple Silicon 16GB**：默认推荐 `qwen3-asr-0.6b` + `yanmo-correct-4b-cot (4bit)` **双热驻留**（合计约 3.8–4.2 GB）；TTS 推荐 `qwen3-tts-0.6b` 且跑批按需加载/快退。
- **Apple Silicon 24GB+**：默认推荐 `qwen3-asr-1.7b`（或 `0.6b`）+ `yanmo-correct-4b-cot (4bit/8bit)` + `qwen3-tts-1.7b` 无缝并存。
- **Windows CUDA 8GB VRAM**：推荐 `qwen3-asr-0.6b` + `yanmo-correct-4b-cot (q4_k_m)` 按任务/互斥切换；**12GB+ VRAM**：可稳态并发/热驻留。

---

## 4. 诊断存储与隐私铁律（`diagnostics.db`）

延续 Android `acpm` `SpeechFailures` 经过验证的极简可观测策略：

- **只存元数据，绝不存用户内容**：
  - 允许持久化：`timestamp_ms`、`request_id`、`caller`、`model_id`、`variant_id`、`operation`、`stage`、`code`、`detail`、`native_code`、`elapsed_ms`、`worker_pid`、`memory_snapshot_mb`。
  - **严禁落盘**：原始录音路径以外的音频内容、识别转写文本、4B 纠错输入与输出文本、TTS 合成台词文本、Prompt 上下文。
- SQLite 循环保留最近 **100** 条故障记录，API `/v1/system/failures` 与控制台概览默认展示最近 **20** 条，便于用户输入法或工作流出错时按 `request_id` 精确排障。
