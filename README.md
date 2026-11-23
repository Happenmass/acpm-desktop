# acpm-desktop (`AcpmRuntime`)

`acpm-desktop` 是面向桌面端的本地 AI 模型统一管理与推理调度后端（`acpm` Android AI SDK 的桌面端姊妹项目），首发针对 **macOS 15+ Apple Silicon（MLX）**，并在核心调度与协议层原生预留 **Windows x64 + CUDA** 跨平台扩展。

它将本地 **Yanmo CoT 后纠错 LLM（4B / 9B）**、**Qwen3-ASR（0.6B / 1.7B）**、**Qwen3-TTS（支持参考音频音色克隆）** 以及内置 **Pyannote 3.0 CPU VAD（`sherpa-onnx`）** 统一纳管在进程隔离的运行时之后，向「言墨输入法」、视频制作工作流及任意跨设备客户端（通过固定域名 `http://acpm.local:18790`）提供标准、高并发抢占安全、可观测的本地接口。

## HuggingFace 公开模型权重（标准 Hub 自动发现与在线下载）

`AcpmRuntime` 支持直接从标准 HuggingFace Hub 缓存（`~/.cache/huggingface/hub/models--<org>--<repo>/snapshots/...`）自动发现并加载模型权重，也支持在控制台「模型」页直接在线断点下载与 SHA-256 校验：

| 逻辑模型 ID | 参数规模与量化 | 推荐主机内存 | 实测运行时占用 | HuggingFace 公开仓库 |
| --- | --- | --- | --- | --- |
| `yanmo-correct-4b-cot` | 4B · MLX 8-bit | 16 GB+ 统一内存 | ~4.8 GB | [Happenmasss/yanmo-correct-4b-cot-mlx-8bit](https://huggingface.co/Happenmasss/yanmo-correct-4b-cot-mlx-8bit) |
| `yanmo-correct-9b-cot` | 9B Distill · MLX 8-bit | 24 GB+ 统一内存 | ~9.5 GB | [Happenmasss/yanmo-correct-9b-cot-mlx-8bit](https://huggingface.co/Happenmasss/yanmo-correct-9b-cot-mlx-8bit) |

> 如果您通过 `hf download Happenmasss/yanmo-correct-4b-cot-mlx-8bit`（或 `huggingface_hub.snapshot_download`）拉取到默认 HuggingFace 缓存目录，启动 `AcpmRuntime.app` / `acpmd` 后无需额外配置路径即可自动识别就绪。

## 架构总览

```text
┌──────────────────────────────────────────────────────────────────────┐
│  AcpmRuntime Native App (macOS 15+ AppKit 菜单栏 + SwiftUI 控制台)   │
│   • 左键浮窗概览 / 右键 NSMenu 命令 · List+Inspector · 实时演练台     │
│   • 独立音色库 · 原生 Settings (⌘,) · SMAppService 开机自启           │
└───────────────────────────────┬──────────────────────────────────────┘
                                │ UDS / 127.0.0.1 / mDNS acpm.local HTTP+SSE
┌───────────────────────────────▼──────────────────────────────────────┐
│  acpmd (Rust 跨平台控制面内核)                                        │
│   • OpenAI 兼容网关 & 流式 <think>...</think> CoT 拆分器              │
│   • 统一内存预算调度 & Interactive 句级优先级抢占                     │
│   • 标准 HuggingFace Hub 缓存发现、断点续传、SHA-256 校验与内置 VAD   │
│   • 脱敏诊断记录 (diagnostics.db) & PAL 平台抽象层                    │
└───────────┬──────────────────────────┬───────────────────────────────┘
            │ 私有 IPC + ACPM_FRAME\t   │
┌───────────▼──────────────────┐  ┌────▼───────────────────────────────┐
│  macOS Workers               │  │  Cross-Platform / CPU Workers      │
│  • acpm-worker-mlx (Swift)   │  │  • acpm-worker-speech (sherpa-onnx)│
│    单多模式二进制: llm|asr|tts│  │    CPU Pyannote 3.0 VAD (随包内置) │
└──────────────────────────────┘  └────────────────────────────────────┘
```

## 纳管模型与能力矩阵

| 逻辑模型 ID | 能力 | macOS 15+ 引擎 | Windows 引擎（预留） | 核心特性 | 模型来源 |
| --- | --- | --- | --- | --- | --- |
| `yanmo-correct-4b-cot` | `llm` | `mlx-swift` (`MLXLLM`, 4/8-bit) | `cuda-llamacpp` (`q4_k_m`) | 流式 `<think>` 拆分、System Prompt 前缀 KV 缓存 | [HF 8-bit](https://huggingface.co/Happenmasss/yanmo-correct-4b-cot-mlx-8bit) |
| `yanmo-correct-9b-cot` | `llm` | `mlx-swift` (`MLXLLM`, 8-bit) | — | 高精度蒸馏纠错（24 GB+ 推荐）、流式 `<think>` 拆分 | [HF 8-bit](https://huggingface.co/Happenmasss/yanmo-correct-9b-cot-mlx-8bit) |
| `qwen3-asr-0.6b` / `1.7b` | `asr` | `mlx-swift` (`MLXAudioSTT`) | `cuda-qwen-asr` | `file_path` 零拷贝、`vad_filter` 长音频分窗 | MLX Community |
| `qwen3-tts-0.6b` / `1.7b` | `tts` | `mlx-swift` (`MLXAudioTTS`) | `cuda-qwen-tts` | 参考音频音色克隆、音色库持久化、可抢占批量合成 | MLX Community |
| `speech-vad-pyannote` | `vad` | `sherpa-onnx` (CPU) | `sherpa-onnx` (CPU) | Pyannote 3.0 ONNX（随 `AcpmRuntime.app` 内置开箱即用） | `sherpa-onnx` |

> 说明：面向输入法后端场景，当前仅启用 CPU VAD（说话人分离 `speech-speaker-eres2net` 暂缓接入，接口返回 `501 DIARIZATION_DEFERRED`）。

## 目录结构

```text
acpm-desktop/
├─ docs/
│  ├─ INTEGRATION.md           # 第三方软件 / 言墨输入法 HTTP/SSE/SDK 接入文档
│  └─ spec/                    # 正式架构、API、Worker 协议、调度、UI 与 OpenAPI 规范
├─ manifests/                  # 逻辑模型注册清单 (registry.example.json)
├─ core/                       # Rust 控制面工作空间 (protocol / pal / scheduler / registry / daemon / worker-speech)
├─ workers/
│  ├─ macos-mlx/               # Swift Package: EngineLLM/ASR/TTS + acpm-worker-mlx
│  └─ windows-cuda/            # Windows + CUDA Worker 预留说明
├─ apps/
│  ├─ macos-console/           # AcpmRuntime 菜单栏 + 运行控制台 App
│  └─ windows-console/         # Windows 托盘与控制台预留说明
├─ clients/
│  ├─ swift/                   # Swift Client SDK (AcpmClient)
│  └─ python/                  # 零依赖 Python Stdlib Client (acpm_client)
└─ scripts/                    # 图标生成与 AcpmRuntime.app / DMG 打包脚本
```

## 文档导航

- **[第三方接入指南 (INTEGRATION.md)](docs/INTEGRATION.md)** — 同机 `runtime.json` 发现、mDNS 跨设备、HTTP/SSE/Multipart 接口与 Swift / Python / TS 示例
- [01-architecture.md](docs/spec/01-architecture.md) — 系统总体架构与优先级抢占模型
- [02-external-api.md](docs/spec/02-external-api.md) — 对外统一标准接口、发现机制与结构化错误
- [03-worker-protocol.md](docs/spec/03-worker-protocol.md) — 跨平台 Worker 进程协议与状态机
- [04-model-registry-and-scheduling.md](docs/spec/04-model-registry-and-scheduling.md) — 模型清单、原子下载、LRU 驱逐与脱敏诊断
- [05-console-ui-and-distribution.md](docs/spec/05-console-ui-and-distribution.md) — 控制台 UI、签名公证与分发
- [openapi.yaml](docs/spec/openapi.yaml) — OpenAPI 3.1.0 接口契约

## 构建、测试与分发打包

- **运行全套单元测试**（Rust 控制面 + Swift Worker/SDK/Console + Python 客户端）：
  ```sh
  PATH="$HOME/.cargo/bin:$PATH" cargo test --manifest-path core/Cargo.toml --workspace
  swift test --package-path clients/swift
  swift test --package-path workers/macos-mlx --build-system native
  swift test --package-path apps/macos-console
  python3 -m unittest discover -s clients/python/tests
  ```
- **打包可分发的 `AcpmRuntime.app` 与 `AcpmRuntime-macos-arm64.dmg`**：
  ```sh
  ./scripts/package-macos-app.sh --dmg
  ```

## 开源协议

Apache-2.0，详见 [LICENSE](LICENSE) 与 [NOTICE](NOTICE)。
