#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="v2.0.3"
ARCHIVE_NAME="sherpa-onnx-${VERSION}-osx-arm64-shared-no-tts-lib.tar.bz2"
DOWNLOAD_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/${VERSION}/${ARCHIVE_NAME}"

CACHE_BASE="$ROOT_DIR/.cache/sherpa-onnx"
EXTRACT_DIR="$CACHE_BASE/$VERSION"
LIB_DIR="$EXTRACT_DIR/lib"
ARCHIVE_PATH="$CACHE_BASE/$ARCHIVE_NAME"
MODELS_STAGE="$CACHE_BASE/models"

mkdir -p "$CACHE_BASE" "$EXTRACT_DIR" "$MODELS_STAGE"

verify_dylibs() {
  local ort_dylib
  ort_dylib="$(find "$LIB_DIR" -maxdepth 1 -name 'libonnxruntime*.dylib' | head -n 1 || true)"
  [[ -n "$ort_dylib" && -f "$ort_dylib" ]] || return 1
  file "$ort_dylib" | grep -q "Mach-O" || return 1
  return 0
}

if ! verify_dylibs; then
  if [[ ! -f "$ARCHIVE_PATH" ]]; then
    echo "[ensure-sherpa-onnx] Downloading $DOWNLOAD_URL..."
    curl -fL --retry 3 -o "${ARCHIVE_PATH}.part" "$DOWNLOAD_URL"
    mv "${ARCHIVE_PATH}.part" "$ARCHIVE_PATH"
  fi
  echo "[ensure-sherpa-onnx] Extracting $ARCHIVE_NAME into $EXTRACT_DIR..."
  tar -xjf "$ARCHIVE_PATH" --strip-components=1 -C "$EXTRACT_DIR"
  rm -rf "$EXTRACT_DIR/sherpa-onnx-${VERSION}-osx-arm64-shared-no-tts-lib"
fi

if ! verify_dylibs; then
  echo "[ensure-sherpa-onnx] ERROR: failed verifying sherpa-onnx/onnxruntime dylibs in $LIB_DIR" >&2
  exit 1
fi

echo "[ensure-sherpa-onnx] Verified dylibs in $LIB_DIR"
ls -lh "$LIB_DIR"/libonnxruntime*.dylib

SEG_SRC="${ACPM_SEG_ONNX_SRC:-$HOME/.cache/codex/models/sherpa-onnx/sherpa-onnx-pyannote-segmentation-3-0/model.onnx}"

if [[ -f "$SEG_SRC" ]]; then
  mkdir -p "$MODELS_STAGE/speech-vad-pyannote"
  ln -sfn "$SEG_SRC" "$MODELS_STAGE/speech-vad-pyannote/segmentation.onnx"
  echo "[ensure-sherpa-onnx] Staged speech-vad-pyannote -> $SEG_SRC"
fi
