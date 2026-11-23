# 05 — 菜单栏控制台 UI、分发封装与 Phase 0 验收计划

---

## 1. 菜单栏常驻 App 与运行控制台信息架构

`AcpmRuntime.app`（`LSUIElement = YES`，纯菜单栏应用，需要时点击打开控制台窗口，品牌名支持与 Android 端统一显示为 **AI SDK**）。UI 层完全无状态调度代码，只订阅 `acpmd` 的 `/v1/system/status`、`/v1/models`、`/v1/system/events`（SSE）和 `/v1/system/failures`。

### 1.1 菜单栏弹出面板（MenuBarExtra Popover）

以 5 秒内完成状态判断和内存释放为核心目标：
1. **顶部健康与内存总览**：`内存使用 4.2 / 16.0 GB` 进度条 + 系统内存压力指示灯（绿/黄/红）+ 热状态徽标。
2. **活跃模型胶囊列表**：每行展示逻辑模型名、状态徽章（`WARM` / `RUNNING` / `LOADING`）、真实物理占用 `phys_footprint`、空闲回收倒计时（如 `18m 20s`），右侧提供单个「卸载」按钮。
3. **后台作业摘要（有任务时显示）**：如 `TTS 批量合成 14/60`，提供暂停/取消快捷按钮。
4. **底部操作条**：「全部释放内存」「打开运行控制台」「退出运行时」。

### 1.2 独立运行控制台窗口（4 个 Tab）

| Tab | 对应 Android Console 灵感 | 核心展示与操作项 |
| --- | --- | --- |
| **概览 (Overview)** | `Overview` 内存曲线 + Failure History | 1. 全局及按 Worker 分色内存曲线（最近 5 分钟趋势）<br>2. GPU / CPU 队列等待数与硬件档位提示<br>3. 按调用方统计（`yanmo-ime` / `video-agent` 请求量与失败率）<br>4. 最近 20 条脱敏失败记录（可一键复制 `request_id` + `stage` + `detail`） |
| **模型 (Models)** | `Speech / Models` 面板 | 1. 全部逻辑模型卡片（4B CoT、Qwen3-ASR 0.6B/1.7B、Qwen3-TTS 0.6B/1.7B、Pyannote+ERes2Net）<br>2. 量化/变体选择、下载进度条（SHA-256 校验状态）、安装/删除<br>3. 手动「预热 / 卸载」、固定常驻开关（`Pin`）与空闲超时滑块 |
| **任务 (Jobs)** | `Agents / MCP` 活动视图 | 1. 实时活跃推理与排队请求（含 `X-AI-Priority` 与 `caller` 标签，直观看到 P0 抢占 P2）<br>2. 批量 TTS 作业列表（进度、暂停/恢复/取消、失败项重跑） |
| **音色与设置 (Voices & Settings)** | 运行配置中心 | 1. 参考音色库管理（新增试听/查看引用文字/删除 `voice_id`）<br>2. 内存预算档位（节能/均衡/性能）与模型存储目录迁移<br>3. `SMAppService.mainApp` 登录开机自启开关、HTTP 监听端口与 Bearer Token 复制、同签名/授权调用方管理 |

---

## 2. macOS 15+ 构建、签名与公证分发

1. **为什么必须用完整 Xcode 构建最终发布包**：
   - 仅 CommandLineTools 可以编译纯 Swift 逻辑，但 `mlx-swift` 依赖编译 Metal `.metal` 着色器为 `mlx.metallib`，必须通过完整 Xcode（`xcodebuild` + Metal toolchain）构建并打进 `Contents/Resources/`。
2. **权限与签名（Hardened Runtime）**：
   - `AcpmRuntime`、`acpmd`、`acpm-worker-mlx`、`acpm-worker-speech` 全部使用同一 Apple Developer ID Application 证书签名。
   - Worker 无需网络对外暴露权限，仅需最小 Entitlements；若采用 `com.apple.security.app-sandbox` 以外的独立分发（Direct Distribution / DMG），启用 Hardened Runtime 即可顺畅读取用户选择的音视频目录并监听 UDS/Loopback。
3. **开机自启**：
   - 通过 `SMAppService.mainApp.register()` 注册，可在系统设置「通用 → 登录项」中透明管理，无残留孤立 LaunchAgent plist。
4. **Windows 分发预览（未来）**：
   - Inno Setup / MSIX 打包 `AcpmRuntime.exe` + `acpmd.exe` + `acpm-worker-cuda-*.exe` + `acpm-worker-speech.exe`，使用 Authenticode 签名与 Windows 任务栏托盘自启。

---

## 3. Phase 0 真实权重验收计划（动工第一里程碑）

在接入 `acpmd` 全量调度前，用真实的 **4B CoT MLX 权重**、**Qwen3-ASR 0.6B/1.7B** 和 **Qwen3-TTS** 跑通 `workers/macos-mlx` 的原生 Swift 闭环，消除一切框架差异风险：

| 验证项 | 目标与通过标准 |
| --- | --- |
| **1. 4B CoT 精度与格式对齐** | 同一批测试语料（20 条典型听写易错句），对比 Python `mlx_lm` 与 Swift `MLXLLM`（4-bit / 8-bit）输出：greedy（`temperature=0`）下 token 一致率达到对齐要求，`<think>...</think>` 格式稳定闭合。 |
| **2. System Prompt KV 前缀缓存提速** | 固定 ~200–400 tokens 纠错 System Prompt，对比冷 prefill 与命中 `prompt_cache_key` 后的 TTFT：验证命中后 TTFT 显著降低（目标 < 60 ms，视机型而定），内存增长可控。 |
| **3. Qwen3-ASR 0.6B & 1.7B 对齐** | 复用移动端中英双语测试音频及真实长短语音，对比 Swift `MLXAudioSTT` 与 Python `mlx-audio` 的转写文本、时间戳及冷/热加载耗时。 |
| **4. Qwen3-TTS 参考音频克隆与 Cache** | 验证 5 秒参考音频 + `reference_text` 在 Swift `MLXAudioTTS` 下生成的 24kHz WAV 音质与一致性；验证同一音色连续合成 5 句时，第 2–5 句命中音色缓存后的编码时间接近 `0`。 |
| **5. 真实 `ri_phys_footprint` 基线采样** | 通过 `proc_pid_rusage` 记录上述各 Worker 在 `LOADING` / `WARM` / `RUNNING` 峰值下的实际物理内存占用，用于回填正式 `registry.json` 中的 `footprint.unified_mb`。 |
| **6. 进程退出回收实测** | 观测 `acpm-worker-mlx` 退出前后的系统活跃内存与 Metal 占用变化，确认退出 1 秒内 100% 回收。 |
