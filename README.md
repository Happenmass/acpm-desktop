# acpm-desktop

`acpm-desktop` 是面向桌面端的本地 AI 模型统一管理与推理调度后端（`acpm` Android AI SDK 的桌面端姊妹项目），首发针对 **macOS 15+ Apple Silicon（MLX）**，并在核心调度与协议层原生预留 **Windows x64 + CUDA** 跨平台扩展。

它把本地 **4B CoT 后纠错 LLM**、**Qwen3-ASR（0.6B / 1.7B）**、**Qwen3-TTS（支持参考音频音色克隆）** 以及 **Pyannote 3.0 VAD + ERes2NetV2 说话人分离（`sherpa-onnx`）** 统一纳管在进程隔离的运行时之后，向「言墨输入法」、视频制作工作流及任意 Agent 提供标准、高并发抢占安全、可观测的本地接口。

## 架构总览

```text
┌──────────────────────────────────────────────────────────────────────┐
│  Native UI Shell (极薄菜单栏 / 托盘 + 运行控制台，仅消费 HTTP + SSE)   │
│   • macOS 15+: SwiftUI MenuBarExtra + Console (SMAppService 自启)     │
│   • Windows (预留): WinUI 3 / 托盘 + Console                          │
└───────────────────────────────┬──────────────────────────────────────┘
                                │ UDS / Named Pipe / 127.0.0.1 HTTP+SSE
┌───────────────────────────────▼──────────────────────────────────────┐
│  acpmd (Rust 跨平台控制面内核，双端复用)                                │
│   • OpenAI 兼容网关 & 流式 <think>...</think> CoT 拆分器              │
│   • 多资源池预算调度 (Unified / SystemRam + GpuVram) & 优先级抢占       │
│   • 逻辑 Model Registry（平台变体路由、断点续传、SHA-256 校验）          │
│   • 脱敏诊断记录 (diagnostics.db) & PAL 平台抽象层                    │
└───────────┬──────────────────────────┬───────────────────────────────┘
            │ 私有 IPC + ACPM_FRAME\t   │
┌───────────▼──────────────────┐  ┌────▼───────────────────────────────┐
│  macOS Workers               │  │  Cross-Platform / Future Workers   │
│  • acpm-worker-mlx (Swift)   │  │  • acpm-worker-speech (sherpa-onnx)│
│    单多模式二进制: llm|asr|tts│  │  • acpm-worker-cuda-* (Windows)    │
└──────────────────────────────┘  └────────────────────────────────────┘
```

## 纳管模型与能力矩阵

| 逻辑模型 ID | 能力 | macOS 15+ 引擎 | Windows 引擎（预留） | 计算槽 | 核心特性 |
| --- | --- | --- | --- | --- | --- |
| `yanmo-correct-4b-cot` | `llm` | `mlx-swift` (`MLXLLM`, 4/8-bit) | `cuda-llamacpp` (`q4_k_m`) | `Gpu` | 流式 `<think>` 拆分、System Prompt 前缀 KV 缓存 |
| `qwen3-asr-0.6b` / `1.7b` | `asr` | `mlx-swift` (`MLXAudioSTT`) | `cuda-qwen-asr` | `Gpu` | 支持 `file_path` 零拷贝、分窗、`vad_filter` |
| `qwen3-tts-0.6b` / `1.7b` | `tts` | `mlx-swift` (`MLXAudioTTS`) | `cuda-qwen-tts` | `Gpu` | 参考音频音色克隆（自动特征缓存）+ 音色库 + 批量 |
| `speech-vad-pyannote` | `vad` | `sherpa-onnx` (CPU) | `sherpa-onnx` (CPU) | `Cpu` | Pyannote 3.0 ONNX，复用移动端 `speakers.json` 权重 |
| `speech-speaker-eres2net` | `diarization` | `sherpa-onnx` (CPU) | `sherpa-onnx` (CPU) | `Cpu` | ERes2NetV2 说话人分离与聚类 |

## 目录结构

```text
acpm-desktop/
├─ docs/spec/                  # 正式架构、API、Worker 协议、调度、UI 与 OpenAPI 规范
├─ manifests/                  # 模型清单示例 (registry.example.json)
├─ core/                       # Rust 跨平台工作空间
│  ├─ protocol/                # acpm-protocol: API DTO、错误码、资源向量、Worker 帧
│  ├─ pal/                     # acpm-pal: macOS / Windows 平台抽象层 Trait
│  ├─ scheduler/               # acpm-scheduler: 多池准入驱逐算法 + 流式 CoT 拆分器
│  ├─ registry/                # acpm-registry: 逻辑模型变体路由与硬件自动分档
│  ├─ daemon/                  # acpmd: 跨平台控制面主程序入口与发现文件写入
│  └─ worker-speech/           # acpm-worker-speech: 跨平台 sherpa-onnx Worker 骨架
├─ workers/
│  ├─ macos-mlx/               # Swift Package: WorkerCore + EngineLLM/ASR/TTS + acpm-worker-mlx
│  └─ windows-cuda/            # Windows + CUDA Worker 预留说明
├─ apps/
│  ├─ macos-console/           # SwiftUI 菜单栏 + 4-Tab 运行控制台 App 骨架
│  └─ windows-console/         # Windows 托盘与控制台预留说明
└─ clients/
   ├─ swift/                   # 零依赖 Swift Client SDK (AcpmClient，供言墨输入法直连)
   └─ python/                  # 零依赖 Python Stdlib Client (供视频工作流与 Agent 调用)
```

## 规范文档导航

- [01-architecture.md](docs/spec/01-architecture.md) — 系统总体架构、跨平台 PAL 与多资源池优先级抢占模型
- [02-external-api.md](docs/spec/02-external-api.md) — 对外统一标准接口、发现机制、结构化错误与双模音色克隆
- [03-worker-protocol.md](docs/spec/03-worker-protocol.md) — 跨平台 Worker 进程协议、生命周期状态机与缓存不变量
- [04-model-registry-and-scheduling.md](docs/spec/04-model-registry-and-scheduling.md) — 模型清单、原子下载、LRU 驱逐算法与脱敏诊断存储
- [05-console-ui-and-distribution.md](docs/spec/05-console-ui-and-distribution.md) — 菜单栏控制台 UI、签名公证与 Phase 0 基准验收计划
- [openapi.yaml](docs/spec/openapi.yaml) — OpenAPI 3.1.0 接口契约

## 前置环境与构建说明

- **Rust 控制面（`core/`）**：建议安装 `rustup`（Rust 1.82+，Edition 2021）。安装后可执行：
  ```sh
  cargo test --manifest-path core/Cargo.toml --workspace
  ```
- **macOS 15+ 原生 Worker 与客户端**：需要 Apple Silicon + macOS 15.0+（Swift 6.0+）；在 Phase 0 接入 `mlx-swift` 编译 Metal 着色器（`mlx.metallib`）时需要完整 **Xcode 16+**（确保 `xcode-select` 指向 Xcode 而非仅 CommandLineTools）。
  ```sh
  swift test --package-path clients/swift
  swift test --package-path workers/macos-mlx
  python3 -m unittest discover -s clients/python/tests
  ```

## 演进路线

- **Phase 0**：使用真实 4B CoT MLX、Qwen3-ASR 0.6B/1.7B、Qwen3-TTS 权重完成 Swift MLX 精度对齐、KV 前缀缓存与 `ri_phys_footprint` 实测。
- **Phase 1**：`acpmd` + `acpm-worker-mlx`（`llm`/`asr`）+ UDS/HTTP 接入言墨输入法，验证延迟与空闲回收。
- **Phase 2**：接入 `tts`/`speech`、参考音频音色库与批量合成队列，压测 16GB 机型下的句子级抢占让路。
- **Phase 3**：完善菜单栏与 Console 4-Tab UI、`SMAppService` 开机自启、断点下载与公证分发。

## 开源协议

Apache-2.0，详见 [LICENSE](LICENSE) 与 [NOTICE](NOTICE)。
