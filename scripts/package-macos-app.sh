#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${ACPM_DIST_DIR:-$ROOT_DIR/dist}"
APP_DIR="$DIST_DIR/AcpmRuntime.app"
PACKAGING_DIR="$ROOT_DIR/apps/macos-console/Packaging"
ENTITLEMENTS="$PACKAGING_DIR/AcpmRuntime.entitlements"
INFO_PLIST="$PACKAGING_DIR/Info.plist"
APP_ICON_ICNS="$PACKAGING_DIR/AppIcon.icns"
DMG_BG_PNG="$PACKAGING_DIR/dmg-background.png"
REGISTRY_SRC="$ROOT_DIR/manifests/registry.example.json"
METALLIB_SRC="$ROOT_DIR/.cache/mlx-metallib/0.33.0/default.metallib"
ORT_DYLIB_SRC="$ROOT_DIR/.cache/sherpa-onnx/v2.0.3/lib/libonnxruntime.dylib"
VAD_ONNX_SRC="$ROOT_DIR/.cache/sherpa-onnx/models/speech-vad-pyannote/segmentation.onnx"
SIGN_IDENTITY="${ACPM_SIGN_IDENTITY:--}"

CREATE_DMG=0
DO_NOTARIZE=0
REGEN_ASSETS=0
BUNDLE_VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dmg)
      CREATE_DMG=1
      shift
      ;;
    --notarize)
      DO_NOTARIZE=1
      shift
      ;;
    --regen-assets)
      REGEN_ASSETS=1
      shift
      ;;
    --version)
      if [[ $# -lt 2 ]]; then
        echo "--version requires a value (e.g. 0.2.0)" >&2
        exit 2
      fi
      BUNDLE_VERSION="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1 (supported: --dmg, --notarize, --regen-assets, --version <ver>)" >&2
      exit 2
      ;;
  esac
done

"$ROOT_DIR/scripts/ensure-metallib.sh"
"$ROOT_DIR/scripts/ensure-sherpa-onnx.sh"

if [[ "$REGEN_ASSETS" == "1" || ! -f "$APP_ICON_ICNS" || ! -f "$DMG_BG_PNG" ]]; then
  echo "[package-macos-app] Generating AppIcon.icns and DMG background..."
  swift "$ROOT_DIR/scripts/generate-app-icon.swift"
fi

PATH="$HOME/.cargo/bin:$PATH" cargo build --release --manifest-path "$ROOT_DIR/core/Cargo.toml" -p acpmd -p acpm-worker-speech
swift build -c release --package-path "$ROOT_DIR/workers/macos-mlx" --build-system native
swift build -c release --package-path "$ROOT_DIR/apps/macos-console"

MLX_BIN_DIR="$(swift build -c release --package-path "$ROOT_DIR/workers/macos-mlx" --build-system native --show-bin-path)"
CONSOLE_BIN_DIR="$(swift build -c release --package-path "$ROOT_DIR/apps/macos-console" --show-bin-path)"

ACPM_CONSOLE_BIN="$CONSOLE_BIN_DIR/AcpmRuntime"
ACPMD_BIN="$ROOT_DIR/core/target/release/acpmd"
WORKER_MLX_BIN="$MLX_BIN_DIR/acpm-worker-mlx"
WORKER_SPEECH_BIN="$ROOT_DIR/core/target/release/acpm-worker-speech"

for req_file in "$ACPM_CONSOLE_BIN" "$ACPMD_BIN" "$WORKER_MLX_BIN" "$WORKER_SPEECH_BIN" "$METALLIB_SRC" "$ORT_DYLIB_SRC" "$VAD_ONNX_SRC" "$REGISTRY_SRC" "$INFO_PLIST" "$ENTITLEMENTS" "$APP_ICON_ICNS" "$DMG_BG_PNG"; do
  if [[ ! -f "$req_file" ]]; then
    echo "[package-macos-app] Missing required artifact: $req_file" >&2
    exit 1
  fi
done

rm -rf "$APP_DIR"
mkdir -p \
  "$APP_DIR/Contents/MacOS" \
  "$APP_DIR/Contents/Helpers" \
  "$APP_DIR/Contents/Frameworks" \
  "$APP_DIR/Contents/Resources/models/speech-vad-pyannote"

cp -f "$INFO_PLIST" "$APP_DIR/Contents/Info.plist"
if [[ -n "$BUNDLE_VERSION" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $BUNDLE_VERSION" "$APP_DIR/Contents/Info.plist"
fi
printf "APPL????" > "$APP_DIR/Contents/PkgInfo"
cp -f "$ACPM_CONSOLE_BIN" "$APP_DIR/Contents/MacOS/AcpmRuntime"
cp -f "$ACPMD_BIN" "$APP_DIR/Contents/Helpers/acpmd"
cp -f "$WORKER_MLX_BIN" "$APP_DIR/Contents/Helpers/acpm-worker-mlx"
cp -f "$WORKER_SPEECH_BIN" "$APP_DIR/Contents/Helpers/acpm-worker-speech"
cp -f "$ORT_DYLIB_SRC" "$APP_DIR/Contents/Frameworks/libonnxruntime.dylib"
cp -f "$METALLIB_SRC" "$APP_DIR/Contents/Resources/default.metallib"
cp -f "$METALLIB_SRC" "$APP_DIR/Contents/Resources/mlx.metallib"
cp -f "$REGISTRY_SRC" "$APP_DIR/Contents/Resources/default-registry.json"
cp -f "$APP_ICON_ICNS" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp -f "$VAD_ONNX_SRC" "$APP_DIR/Contents/Resources/models/speech-vad-pyannote/segmentation.onnx"

chmod 755 "$APP_DIR/Contents/MacOS/AcpmRuntime" \
          "$APP_DIR/Contents/Helpers/acpmd" \
          "$APP_DIR/Contents/Helpers/acpm-worker-mlx" \
          "$APP_DIR/Contents/Helpers/acpm-worker-speech" \
          "$APP_DIR/Contents/Frameworks/libonnxruntime.dylib"

sign_item() {
  local target="$1"
  local with_entitlements="${2:-0}"
  local cs_args=(--force --sign "$SIGN_IDENTITY")
  if [[ "$SIGN_IDENTITY" != "-" ]]; then
    cs_args+=(--options runtime --timestamp)
  fi
  if [[ "$with_entitlements" == "1" ]]; then
    cs_args+=(--entitlements "$ENTITLEMENTS")
  fi
  codesign "${cs_args[@]}" "$target"
}

# Inside-out code signing for Frameworks -> Helpers -> App bundle
sign_item "$APP_DIR/Contents/Frameworks/libonnxruntime.dylib" 0
sign_item "$APP_DIR/Contents/Helpers/acpm-worker-speech" 1
sign_item "$APP_DIR/Contents/Helpers/acpm-worker-mlx" 1
sign_item "$APP_DIR/Contents/Helpers/acpmd" 1
sign_item "$APP_DIR" 1

codesign --verify --deep --strict --verbose=2 "$APP_DIR"
echo "[package-macos-app] Verified bundle: $APP_DIR"

DMG_PATH="$DIST_DIR/AcpmRuntime-macos-arm64.dmg"
DMG_MOUNT_POINT=""
DMG_STAGE=""
DMG_RW_PATH=""
cleanup_packaging() {
  if [[ -n "$DMG_MOUNT_POINT" && -d "$DMG_MOUNT_POINT" ]]; then
    hdiutil detach -force "$DMG_MOUNT_POINT" >/dev/null 2>&1 || true
  fi
  if [[ -n "$DMG_STAGE" && -d "$DMG_STAGE" ]]; then
    rm -rf "$DMG_STAGE"
  fi
  if [[ -n "$DMG_RW_PATH" && -f "$DMG_RW_PATH" ]]; then
    rm -f "$DMG_RW_PATH"
  fi
}
trap cleanup_packaging EXIT

if [[ "$CREATE_DMG" == "1" ]]; then
  DMG_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/acpm-dmg-stage.XXXXXX")"
  DMG_RW_PATH="$DIST_DIR/.AcpmRuntime-rw.dmg"
  DMG_MOUNT_POINT="/Volumes/AcpmRuntime"

  cp -R "$APP_DIR" "$DMG_STAGE/AcpmRuntime.app"
  ln -s /Applications "$DMG_STAGE/Applications"
  mkdir -p "$DMG_STAGE/.background"
  cp -f "$DMG_BG_PNG" "$DMG_STAGE/.background/dmg-background.png"

  rm -f "$DMG_PATH" "$DMG_RW_PATH"

  STYLED_OK=0
  if hdiutil create -volname "AcpmRuntime" -srcfolder "$DMG_STAGE" -ov -format UDRW "$DMG_RW_PATH" >/dev/null 2>&1; then
    ATTACH_OUT="$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_RW_PATH" 2>/dev/null || true)"
    ATTACHED_MOUNT="$(printf '%s\n' "$ATTACH_OUT" | sed -n 's/^.*\(\/Volumes\/.*\)$/\1/p' | tail -n 1)"
    if [[ -n "$ATTACHED_MOUNT" ]]; then
      DMG_MOUNT_POINT="$ATTACHED_MOUNT"
      VOL_NAME="$(basename "$DMG_MOUNT_POINT")"
      if osascript <<EOF >/dev/null 2>&1
tell application "Finder"
  tell disk "$VOL_NAME"
    open
    set current view of container window of disk "$VOL_NAME" to icon view
    set toolbar visible of container window of disk "$VOL_NAME" to false
    set statusbar visible of container window of disk "$VOL_NAME" to false
    set the bounds of container window of disk "$VOL_NAME" to {220, 180, 880, 600}
    set viewOptions to the icon view options of container window of disk "$VOL_NAME"
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 112
    set background picture of viewOptions to file ".background:dmg-background.png"
    set position of item "AcpmRuntime.app" of container window of disk "$VOL_NAME" to {175, 225}
    set position of item "Applications" of container window of disk "$VOL_NAME" to {485, 225}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
      then
        STYLED_OK=1
      fi
      sync
      hdiutil detach "$DMG_MOUNT_POINT" >/dev/null 2>&1 || hdiutil detach -force "$DMG_MOUNT_POINT" >/dev/null 2>&1 || true
      DMG_MOUNT_POINT=""
    fi

    if [[ "$STYLED_OK" == "1" ]]; then
      hdiutil convert "$DMG_RW_PATH" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
    fi
  fi

  if [[ "$STYLED_OK" != "1" ]]; then
    echo "[package-macos-app] Finder styling unavailable in current session; falling back to plain UDZO DMG."
    hdiutil create -volname "AcpmRuntime" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null
  fi

  rm -f "$DMG_RW_PATH"
  if [[ "$SIGN_IDENTITY" != "-" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
  fi
  (cd "$DIST_DIR" && shasum -a 256 "$(basename "$DMG_PATH")" > "$DMG_PATH.sha256")
  echo "[package-macos-app] Created DMG: $DMG_PATH"
  echo "[package-macos-app] Checksum:    $(cat "$DMG_PATH.sha256")"
fi

if [[ "$DO_NOTARIZE" == "1" ]]; then
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "[package-macos-app] --notarize requires ACPM_SIGN_IDENTITY (Developer ID Application certificate)." >&2
    exit 1
  fi
  NOTARY_PROFILE="${ACPM_NOTARY_PROFILE:?ACPM_NOTARY_PROFILE keychain profile is required for --notarize}"
  if [[ "$CREATE_DMG" == "1" && -f "$DMG_PATH" ]]; then
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
  else
    NOTARY_ZIP="$DIST_DIR/AcpmRuntime-macos-arm64.zip"
    rm -f "$NOTARY_ZIP"
    ditto -c -k --keepParent "$APP_DIR" "$NOTARY_ZIP"
    xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP_DIR"
  fi
fi
