# 03 — 跨平台 Worker 进程协议与生命周期规范

`acpmd` 通过完全一致的 CLI 参数、`stdout/stdin` 控制通道和私有本地 HTTP 数据通道托管所有异构 Worker（macOS Swift MLX、跨平台 `sherpa-onnx`、未来 Windows CUDA）。Worker 必须保持**极薄且无状态（除进程内受控缓存外）**。

---

## 1. 进程启动契约（CLI 与环境隔离）

`acpmd` 启动任一 Worker 时使用统一 CLI 参数格式：

```sh
<worker-binary> \
  --mode <llm|asr|tts|speech> \
  --model-id <logical_model_id> \
  --model-dir <resolved_variant_dir> \
  --ipc-path <uds_path_or_loopback_bind> \
  --auth-token-env ACPM_WORKER_TOKEN \
  --memory-limit-mb <soft_limit_mb> \
  --threads <cpu_threads>
```

- **Auth Token 传递**：通过环境变量 `ACPM_WORKER_TOKEN` 传入随机 256-bit hex 秘钥（严禁放到命令行参数中，防止 `ps` 暴露）。
- **工作隔离**：
  - macOS：Worker 放入独立 Process Group；模型目录只读打开；Worker 绝不读取 `acpmd` 的用户配置文件或历史数据库。
  - Windows：Worker 挂入 `acpmd` 创建的 Job Object（`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`）。

---

## 2. 生命周期状态机

```text
               spawn
  STOPPED ──────────────► STARTING
                             │ (打开私有 IPC、发启动帧)
                             ▼
                          LOADING ◄─── (加载权重到 Metal/CUDA/CPU)
                             │
             ┌───────────────┴───────────────┐
             │ 加载成功                       │ 超时/OOM/校验失败
             ▼                               ▼
            WARM ◄──────► RUNNING          FAILED ──► (discard & clean exit)
             │            (请求执行中)
             │ (idle TTL / 驱逐 / 显式 unload)
             ▼
         UNLOADING ──► STOPPED (进程退出, OS 回收 100% 物理内存与显存)
```

- **失败即丢弃原则（借鉴 Android `HtpAsr.kt`）**：任何处于 `RUNNING` 或 `LOADING` 状态的 Worker 发生通道中断、内部 Panic、推理超时或未捕获异常时，`acpmd` 立即将其标记为失效并强制终止进程，绝不复用可能处于脏状态的管道或 Metal/CUDA 上下文；下次请求将拉起全新 Worker 进程。

---

## 3. 控制通道协议（`stdout` 帧 + `stdin` 指令）

### 3.1 `stdout` 单行状态帧

Worker 仅将结构化生命周期帧输出到 `stdout`，每行必须以固定前缀 `ACPM_FRAME\t` 开头，后接单行 JSON：

```text
ACPM_FRAME\t{"type":"state","state":"LOADING","ts_ms":1763872800100}
ACPM_FRAME\t{"type":"state","state":"WARM","model_load_ms":742.5,"memory":{"unified_mb":2840}}
ACPM_FRAME\t{"type":"metric","memory":{"unified_mb":2910},"kv_cache_entries":1,"voice_cache_entries":0}
ACPM_FRAME\t{"type":"error","stage":"MODEL_LOAD","detail":"SAFETENSORS_CORRUPTED","native_code":"mlx:2","fatal":true}
```

- 第三方底层库（如 `onnxruntime`、`llama.cpp`、`mlx`）偶尔向 `stdout`/`stderr` 打印的非 `ACPM_FRAME\t` 日志行，`acpmd` 一律按普通调试日志透传到日志环，不视为协议错误。

### 3.2 `stdin` 控制指令与父进程死亡防孤儿

- `acpmd` 向 Worker `stdin` 发送单行 JSON 指令：
  - `{"cmd":"shutdown"}`：优雅退出，停止接收新请求，清理资源并在退出码 `0` 终止。
  - `{"cmd":"trim_cache"}`：内存压力 `WARN` 时触发，释放非必要缓存（如清空 `MLX.GPU.clearCache()` 或驱逐非固定 KV/音色缓存）而不杀死进程。
- **EOF 自杀不变式**：Worker 启动后台线程持续读取 `stdin`；一旦检测到 `EOF`（意味着 `acpmd` 已崩溃或管道断开），Worker 必须在 **500ms 内自行退出**，防止残留 GB 级孤儿进程占满内存/显存。

---

## 4. 私有数据通道接口（Worker 内部 HTTP）

Worker 在 `--ipc-path`（macOS 为私有 UDS `worker-<model>-<pid>.sock`；Windows 为绑定 `127.0.0.1:<ephemeral_port>` 并在 `STARTING -> WARM` 帧中回传端口）暴露极简内部 HTTP 服务，所有请求必须校验 `X-Worker-Token`：

| 路径 | 方法 | 说明 |
| --- | --- | --- |
| `/health` | `GET` | 返回当前 `state`、已加载模式、缓存条目统计 |
| `/infer/chat` | `POST` | 流式（NDJSON / SSE）或一次性返回**原始文本 tokens**（含 `<think>` 标签原样输出）与耗时统计 |
| `/infer/asr` | `POST` | 接受 WAV/音频文件路径、语言、上下文提示词，返回分段与耗时 |
| `/infer/tts` | `POST` | 接受单句文本、音色参数（内置名或 `reference_audio` + `reference_text`）、输出 WAV 路径 |
| `/infer/vad` | `POST` | （仅 `speech` 模式）返回语音区间 `[start_ms, end_ms]` |
| `/infer/diarize` | `POST` | （仅 `speech` 模式）返回说话人分段与警告 |
| `/cache/clear` | `POST` | 清空进程内前缀 KV 缓存或音色克隆特征缓存 |
| `/shutdown` | `POST` | 备选优雅关停端点 |

---

## 5. 请求取消与各引擎实现不变量

### 5.1 取消传播

当外部调用方断开 HTTP 连接或调用批量取消时，`acpmd` 立即中断发往 Worker 的内部请求。Worker 收到连接关闭/取消信号后：
- 若可在当前 token / 推理步安全中断，立刻停止循环释放计算槽并返回取消帧；
- 若 3 秒内未退出 `RUNNING` 回到 `WARM`，`acpmd` 判定为不可协作阻塞（常见于单次长推理 kernel），先发送强杀，再在下一次调度时重建干净 Worker。

### 5.2 各模式专属不变量

1. **`llm` Worker（4B CoT）**：
   - **禁止解析 `<think>`**：原样吐出 tokens，由 `acpmd` 统一执行流式拆分，确保 Mac MLX 与未来 Windows CUDA 行为 100% 一致。
   - **前缀 KV Cache（LRU）**：内部维护小容量（默认最多 4 组，受 `--memory-limit-mb` 约束）的 `prompt_cache_key -> (prefix_tokens, kv_cache_snapshot)` 映射。当请求带有相同 `prompt_cache_key` 且提示词前缀完全一致时，直接复用快照跳过 System Prompt Prefill。
2. **`asr` Worker（Qwen3-ASR 0.6B / 1.7B）**：
   - **仅处理分段或已切窗音频**：长音频超过单窗上限时，由 `acpmd` 先配合 `speech` VAD 切分为 ≤ 24–30s 片段后再逐窗送入 ASR Worker，既防长上下文爆内存，又天然制造了 `interactive` 抢占点。
3. **`tts` Worker（Qwen3-TTS）**：
   - **单句粒度和单次调用**：每次 `/infer/tts` 仅合成单句或单段可控文本；多句剧本由调用方或 `acpmd` 批处理引擎循环驱动。
   - **参考音色特征缓存**：按 `sha256(ref_audio_bytes + "\0" + ref_text + "\0" + x_vector_only)` 维护进程内 LRU（默认最多缓存 8 个音色），缓存提取后的声学/Speaker Embedding 张量，单句合成免重复读盘和编码参考音频。
4. **`speech` Worker（`sherpa-onnx` VAD + Diarization）**：
   - 严格使用 CPU 推理并受 `--threads` 限制，绝不申请 Metal 或 CUDA 上下文，使音频预处理与 LLM/TTS 可安全并发。
