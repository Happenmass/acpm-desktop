# Windows + CUDA Workers（预留目录）

本目录预留用于后续 **Windows x64 + NVIDIA CUDA** 平台原生 Worker 实现。

## 设计约束（与 `docs/spec/03-worker-protocol.md` 保持一致）

1. **进程与控制通道**：
   - 使用 `acpm-protocol` 定义的统一 CLI 参数、`ACPM_FRAME\t` 单行 JSON 帧与 `stdin` `{"cmd":"shutdown"}` / EOF 自杀退出契约。
   - 由 `acpmd` 的 `WindowsProcessSupervisor` 挂入 Win32 Job Object（`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`），防止进程异常崩溃导致孤儿 CUDA Context 长期占用显存。
2. **计划中的 Worker 映射**：
   - `acpm-worker-cuda-llm`：基于 `llama.cpp`（CUDA / GGUF `q4_k_m`）承载 4B CoT 后纠错模型，原样吐出 `<think>...</think>`，并支持前缀 KV Cache。
   - `acpm-worker-cuda-asr`：承载 `qwen3-asr-0.6b` / `1.7b`。
   - `acpm-worker-cuda-tts`：承载 `qwen3-tts-0.6b` / `1.7b`（单句合成 + 参考音频特征缓存）。
   - VAD 与说话人分离直接复用根目录 `core/worker-speech`（`sherpa-onnx` 跨平台 CPU Worker），无需重复编写。
