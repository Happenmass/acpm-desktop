# AcpmRuntime 第三方软件接入文档

`AcpmRuntime` 是面向 Apple Silicon macOS 的本地多模态 AI 推理后端（LLM / ASR / TTS / CPU VAD），统一由守护进程 `acpmd` 调度并向本机软件与局域网设备提供标准化 HTTP / SSE / OpenAI 兼容接口。

---

## 1. 服务发现、连接方式与鉴权

### 1.1 同机接入（推荐，免配置固定地址与 Token）

任何运行在同一台 Mac 上的客户端（如输入法、桌面工具、自动化脚本），均可通过读取固定发现文件完成零配置鉴权：

- **发现文件路径**：
  `~/Library/Application Support/acpm-desktop/runtime.json`

```json
{
  "version": 1,
  "pid": 47228,
  "started_at": "2026-11-23T17:00:00Z",
  "http_base_url": "http://127.0.0.1:18790",
  "native_ipc_path": "/Users/<user>/Library/Application Support/acpm-desktop/acpmd.sock",
  "token": "5c2d9a...",
  "platform": "darwin-arm64",
  "capabilities": ["llm", "asr", "tts", "vad"],
  "mdns_hostname": "acpm.local",
  "mdns_base_url": "http://acpm.local:18790"
}
```

> **建议**：读取 `pid` 后先使用 `kill(pid, 0)` 验证进程存活，再使用 `http_base_url` 与 `token` 发起请求。

### 1.2 局域网跨设备接入（mDNS / Bonjour）

同一局域网下的手机、iPad、另一台 Mac 或开发机无需关心宿主 IP 变化，可直接通过固定域名连接：

- **默认 mDNS 地址**：`http://acpm.local:18790`（广播服务类型 `_acpm._tcp`）
- **获取 Token**：在宿主 Mac 菜单栏 **右键点击 AcpmRuntime 图标 -> 按住 `⌥ (Option)` 点击「复制 Bearer Token (`⌥⌘C`)」**，或打开 **设置 (`⌘,`) -> 连接** 一键复制 API 地址与 Token。

### 1.3 请求头与安全约束

除 `GET /healthz` 外，**所有接口均要求 Bearer 鉴权**，并建议携带调度元数据请求头：

| Header | 必填 | 可选值 / 说明 |
| --- | --- | --- |
| `Authorization` | **是** | `Bearer <token>` |
| `X-AI-Priority` | 否 | `interactive` / `normal`（默认）/ `batch`；`interactive` 可优先队列调度并在句级抢占批量任务 |
| `X-AI-Caller` | 否 | 调用方标识（如 `yanmo-ime`、`my-agent`），会在控制台概览统计调用次数 |
| `X-AI-Request-Id` | 否 | 请求唯一追踪 ID，响应头 `x-ai-request-id` 与错误日志会原样回传 |

**安全护栏说明**：
- 守护进程拒绝任何携带浏览器 `Origin` 请求头的跨域请求（返回 `403 ORIGIN_HEADER_REJECTED`），防止网页直接调用本机引擎。
- `Host` 头仅允许 `127.0.0.1`、`localhost`、`[::1]`、`<mdns_hostname>`（默认 `acpm.local`）及当前激活的局域网 IP。
- 单次请求体（含 Multipart 音频上传）上限为 **128 MB**。

---

## 2. 逻辑模型 ID 速查表

| 逻辑模型 ID | 能力 | 说明与特点 | 公开 HuggingFace 仓库 / 来源 |
| --- | --- | --- | --- |
| `yanmo-correct-4b-cot` | `llm` | 本地 4B 思维链纠错 / 对话模型（16 GB+ 推荐，支持 `<think>` 拆分与 KV 缓存） | [Happenmasss/yanmo-correct-4b-cot-mlx-8bit](https://huggingface.co/Happenmasss/yanmo-correct-4b-cot-mlx-8bit) |
| `yanmo-correct-9b-cot` | `llm` | 高精度蒸馏 9B 思维链纠错模型（24 GB+ 推荐，支持 `<think>` 拆分与 KV 缓存） | [Happenmasss/yanmo-correct-9b-cot-mlx-8bit](https://huggingface.co/Happenmasss/yanmo-correct-9b-cot-mlx-8bit) |
| `qwen3-asr-0.6b` | `asr` | 轻量多语种语音识别，适合 16 GB 机型与 LLM 协同热驻留 | MLX Community |
| `qwen3-asr-1.7b` | `asr` | 高精度多语种与方言识别，适合 24 GB+ 统一内存主机 | MLX Community |
| `qwen3-tts-0.6b` | `tts` | 轻量零样本音色克隆语音合成 | MLX Community |
| `qwen3-tts-1.7b` | `tts` | 高质量音色克隆、指令可控合成（`instruct` / `VoiceDesign`） | MLX Community |
| `speech-vad-pyannote` | `vad` | Pyannote Segmentation 3.0 CPU 语音活动检测（**随应用内置，开箱即用**） | `sherpa-onnx`（内置） |

> 注：`acpmd` 会自动扫描标准 HuggingFace Hub 缓存（`~/.cache/huggingface/hub/models--...`）；实际已安装/就绪状态请以 `GET /v1/models` 返回的 `installed` 字段为准。

---

## 3. HTTP API 接口参考（含同机与跨设备示例）

以下示例假设已设置：

```bash
export ACPM_URL="http://127.0.0.1:18790"   # 跨设备可用 http://acpm.local:18790
export ACPM_TOKEN="<你的 Bearer Token>"
```

### 3.1 健康检查与模型调度

#### `GET /healthz`（免鉴权）
检查服务是否在线及 mDNS 广播地址：
```bash
curl -sS "$ACPM_URL/healthz"
```

#### `GET /v1/models`
查看所有模型状态（`STOPPED` / `LOADING` / `WARM` / `RUNNING`）、是否就绪（`installed`）及内存占用：
```bash
curl -sS "$ACPM_URL/v1/models" -H "Authorization: Bearer $ACPM_TOKEN"
```

#### `POST /v1/models/prewarm`
提前预热模型并可选建立系统提示词 KV 前缀缓存（适合输入法激活时调用）：
```bash
curl -sS -X POST "$ACPM_URL/v1/models/prewarm" \
  -H "Authorization: Bearer $ACPM_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"models":["qwen3-asr-0.6b","yanmo-correct-4b-cot"],"prompt_cache_keys":["ime-default"]}'
```

#### 其他模型控制接口
- `POST /v1/models/:id/load`：显式加载指定模型至热驻留状态
- `POST /v1/models/:id/unload`：立即卸载指定模型释放统一内存
- `PATCH /v1/models/:id/config`：热更新驻留策略（`pin_policy`: `auto`/`pinned`/`ephemeral`、`idle_timeout_sec`、`quant`、`path`）

---

### 3.2 对话补全与流式纠错：`POST /v1/chat/completions`

兼容 OpenAI Chat Completions 协议（因此任何支持自定义 `base_url` 的 OpenAI 客户端只需指向 `http://127.0.0.1:18790/v1` 即可直接接入），并额外支持：
- `separate_reasoning`（默认 `true`）：自动将 `<think>...</think>` 思维链拆分为 `reasoning_content`，干净正文输出在 `content`。
- `prompt_cache_key`：复用系统前缀 KV Cache，显著降低首字延迟（TTFT）。

**流式 SSE 请求示例**：
```bash
curl -sS -N -X POST "$ACPM_URL/v1/chat/completions" \
  -H "Authorization: Bearer $ACPM_TOKEN" \
  -H "X-AI-Priority: interactive" \
  -H "X-AI-Caller: yanmo-ime" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "yanmo-correct-4b-cot",
    "messages": [
      {"role": "system", "content": "你是语音输入法纠错助手，请修正口述中的同音错别字并补充标点，只输出最终文本。"},
      {"role": "user", "content": "今天下午三点去北京开回大家别忘啦带电脑"}
    ],
    "stream": true,
    "temperature": 0.0,
    "max_tokens": 256,
    "separate_reasoning": true,
    "prompt_cache_key": "ime-default"
  }'
```

**非流式响应核心结构**：
```json
{
  "id": "chatcmpl-...",
  "object": "chat.completion",
  "model": "yanmo-correct-4b-cot",
  "choices": [{
    "index": 0,
    "message": {
      "role": "assistant",
      "reasoning_content": "...",
      "content": "今天下午三点去北京开会，大家别忘啦带电脑。"
    },
    "finish_reason": "stop"
  }],
  "x_acpm_timing": {
    "queue_ms": 0.4,
    "prefill_ms": 48.2,
    "decode_ms": 620.5,
    "kv_cache_hit": true
  }
}
```

---

### 3.3 CPU 语音活动检测（VAD）：`POST /v1/audio/vad`

由内置 `speech-vad-pyannote` 在 CPU ONNX 执行，不影响 GPU/NPU MLX 模型驻留。

- **同机传路径（JSON）**：
```bash
curl -sS -X POST "$ACPM_URL/v1/audio/vad" \
  -H "Authorization: Bearer $ACPM_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"speech-vad-pyannote","file_path":"/tmp/speech.wav","min_speech_ms":250,"min_silence_ms":300}'
```

- **跨设备上传音频（`multipart/form-data`）**：
```bash
curl -sS -X POST "$ACPM_URL/v1/audio/vad" \
  -H "Authorization: Bearer $ACPM_TOKEN" \
  -F "model=speech-vad-pyannote" \
  -F "min_speech_ms=250" \
  -F "file=@/path/to/audio.wav"
```

**响应示例**：
```json
{
  "segments": [{"start_ms": 180, "end_ms": 3420}],
  "duration_ms": 3800,
  "x_acpm_timing": {"queue_ms": 0.1, "decode_ms": 42.3}
}
```

---

### 3.4 语音识别转写（ASR）：`POST /v1/audio/transcriptions`

支持 `wav` / `m4a` / `mp3` / `flac` 等常见格式；开启 `vad_filter: true` 时，超过 28 秒的长音频会自动使用 CPU VAD 智能分段拼接，避免长音频退化。

- **同机传路径（JSON）**：
```bash
curl -sS -X POST "$ACPM_URL/v1/audio/transcriptions" \
  -H "Authorization: Bearer $ACPM_TOKEN" \
  -H "X-AI-Priority: interactive" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3-asr-0.6b","file_path":"/tmp/speech.wav","language":"auto","vad_filter":true,"timestamps":true}'
```

- **跨设备上传音频（`multipart/form-data`）**：
```bash
curl -sS -X POST "$ACPM_URL/v1/audio/transcriptions" \
  -H "Authorization: Bearer $ACPM_TOKEN" \
  -F "model=qwen3-asr-0.6b" \
  -F "language=zh" \
  -F "vad_filter=true" \
  -F "file=@/path/to/voice.m4a"
```

---

### 3.5 参考音色库与语音合成（TTS）

#### 管理音色档案
- **注册音色 `POST /v1/audio/voices`**（支持 JSON `reference_audio` 路径，或 Multipart 上传 `audio`/`file` + `name`、`reference_text`、`language`、`notes`）：
```bash
curl -sS -X POST "$ACPM_URL/v1/audio/voices" \
  -H "Authorization: Bearer $ACPM_TOKEN" \
  -F "name=新闻主播" \
  -F "language=zh" \
  -F "reference_text=大家好，欢迎收听今天的科技早报。" \
  -F "audio=@/path/to/ref.wav"
```
- `GET /v1/audio/voices`：列出所有已注册 `voice_id`
- `GET /v1/audio/voices/:id/sample`：获取原始参考音频（`audio/wav`）
- `DELETE /v1/audio/voices/:id`：删除音色档案

#### 单句合成：`POST /v1/audio/speech`
- **直接返回 WAV 二进制**（不传 `output_path`）：
```bash
curl -sS -X POST "$ACPM_URL/v1/audio/speech" \
  -H "Authorization: Bearer $ACPM_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3-tts-1.7b","voice":"v_xxx","input":"你好，欢迎体验本地音色克隆。","speed":1.0}' \
  --output out.wav
```
  > 响应头会附带 `x-ai-audio-duration-ms`、`x-ai-timing-decode-ms`、`x-ai-voice-cache-hit` 等性能指标。

- **同机直接写盘返回元数据**（传入 `output_path`）：返回 JSON `{ "output_path", "bytes", "sample_rate", "duration_ms", "voice_cache_hit" }`。

#### 可抢占批量配音作业
适合生成有声书或大段对话；每个句段间隙可被 `X-AI-Priority: interactive`（例如言墨输入法）毫秒级抢占而不丢失已完成进度：
- `POST /v1/audio/speech/batches`（指定 `output_dir`、`voice` 及多句 `items: [{id, text, output_file}]`）
- `GET /v1/audio/speech/batches/:id` / `GET /v1/audio/speech/batches/:id/events`（SSE 句级进度）
- `POST /v1/audio/speech/batches/:id/{pause,resume,cancel}`

---

### 3.6 系统监控、热配置与诊断

| 接口 | 说明 |
| --- | --- |
| `GET /v1/system/status` | 获取预算上限、已用统一内存、压力/热状态、活跃与排队请求数、各 Caller 计数 |
| `GET /v1/system/events` | SSE 实时事件流（`model_state_changed` / `batch_progress` / `download_progress` / `config_changed` / `failure_recorded`） |
| `GET / PATCH /v1/system/config` | 读取或热更新全局内存预算档位（`eco` / `balanced` / `performance`）与自定义 MB 上限 |
| `POST /v1/system/unload-all` | 一键卸载未常驻的空闲模型释放内存（可选 `{"include_pinned": true}`） |
| `GET /v1/system/failures` | 读取最近脱敏后的结构化错误日志（不含音视频或用户文本） |

---

## 4. 官方 SDK 与跨语言调用示例

### 4.1 Swift（macOS / iOS App，推荐用于言墨输入法及原生应用）

仓库自带 Swift Package：[`clients/swift`](../clients/swift)（模块名 `AcpmClient`）。

```swift
import AcpmClient

// 1. 同机自动发现（或跨设备使用 AcpmClient.fromMdns(host: "acpm.local", port: 18790, token: token)）
let client = try AcpmClient.fromDefaultDiscovery(caller: "yanmo-ime")

// 2. 应用激活时预热（可选）
_ = try await client.prewarm(
    models: ["qwen3-asr-0.6b", "yanmo-correct-4b-cot"],
    promptCacheKeys: ["ime-default"]
)

// 3. CPU VAD 语音检出
let vad = try await client.vad(VadRequest(filePath: "/tmp/input.wav"))

// 4. 语音识别（interactive 优先级）
let asr = try await client.transcribe(
    TranscriptionRequest(model: "qwen3-asr-0.6b", filePath: "/tmp/input.wav", vadFilter: true),
    priority: .interactive
)

// 5. 流式 4B CoT 后纠错
let stream = client.chatCompletionsStream(
    ChatCompletionRequest(
        model: "yanmo-correct-4b-cot",
        messages: [ChatMessage(role: "user", content: asr.text)],
        separateReasoning: true,
        promptCacheKey: "ime-default"
    ),
    priority: .interactive
)
for try await delta in stream {
    if let text = delta.content {
        print(text, terminator: "")
    }
}

// 6. 音色合成直接拿到 WAV 字节流播放
let wavData = try await client.speechAudio(
    SpeechRequest(model: "qwen3-tts-1.7b", input: "合成完成", voice: "v_xxx")
)
```

### 4.2 Python（零第三方依赖）

仓库自带纯标准库客户端：[`clients/python`](../clients/python)。

```python
from acpm_client import AcpmClient

# 同机发现：
client = AcpmClient.from_default_discovery(caller="my-python-tool")
# 或跨设备局域网 mDNS：
# client = AcpmClient.from_mdns(token="<ACPM_TOKEN>", host="acpm.local", port=18790, caller="remote-agent")

print(client.health())
vad_res = client.vad("/tmp/speech.wav")
asr_res = client.transcribe("/tmp/speech.wav", model="qwen3-asr-0.6b")

chat_res = client.chat_completions(
    [{"role": "user", "content": asr_res["text"]}],
    model="yanmo-correct-4b-cot",
    separate_reasoning=True,
)
print("纠错结果:", chat_res["choices"][0]["message"]["content"])

# 音色克隆并返回 WAV bytes
wav_bytes = client.speech("你好，测试语音合成。", voice="v_xxx")
open("out.wav", "wb").write(wav_bytes)
```

### 4.3 Node.js / TypeScript 或 OpenAI 兼容生态（Cursor / Continue / Cline 等）

任何兼容 OpenAI API 的工具或 `openai` SDK，可直接把 `baseURL` 设为 `http://127.0.0.1:18790/v1`（或 `http://acpm.local:18790/v1`）：

```ts
import OpenAI from "openai";

const openai = new OpenAI({
  baseURL: "http://127.0.0.1:18790/v1",
  apiKey: process.env.ACPM_TOKEN, // 来自 runtime.json 或右键菜单 ⌥⌘C
  defaultHeaders: {
    "X-AI-Priority": "interactive",
    "X-AI-Caller": "ts-app",
  },
});

const stream = await openai.chat.completions.create({
  model: "yanmo-correct-4b-cot",
  messages: [{ role: "user", content: "测试一句语音识别纠错" }],
  stream: true,
});

for await (const chunk of stream) {
  process.stdout.write(chunk.choices[0]?.delta?.content ?? "");
}
```

> **提示**：如从非本机或浏览器插件内核发起请求，请确保**不要附带浏览器 `Origin` 请求头**，否则会被同机安全策略拦截。

---

## 5. 低延迟输入法接入最佳实践（以言墨为例）

1. **利用空闲唤醒 + 适度预热**：用户唤出语音输入面板时发送一次轻量 `POST /v1/models/prewarm`；若希望长期驻留，可在 `AcpmRuntime`「模型 -> 检查器」中将 `yanmo-correct-4b-cot` 与 `qwen3-asr-0.6b` 的驻留策略设为「自动（20–30 分钟）」或「常驻内存」。
2. **固定 System Prompt 配 `prompt_cache_key`**：纠错请求固定传入相同的 `system` 消息和 `prompt_cache_key`（如 `"ime-default"`），二次纠错可命中 KV 前缀缓存，大幅压缩 Prefill 耗时。
3. **始终标记 `X-AI-Priority: interactive`**：即使后台正在执行长时间 TTS 批量配音，高优交互请求也会在下一句间隙立刻插队调度。
4. **先本地轻量判停再调 ASR**：先调 `POST /v1/audio/vad`（CPU 执行、几十毫秒级），无有效人声段可直接跳过 ASR 调用节省算力。

---

## 6. 统一结构化错误格式与错误码

所有非 2xx 错误均返回统一结构化信封（且不含原始音频与用户文本）：

```json
{
  "error": {
    "code": "MODEL_NOT_INSTALLED",
    "message": "Model 'qwen3-asr-0.6b' is not installed.",
    "request_id": "e1b8...",
    "stage": "MODEL_PREPARE",
    "detail": "MISSING_WEIGHT_FILES",
    "native_code": null,
    "elapsed_ms": 3,
    "retryable": false
  }
}
```

| `code` | HTTP 状态 | 默认可重试 | 常见含义与处理建议 |
| --- | --- | --- | --- |
| `INVALID_REQUEST` / `AUDIO_VALIDATION_FAILED` | 400 | 否 | 请求 JSON 格式错误、字段缺失或音频损坏/路径非法 |
| `UNAUTHORIZED` | 401 | 否 | Bearer Token 缺失或已过期（重新读取 `runtime.json` 即可） |
| `FORBIDDEN` | 403 | 否 | 非法 `Host` 头或携带了浏览器 `Origin` 头 |
| `NOT_FOUND` | 404 | 否 | `model_id`、`voice_id` 或 `batch_id` 不存在 |
| `CANCELLED` | 408 | 否 | 请求超时或被调用方主动取消 |
| `UNSUPPORTED_PLATFORM` | 422 | 否 | 当前平台无适配量化变体 |
| `MODEL_NOT_INSTALLED` | 424 | 否 | 模型权重未绑定或未下载；提示用户在 AcpmRuntime「模型」页绑定或下载 |
| `INFERENCE_FAILED` | 500 | 否 | Worker 推理失败，查看 `stage` 与 `detail` 定位 |
| `NOT_IMPLEMENTED` | 501 | 否 | 当前已延后或未启用的接口（如 `/v1/audio/diarization`） |
| `WORKER_CRASHED` | 502 | **是** | 子进程 Worker 异常退出，守护进程会自动清理状态，可直接退避重试 |
| `SCHEDULER_BUSY` | 503 | **是** | 并发槽位已满，建议短暂退避后重试或提高 `X-AI-Priority` |
| `QUEUE_TIMEOUT` | 504 | **是** | 排队等待超时 |
| `INSUFFICIENT_MEMORY` | 507 | 否 | 模型所需内存超出当前预算上限，可引导用户在设置中提高内存预算档位 |
