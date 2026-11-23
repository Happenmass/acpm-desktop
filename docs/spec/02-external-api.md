# 02 — 对外统一标准接口规范

`acpm-desktop` 对外提供 **OpenAI 兼容 REST/SSE** 与 **语音/音色/可观测扩展端点**。所有接口均不绑定具体业务形态，言墨输入法（Swift）、视频工作流（Python）及第三方 Agent 均按本规范接入。完整机器可读 Schema 见 [openapi.yaml](openapi.yaml)。

---

## 1. 传输通道、服务发现与安全边界

### 1.1 服务发现文件 `runtime.json`

`acpmd` 启动并绑定监听后，以 `0600` 权限通过「写临时文件 + 原子重命名」更新 `runtime.json`。客户端发现流程：
1. 读取 `<AppData>/acpm-desktop/runtime.json`。
2. 校验 `pid` 存活（macOS 可进一步检测 `native_ipc_path` 是否可连通；若 `pid` 失效则清理脏文件或拉起 `AcpmRuntime.app` / `acpmd`）。
3. 优先通过 `native_ipc_path`（同签名应用免 Token 或带签发 Token），本机或局域网跨设备调用方通过 `http_base_url` / `mdns_base_url`（默认 `http://acpm.local:18790`）+ `Authorization: Bearer <token>` 访问。

```json
{
  "version": 1,
  "pid": 42190,
  "started_at": "2026-11-23T12:40:00Z",
  "http_base_url": "http://127.0.0.1:18790",
  "native_ipc_path": "/Users/alice/Library/Application Support/acpm-desktop/daemon.sock",
  "token": "acpm_local_9d8f2e1c4a6b...",
  "platform": "darwin-arm64",
  "capabilities": ["llm", "asr", "tts", "vad", "diarization"],
  "mdns_hostname": "acpm.local",
  "mdns_base_url": "http://acpm.local:18790"
}
```

### 1.2 安全策略与 mDNS 固定域名广播

- **mDNS 局域网固定域名广播（跨设备接入）**：
  - 默认开启 mDNS 广播（可通过 `--no-mdns` 关闭为纯本机 `127.0.0.1`），默认广播固定域名 **`acpm.local`**（可通过 `--mdns-host` 自定义）及 Bonjour 服务 **`_acpm._tcp.local.`**（TXT 记录包含 `version=1`、`host=acpm.local`、`port=18790`、`capabilities=llm,asr,tts`），监听网卡 IP 变化时自动刷新。
  - 跨设备调用方固定通过 `http://acpm.local:18790/v1/...` 访问，不依赖变化的局域网 DHCP IP。
  - 默认持久化 Bearer Token 至 `<AppData>/acpm-desktop/auth_token`（`0600` 权限，亦可通过 `--token` 显式指定），重启后无需在局域网设备重新配对。
- **HTTP (`127.0.0.1:<port>` / `0.0.0.0:<port>`)**：
  - 除 `GET /healthz` 外，所有端点强制要求 `Authorization: Bearer <token>`。
  - **Host 白名单校验**：允许 `127.0.0.1:<port>`、`localhost:<port>`、`[::1]:<port>`、已配置的 mDNS 固定域名（如 `acpm.local:<port>`）及当前活跃 LAN IPv4，拦截任意未知域名，防 DNS Rebinding 攻击。
  - **Origin 防护**：若请求携带非空 `Origin` 头（典型网页浏览器 CSRF 探测），直接返回 `403 FORBIDDEN`。
- **Native IPC（macOS UDS / Windows Named Pipe）**：
  - macOS 通过 `LOCAL_PEERTOKEN` 验证调用进程 Team ID 与宿主一致或位于控制台授权白名单内；Windows 通过当前用户 SID DACL 与 Authenticode 校验。

---

## 2. 通用请求头与结构化错误模型

### 2.1 通用请求头

| Header | 必填 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `X-AI-Priority` | 否 | `normal` | 调度优先级：`interactive`（P0，言墨输入法实时交互）/ `normal`（P1）/ `batch`（P2，后台长音频或批量配音） |
| `X-AI-Caller` | 否 | `unknown` | 调用方标识（如 `yanmo-ime`、`video-agent`），仅用于控制台计数与脱敏故障归因，限制 `[A-Za-z0-9_.-]{1,64}` |
| `X-AI-Request-Id` | 否 | 服务端生成 UUID v4 | 全链路追踪 ID，响应头 `X-AI-Request-Id` 原样回传 |

### 2.2 统一结构化错误格式（对齐 Android `acpm`）

所有非 `2xx` 响应返回如下 JSON（SSE 流中断前亦尽量推送 `event: error` 同构负载）：

```json
{
  "error": {
    "code": "MODEL_NOT_INSTALLED",
    "message": "Model 'yanmo-correct-4b-cot' is not installed locally.",
    "request_id": "550e8400-e29b-41d4-a716-446655440000",
    "stage": "MODEL_PREPARE",
    "detail": "MISSING_WEIGHT_FILES",
    "native_code": null,
    "elapsed_ms": 14,
    "retryable": false
  }
}
```

**标准错误码 `code` 与阶段 `stage`**：
- `code`：`INVALID_REQUEST` (400)、`UNAUTHORIZED` (401)、`FORBIDDEN` (403)、`NOT_FOUND` (404)、`AUDIO_VALIDATION_FAILED` (400)、`MODEL_NOT_INSTALLED` (404/424)、`UNSUPPORTED_PLATFORM` (422)、`INSUFFICIENT_MEMORY` (507)、`SCHEDULER_BUSY` (503)、`QUEUE_TIMEOUT` (504)、`WORKER_CRASHED` (502)、`INFERENCE_FAILED` (500)、`CANCELLED` (499/408)、`NOT_IMPLEMENTED` (501)。
- `stage`：`HTTP_ADMISSION`、`AUDIO_VALIDATION`、`MODEL_PREPARE`、`SCHEDULER_QUEUE`、`WORKER_START`、`WORKER_IO`、`MODEL_LOAD`、`INFERENCE`、`RESULT_VALIDATION`。

---

## 3. 推理端点规范

### 3.1 4B CoT 后纠错 LLM：`POST /v1/chat/completions`

完全兼容 OpenAI Chat Completions，增加两个针对局部优化 CoT 模型的扩展参数：

- **请求新增字段**：
  - `separate_reasoning`（boolean，默认 `true`）：由 `acpmd` 的 `CotStreamSplitter` 自动识别 `<think>...</think>`，将思考过程填入 `reasoning_content`，将干净的最终纠错结果填入 `content`；设为 `false` 时透传原始模型输出。
  - `prompt_cache_key`（string，可选）：固定前缀缓存标识（例如 `"yanmo-correct-v1"`）。Worker 命中对应前缀 `KVCache` 后跳过 System Prompt Prefill。

**请求示例**：
```json
{
  "model": "yanmo-correct-4b-cot",
  "stream": true,
  "temperature": 0.0,
  "max_tokens": 512,
  "separate_reasoning": true,
  "prompt_cache_key": "yanmo-correct-sys-v1",
  "messages": [
    { "role": "system", "content": "你是语音识别后纠错助手，请修正错别字与标点并只输出修正文本。" },
    { "role": "user", "content": "明天去北静出差定一张机票" }
  ]
}
```

**非流式响应片段**：
```json
{
  "id": "chatcmpl-9b3a...",
  "object": "chat.completion",
  "created": 1763872800,
  "model": "yanmo-correct-4b-cot",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "reasoning_content": "“北静”结合“出差”“机票”语境应为“北京”。",
        "content": "明天去北京出差，订一张机票。"
      },
      "finish_reason": "stop"
    }
  ],
  "usage": { "prompt_tokens": 68, "completion_tokens": 34, "total_tokens": 102 },
  "x_acpm_timing": {
    "queue_ms": 0.4,
    "model_load_ms": 0.0,
    "prefill_ms": 18.2,
    "decode_ms": 145.0,
    "kv_cache_hit": true
  }
}
```

**SSE 流式 Chunk 示例**：`delta` 中先吐 `{"reasoning_content": "..."}`，闭合 `</think>` 后吐 `{"content": "..."}`，最后以 `[DONE]` 结束。

---

### 3.2 ASR 语音识别：`POST /v1/audio/transcriptions`

支持两种方式提交音频（均支持 16kHz 单声道 PCM16 WAV 及常见容器；Worker 或入口负责安全解码与重采样）：
1. **标准 `multipart/form-data`**：OpenAI SDK 零改动可用（`file`, `model`, `language`, `prompt`, `response_format`）。
2. **`application/json` 零拷贝路径模式**（推荐本地 Agent 与输入法使用）：
   ```json
   {
     "model": "qwen3-asr-0.6b",
     "file_path": "/tmp/yanmo-utterance-123.wav",
     "language": "auto",
     "vad_filter": true,
     "timestamps": true,
     "prompt": "言墨输入法 专业名词"
   }
   ```
- **响应格式**（`json` / `verbose_json`）：
  ```json
  {
    "text": "明天去北静出差定一张机票",
    "language": "zh",
    "duration_ms": 2840,
    "segments": [
      { "start_ms": 120, "end_ms": 2710, "text": "明天去北静出差定一张机票" }
    ],
    "x_acpm_timing": { "queue_ms": 0.2, "model_load_ms": 0.0, "decode_ms": 195.4 }
  }
  ```

---

### 3.3 TTS 语音合成与参考音频克隆：`POST /v1/audio/speech`

兼容 OpenAI `/v1/audio/speech`，并原生扩展 **Qwen3-TTS 音色克隆与磁盘直写**：

```json
{
  "model": "qwen3-tts-1.7b",
  "input": "欢迎来到本期视频，今天我们来聊聊端侧推理架构。",
  "voice": "voice_narrator_01",
  "instruct": "语速适中，沉稳清晰，带有一点讲述感",
  "reference_audio": "/Users/alice/clips/narrator_5s.wav",
  "reference_text": "大家好，这是一段用于音色克隆的参考录音。",
  "x_vector_only_mode": false,
  "speed": 1.0,
  "response_format": "wav",
  "output_path": "/Users/alice/video_proj/audio/line_001.wav"
}
```

- **音色解析优先级**：
  1. 若传入 `reference_audio`（本地文件路径，或通过 `multipart/form-data` 上传）：本次直接用于克隆；TTS Worker 以 `sha256(model + ref_audio_bytes + reference_text + x_vector_only_mode)` 为键**在内存缓存已提取的声学 Prompt 特征**，后续循环请求无需重算参考音频编码。
  2. 否则若 `voice` 匹配 `/v1/audio/voices` 中已注册的 `voice_id`，`acpmd` 自动解析其关联 `ref.wav` 与 `ref_text`。
  3. 否则将 `voice` 作为模型内置说话人名（如 `"Vivian"`、`"Serena"`）透传。
- **返回形式**：
  - 未传 `output_path`：直接返回 `audio/wav`（或 `pcm`）二进制流，响应头带 `X-AI-Audio-Duration-Ms` 与 `X-AI-Timing-Decode-Ms`。
  - 传入 `output_path`：`acpmd` 校验路径可写并原子落盘，返回 `application/json` 元数据：
    `{"output_path": "...", "bytes": 240044, "sample_rate": 24000, "duration_ms": 5000, "voice_cache_hit": true, "x_acpm_timing": {...}}`。

---

### 3.4 命名参考音色库：`/v1/audio/voices`

供视频制作工作流和控制台管理持久化克隆音色：
- `POST /v1/audio/voices`（`multipart/form-data` 或 JSON `reference_audio` 路径）：传入 `name`、`reference_audio`、`reference_text`（可选）、`language`（可选）、`notes`，返回 `{"voice_id": "voice_8f31a...", "name": "...", "duration_ms": 5200, "sha256": "...", "created_at": "..."}`。
- `GET /v1/audio/voices`：列出所有已注册音色。
- `GET /v1/audio/voices/{voice_id}` / `GET /v1/audio/voices/{voice_id}/sample`：获取元信息或试听参考音频。
- `DELETE /v1/audio/voices/{voice_id}`：删除音色及相关引用缓存。

---

### 3.5 通用批量 TTS 作业（Phase 2 可选编排）：`/v1/audio/speech/batches`

供希望将几十/上百句配音进度在菜单栏统一展示与控制的调用方使用（调度层依然按单句释放 GPU 槽以保证言墨输入法抢占）：
- `POST /v1/audio/speech/batches`：提交 `model`、`voice`/`reference_audio`、`reference_text`、`output_dir` 与 `items: [{id, text, output_file, instruct?}]`，返回 `batch_id`。
- `GET /v1/audio/speech/batches/{id}` & `GET /v1/audio/speech/batches/{id}/events`（SSE）：查询或订阅逐句完成状态（`completed / total`、失败项及原因）。
- `POST /v1/audio/speech/batches/{id}/pause | resume | cancel`。

---

### 3.6 VAD 与说话人分离（对齐 Android `acpm`）

- `POST /v1/audio/vad`：接受 `file_path` 或 multipart 音频，可选 `model`（默认 `speech-vad-pyannote`）、`min_speech_ms`、`min_silence_ms`。
  返回：`{"segments": [{"start_ms": 340, "end_ms": 4820}], "duration_ms": 12000, "x_acpm_timing": {...}}`。
- `POST /v1/audio/diarization`：接受 `file_path` 或 multipart 音频，可选 `speaker_count`（`1..32`，缺省自动聚类）。
  返回语义与 Android `acpm` 的 `SpeechServiceClient.kt` 一致：
  `{"turns": [{"start_ms": 340, "end_ms": 4820, "speaker": 0}], "speaker_count": 2, "warning": null, "x_acpm_timing": {...}}`。

---

## 4. 模型与系统管理端点

- `GET /v1/models`：列出逻辑模型清单、本机适配的平台变体、安装状态、当前 Worker 状态（`STOPPED/LOADING/WARM/RUNNING/UNLOADING/FAILED`）、实时内存向量（`memory`）、空闲剩余秒数、配置默认值。
- `POST /v1/models/{id}/load`：主动加载并预热到 `WARM`。可选传 `{"quant": "4bit"}`。
- `POST /v1/models/{id}/unload`：优雅关闭对应 Worker，立即回收内存。
- `POST /v1/models/prewarm`：批量按顺序预热多个模型（如输入法唤醒时传 `{"models": ["qwen3-asr-0.6b", "yanmo-correct-4b-cot"], "prompt_cache_keys": ["yanmo-correct-sys-v1"]}`）。
- `POST /v1/models/{id}/download` / `DELETE /v1/models/{id}`：触发断点下载与 SHA-256 校验落盘，或删除本地权重。
- `GET /v1/system/status`：返回主机资源拓扑（`Unified` 或 `SystemRam + GpuVram`）、总预算与实时使用量、内存压力（`normal/warn/critical`）、热状态、活跃 Worker 列表、GPU/CPU 队列深度、按 `caller` 统计请求数。
- `GET /v1/system/events`（SSE）：实时推送 `model_state_changed`、`memory_snapshot`、`batch_progress`、`failure_recorded`，供菜单栏和控制台 UI 零轮询刷新。
- `GET /v1/system/failures`：返回最近 20 条**脱敏**推理故障记录（仅含 `request_id`、`caller`、`operation`、`stage`、`code`、`detail`、`native_code`、`elapsed_ms`、`timestamp`）。
- `POST /v1/system/unload-all`：立即卸载所有非 `pinned` 模型（支持传 `{"include_pinned": true}` 全部释放）。
