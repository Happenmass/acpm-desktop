#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="0.33.0"
CACHE_DIR="${ROOT_DIR}/.cache/mlx-metallib/${VERSION}"
ZIP_PATH="${CACHE_DIR}/Cmlx.xcframework.zip"
METALLIB_PATH="${CACHE_DIR}/default.metallib"
URL="https://github.com/ml-explore/mlx-swift/releases/download/${VERSION}/Cmlx.xcframework.zip"

mkdir -p "${CACHE_DIR}"

if xcrun metal --version >/dev/null 2>&1; then
    echo "[ensure-metallib] Native Xcode MetalToolchain detected."
fi

if [[ ! -s "${METALLIB_PATH}" ]]; then
    if [[ ! -s "${ZIP_PATH}" ]]; then
        echo "[ensure-metallib] Downloading Cmlx.xcframework.zip (${VERSION})..."
        curl -fL --retry 3 -o "${ZIP_PATH}.part" "${URL}"
        mv "${ZIP_PATH}.part" "${ZIP_PATH}"
    fi

    echo "[ensure-metallib] Inspecting Cmlx.xcframework.zip entries..."
    ENTRY=$(unzip -Z1 "${ZIP_PATH}" | grep -E 'macos-arm64.*/.*\.(metallib|metallib/default\.metallib)$|macos-arm64.*/.*default\.metallib$' | head -n 1 || true)
    if [[ -z "${ENTRY}" ]]; then
        ENTRY=$(unzip -Z1 "${ZIP_PATH}" | grep -E 'macos.*/.*default\.metallib$' | head -n 1 || true)
    fi
    if [[ -z "${ENTRY}" ]]; then
        ENTRY=$(unzip -Z1 "${ZIP_PATH}" | grep -E 'macos.*\.metallib$' | head -n 1 || true)
    fi
    if [[ -z "${ENTRY}" ]]; then
        echo "[ensure-metallib] Could not find macOS metallib in ${ZIP_PATH}. Entries:" >&2
        unzip -Z1 "${ZIP_PATH}" | head -n 50 >&2
        exit 1
    fi

    echo "[ensure-metallib] Extracting ${ENTRY} -> ${METALLIB_PATH}"
    unzip -p "${ZIP_PATH}" "${ENTRY}" > "${METALLIB_PATH}.part"
    mv "${METALLIB_PATH}.part" "${METALLIB_PATH}"
fi

if [[ ! -s "${METALLIB_PATH}" ]]; then
    echo "[ensure-metallib] Extracted metallib is empty!" >&2
    exit 1
fi

MAGIC=$(head -c 4 "${METALLIB_PATH}" | tr -dc '[:print:]')
echo "[ensure-metallib] Verified metallib (${MAGIC}): $(wc -c < "${METALLIB_PATH}") bytes at ${METALLIB_PATH}"
file "${METALLIB_PATH}" || true

install_to_dir() {
    local target_dir="$1"
    if [[ -d "${target_dir}" ]]; then
        cp -f "${METALLIB_PATH}" "${target_dir}/default.metallib"
        cp -f "${METALLIB_PATH}" "${target_dir}/mlx.metallib"
        mkdir -p "${target_dir}/mlx-swift_Cmlx.bundle/Contents/Resources"
        cp -f "${METALLIB_PATH}" "${target_dir}/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
        echo "[ensure-metallib] Installed metallib into ${target_dir}"
    fi
}

WORKER_BUILD_DIR="${ROOT_DIR}/workers/macos-mlx/.build"
for cfg in debug release arm64-apple-macosx/debug arm64-apple-macosx/release; do
    if [[ -d "${WORKER_BUILD_DIR}/${cfg}" ]]; then
        install_to_dir "${WORKER_BUILD_DIR}/${cfg}"
    fi
done

if [[ "${1:-}" != "" ]] && [[ -d "$1" ]]; then
    install_to_dir "$1"
fi
