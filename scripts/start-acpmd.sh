#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT_DIR/scripts/ensure-metallib.sh"
"$ROOT_DIR/scripts/ensure-sherpa-onnx.sh"

ACPMD_BIN="${ACPMD_BIN:-}"
if [[ -z "$ACPMD_BIN" ]]; then
  if [[ -x "$ROOT_DIR/core/target/release/acpmd" ]]; then
    ACPMD_BIN="$ROOT_DIR/core/target/release/acpmd"
  elif [[ -x "$ROOT_DIR/core/target/debug/acpmd" ]]; then
    ACPMD_BIN="$ROOT_DIR/core/target/debug/acpmd"
  else
    PATH="$HOME/.cargo/bin:$PATH" cargo build --release --manifest-path "$ROOT_DIR/core/Cargo.toml" -p acpmd -p acpm-worker-speech
    ACPMD_BIN="$ROOT_DIR/core/target/release/acpmd"
  fi
fi

WORKER_BIN="${ACPM_WORKER_MLX_BIN:-$ROOT_DIR/workers/macos-mlx/.build/release/acpm-worker-mlx}"
if [[ ! -x "$WORKER_BIN" ]]; then
  swift build -c release --package-path "$ROOT_DIR/workers/macos-mlx" --build-system native
fi

SPEECH_WORKER_BIN="${ACPM_WORKER_SPEECH_BIN:-}"
if [[ -z "$SPEECH_WORKER_BIN" ]]; then
  if [[ -x "$ROOT_DIR/core/target/release/acpm-worker-speech" ]]; then
    SPEECH_WORKER_BIN="$ROOT_DIR/core/target/release/acpm-worker-speech"
  elif [[ -x "$ROOT_DIR/core/target/debug/acpm-worker-speech" ]]; then
    SPEECH_WORKER_BIN="$ROOT_DIR/core/target/debug/acpm-worker-speech"
  else
    PATH="$HOME/.cargo/bin:$PATH" cargo build --release --manifest-path "$ROOT_DIR/core/Cargo.toml" -p acpm-worker-speech
    SPEECH_WORKER_BIN="$ROOT_DIR/core/target/release/acpm-worker-speech"
  fi
fi

LLM_DIR="${ACPM_LLM_DIR:-$HOME/.cache/codex/models/yanmo-polish/2026-11-23/qwen35-4b-v6-mlx8}"
ASR_DIR="${ACPM_ASR_DIR:-$HOME/.cache/huggingface/hub/models--mlx-community--Qwen3-ASR-1.7B-8bit/snapshots/a8379a2e2f9e313c9292cdf1af4055ab56d50d55}"
TTS_DIR="${ACPM_TTS_DIR:-$HOME/.cache/huggingface/local-models/mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16}"
VAD_DIR="${ACPM_VAD_DIR:-$ROOT_DIR/.cache/sherpa-onnx/models/speech-vad-pyannote}"

ARGS=(
  --port "${ACPM_PORT:-18790}"
  --mdns-host "${ACPM_MDNS_HOST:-acpm.local}"
  --budget-tier "${ACPM_BUDGET_TIER:-balanced}"
  --worker-mlx-bin "$WORKER_BIN"
  --worker-speech-bin "$SPEECH_WORKER_BIN"
)

if [[ -d "$LLM_DIR" ]]; then
  ARGS+=(--model-path "yanmo-correct-4b-cot=$LLM_DIR")
fi
if [[ -d "$ASR_DIR" ]]; then
  ARGS+=(--model-path "qwen3-asr-1.7b=$ASR_DIR")
fi
if [[ -d "$TTS_DIR" ]]; then
  ARGS+=(--model-path "qwen3-tts-1.7b=$TTS_DIR")
fi
if [[ -d "$VAD_DIR" ]]; then
  ARGS+=(--model-path "speech-vad-pyannote=$VAD_DIR")
fi

exec "$ACPMD_BIN" "${ARGS[@]}" "$@"
