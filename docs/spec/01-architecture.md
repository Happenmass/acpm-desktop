# 01 — 系统总体架构与跨平台抽象规范

本文档定义 `acpm-desktop` 的三层架构、跨平台抽象边界（PAL）、多资源池调度模型与应用程序打包布局。目标是让 **macOS 15+ Apple Silicon（MLX）** 与未来 **Windows x64 + CUDA** 共用同一套控制面语义、调度算法和外部 API 契约。

---

## 1. 核心设计原则

1. **零业务耦合（Zero Business Coupling）**：后端只负责模型托管、资源调度与标准推理原语，不感知「言墨输入法」「视频剪辑」等业务概念，面向通用调用方与 Agent 编排。
2. **零 Python 终端分发（Zero-Python End-User Packaging）**：macOS 端推理全部基于 `mlx-swift`、`mlx-swift-lm`、`mlx-audio-swift` 与 `sherpa-onnx` 原生编译；避免向终端 `.app` 内嵌庞大的 Python 环境及签名公证复杂度。
3. **进程级内存隔离（Process-Level Isolation）**：每个活跃模型运行在独立 OS 子进程中。空闲超时或被驱逐时**直接退出 Worker 进程**，由操作系统内核 100% 回收 Metal Buffer Pool / CUDA Context / 堆碎片。
4. **控制面跨平台复用（Single Rust Control Plane）**：路由、流式 `<think>` CoT 拆分、优先级抢占、多资源池预算、批量作业与脱敏诊断全部收敛在 Rust `acpmd`，不同平台仅实现极薄 Worker 与原生 UI 壳。

---

## 2. 三层解耦架构

```text
┌──────────────────────────────────────────────────────────────────────┐
│  Layer 1: Native UI Shell（极薄原生外壳，仅消费 HTTP + SSE）           │
│   • macOS 15+: SwiftUI MenuBarExtra + Console Window (AcpmRuntime)   │
│   • Windows (未来): WinUI 3 / System Tray + Console Window           │
└───────────────────────────────┬──────────────────────────────────────┘
                                │ UDS / Named Pipe / 127.0.0.1 HTTP+SSE
┌───────────────────────────────▼──────────────────────────────────────┐
│  Layer 2: Cross-Platform Control Plane (acpmd, Rust)                 │
│   • API Gateway: OpenAI 兼容端点 + 语音/声纹/音色/系统管理端点         │
│   • CotStreamSplitter: 统一流式解析 <think>...</think>                │
│   • ResourceScheduler: 多资源池向量准入、LRU 驱逐、句子级抢占          │
│   • ModelRegistry: 逻辑模型 ID -> 平台变体解析、断点续传、SHA-256     │
│   • DiagnosticStore: 脱敏故障历史 (diagnostics.db)                   │
│   • PAL (Platform Abstraction Layer): 隔离 OS 遥测/进程/鉴权/电源事件  │
└───────────┬──────────────────────────┬───────────────────────────────┘
            │ 私有本地 IPC + stdout ACPM_FRAME\t + stdin 控制指令
┌───────────▼──────────────────┐  ┌────▼───────────────────────────────┐
│  Layer 3a: macOS Workers     │  │  Layer 3b: Shared / Windows Workers│
│   • acpm-worker-mlx (Swift)  │  │   • acpm-worker-speech (Rust/ONNX) │
│     单一可执行文件多模式复用: │  │     Pyannote VAD + ERes2NetV2      │
│     --mode llm | asr | tts   │  │   • acpm-worker-cuda-* (Windows)   │
└──────────────────────────────┘  └────────────────────────────────────┘
```

### 为什么不在单个 Worker 进程内 unload？
- 在 Apple Silicon 上，`MLX` 的 Metal 分配器会缓存大量临时张量缓冲区；在 CUDA 上，驱动上下文（`CUcontext`）即使释放权重张量仍常占用 300–700 MiB 显存。
- 通过 `acpmd` 管理独立子进程：每次只按模型粒度 spawn 对应 Worker；利用 SSD + `mmap` 特性，Apple Silicon 加载 4B 4-bit 权重通常在 0.5–1.5 秒级别，而进程退出后可确保内存与显存 **零残留归还**。

---

## 3. 多资源池与优先级抢占抽象

为了同时适应 **Apple Silicon 统一内存** 与 **Windows Host RAM + 独立 GPU VRAM（含多卡）**，`acpm-scheduler` 不使用单一 `memory_mb` 标量，而使用资源向量与计算槽抽象。

### 3.1 资源池与计算槽定义

- **内存池枚举 `MemoryPool`**：
  - `Unified`：macOS Apple Silicon 物理统一内存（CPU + Metal GPU 共享）。
  - `SystemRam`：Windows/Linux 主机系统内存。
  - `GpuVram(u32)`：Windows/Linux 第 `device_id` 块独立 GPU 显存。
- **计算槽枚举 `ComputeSlot`**：
  - `Gpu(u32)`：对应 GPU 计算槽（默认并发度 `1`，防止多模型同时抢占 GPU 带宽触发 Swap 或驱动调度抖动）。
  - `Cpu`：CPU 计算槽（默认并发度 `2`，供 `sherpa-onnx` VAD 与说话人分离并行执行，不阻塞 Metal/CUDA 推理）。

### 3.2 向量准入不变式

设系统配置的资源预算向量为 $B$，当前已加载活跃 Worker 实际占用（无实测值时回退估算值）之和为 $U$，待加载模型的预期资源需求向量为 $R$：

$$\forall p \in \text{pools}(R),\quad U[p] + R[p] \le B[p]$$

若任一池不满足，则进入驱逐规划（详情见 [04-model-registry-and-scheduling.md](04-model-registry-and-scheduling.md)）。

### 3.3 双优先级与句子级抢占路径

系统定义三档优先级：`interactive`（P0，如言墨输入法实时听写/后纠错）> `normal`（P1）> `batch`（P2，如视频工作流批量 TTS/长音频转写）。

- **批处理让路原则**：`batch` 类长任务必须以**单句（TTS）或单窗（ASR ≤ 24s）**为粒度向 `acpmd` 申请 `ComputeSlot::Gpu(0)`；任何长任务不得持锁超过单句/单窗时长。
- **场景走查**：
  1. **24GB+ Mac / 12GB+ VRAM**：ASR + 4B CoT + TTS 内存可全部共存，仅 GPU 槽互斥。当言墨输入法发出 `interactive` ASR 请求时，排在当前正在生成的 1 句 TTS 之后立即插队；该句完成（通常 < 2s）即刻执行输入法 ASR + 4B 纠错，随后自动继续下一句 TTS。
  2. **16GB Mac（或 8GB VRAM 显卡）**：ASR + 4B CoT + TTS 同时驻留可能超出安全预算。`interactive` 请求到来且需加载 ASR/LLM 时，调度器等待当前这 1 句 TTS 结束，随即向空闲状态的 TTS Worker 发送优雅退出以释放约 2–3 GB，立即腾出空间服务输入法；输入法闲置后或批处理队列恢复时再重新拉起 TTS Worker。

---

## 4. Platform Abstraction Layer (PAL) 契约

在 Rust crate `acpm-pal` 中定义 4 个平台抽象 Trait，编译期按 `#[cfg(target_os = "macos")]` 与 `#[cfg(target_os = "windows")]` 切换实现。

| PAL Trait | 核心职责 | macOS 15+ 实现要点 | Windows x64 + CUDA 实现要点（预留） |
| --- | --- | --- | --- |
| `SystemTelemetry` | 采集本机总量/可用量、进程真实内存/显存、系统内存压力与热状态 | `sysctl` 总内存 + `MTLDevice.recommendedMaxWorkingSetSize`；`proc_pid_rusage` 读取 `ri_phys_footprint`（防 `mmap` RSS 失真）；`DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`；`NSProcessInfo.thermalState` | `GlobalMemoryStatusEx` + `GetProcessMemoryInfo`；动态加载 `nvml.dll` 读取 `nvmlDeviceGetMemoryInfo`、进程级显存占用、GPU 温度与多卡列表 |
| `ProcessSupervisor` | 拉起、监控、优雅关闭、强杀及防止孤儿僵尸进程 | `posix_spawn` / `Command` 置独立 Process Group（`setpgid`）；优雅退出发 JSON/信号，超时 `SIGKILL` 整组 | 创建 **Win32 Job Object**（配置 `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`），主控崩溃退出时由内核连带清理全部 CUDA Worker 防止显存泄漏 |
| `LocalTransportAuth` | 原生高安全 IPC 通道建立与同签名/同用户调用方验证 | Unix Domain Socket（`0600`）+ `getsockopt(LOCAL_PEERTOKEN)` / `SecCodeCopyGuestWithAttributes` 校验与宿主同 Team ID 签名 | Named Pipe（`\\.\pipe\acpm-desktop-<sid>`，当前用户 SID DACL + `GetNamedPipeClientProcessId` + WinVerifyTrust Authenticode 校验） |
| `PowerObserver` | 监听休眠、锁屏、电源变化 | `NSWorkspace.willSleepNotification`、`screensDidSleepNotification` 触发非常驻模型释放 | `WM_POWERBROADCAST`（`PBT_APMSUSPEND` / 锁屏事件）触发非常驻模型释放 |

---

## 5. 目录与打包布局规范

### 5.1 运行时数据与发现目录（可自定义迁移大模型目录）

- **macOS**：`~/Library/Application Support/acpm-desktop/`
- **Windows**：`%LOCALAPPDATA%\acpm-desktop\`

标准子目录结构：
```text
<AppData>/acpm-desktop/
├─ runtime.json        # 0600 权限，原子替换，当前运行实例发现文件
├─ daemon.sock         # macOS 私有控制与调用 UDS (Windows 下使用 Named Pipe)
├─ config.json         # 内存预算档位、自定义模型路径、HTTP 端口、空闲超时覆盖
├─ diagnostics.db      # SQLite 脱敏故障与指标库（严禁记录音频/文本 PII）
├─ models/             # 默认逻辑模型落盘目录（按 <model_id>/<variant_key>/ 存放）
└─ voices/             # 已注册参考音色 WAV 与元数据 (<voice_id>/ref.wav + meta.json)
```

### 5.2 macOS `.app` 分发包布局

```text
AcpmRuntime.app/
└─ Contents/
   ├─ Info.plist                        # LSUIElement = YES (纯菜单栏图标 + 按需弹出控制台窗口)
   ├─ Resources/
   │  ├─ mlx.metallib                   # 由完整 Xcode 编译打包的 MLX Metal 着色器库
   │  └─ default-registry.json          # 随包内置逻辑模型基线清单
   ├─ Frameworks/
   │  └─ sherpa-onnx.framework          # (按需动态库或静态链接入 acpm-worker-speech)
   ├─ MacOS/
   │  └─ AcpmRuntime                    # SwiftUI 菜单栏 + 控制台宿主，负责拉起/保活 acpmd
   └─ Helpers/
      ├─ acpmd                          # Rust 控制面守护进程
      ├─ acpm-worker-mlx                # 单一 Swift 多模式可执行文件 (llm | asr | tts)
      └─ acpm-worker-speech             # Rust/C++ sherpa-onnx VAD + 说话人分离 Worker
```

说明：将 `llm` / `asr` / `tts` 编译进同一个 `acpm-worker-mlx` 可执行文件，使重型 `mlx-swift` 与 `mlx.metallib` 在安装包内只存一份，避免 3 倍包体膨胀；运行时由 `acpmd` 按 `--mode llm|asr|tts` 分别拉起独立子进程。
