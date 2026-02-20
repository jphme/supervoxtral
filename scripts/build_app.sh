#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RECOMMENDED_MLX_VERSION="0.30.3"

read_version() {
  if [[ -n "${SUPERVOXTRAL_VERSION:-}" ]]; then
    echo "${SUPERVOXTRAL_VERSION}"
    return 0
  fi
  if [[ -f "$ROOT_DIR/VERSION" ]]; then
    tr -d '[:space:]' < "$ROOT_DIR/VERSION"
    return 0
  fi
  echo "0.1.0"
}

run_release_build() {
  swift build --disable-sandbox -c release
}

find_mlx_metallib() {
  if [[ -n "${SUPERVOXTRAL_MLX_METALLIB:-}" && -f "${SUPERVOXTRAL_MLX_METALLIB}" ]]; then
    echo "${SUPERVOXTRAL_MLX_METALLIB}"
    return 0
  fi

  shopt -s nullglob
  local candidate
  for candidate in \
    "$ROOT_DIR"/../.venv/lib/python*/site-packages/mlx/lib/mlx.metallib \
    "$HOME"/.venv/lib/python*/site-packages/mlx/lib/mlx.metallib \
    "$HOME"/Library/Python/*/lib/python*/site-packages/mlx/lib/mlx.metallib; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  shopt -u nullglob

  if command -v uv >/dev/null 2>&1; then
    local via_uv
    via_uv="$(
      cd "$ROOT_DIR/.." && uv run python - <<'PY' 2>/dev/null || true
import os
from pathlib import Path
try:
    import mlx.core as core
except Exception:
    raise SystemExit(0)

lib_path = Path(core.__file__).resolve().parent / "lib" / "mlx.metallib"
if lib_path.exists():
    print(lib_path)
PY
    )"
    if [[ -n "$via_uv" && -f "$via_uv" ]]; then
      echo "$via_uv"
      return 0
    fi
  fi

  if command -v python3 >/dev/null 2>&1; then
    local via_python3
    via_python3="$(
      python3 - <<'PY' 2>/dev/null || true
from pathlib import Path
try:
    import mlx.core as core
except Exception:
    raise SystemExit(0)

lib_path = Path(core.__file__).resolve().parent / "lib" / "mlx.metallib"
if lib_path.exists():
    print(lib_path)
PY
    )"
    if [[ -n "$via_python3" && -f "$via_python3" ]]; then
      echo "$via_python3"
      return 0
    fi
  fi

  return 1
}

validate_mlx_python_version() {
  if [[ -n "${SUPERVOXTRAL_MLX_METALLIB:-}" ]]; then
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    return 0
  fi

  local mlx_version
  mlx_version="$(
    python3 - <<'PY' 2>/dev/null || true
try:
    import mlx
except Exception:
    raise SystemExit(0)
print(getattr(mlx, "__version__", ""))
PY
  )"

  if [[ -n "$mlx_version" && "$mlx_version" != "$RECOMMENDED_MLX_VERSION" ]]; then
    echo "[supervoxtral] ERROR: Python mlx version is $mlx_version, but this project expects $RECOMMENDED_MLX_VERSION."
    echo "[supervoxtral] Install matching version: python3 -m pip install --user \"mlx==$RECOMMENDED_MLX_VERSION\""
    echo "[supervoxtral] or set SUPERVOXTRAL_MLX_METALLIB=/path/to/mlx.metallib"
    exit 1
  fi
}

APP_VERSION="$(read_version)"
BUILD_NUMBER="${SUPERVOXTRAL_BUILD_NUMBER:-1}"
validate_mlx_python_version

echo "[supervoxtral] Building release binary..."
BUILD_LOG="$(mktemp -t supervoxtral-build.XXXXXX.log)"
trap 'rm -f "$BUILD_LOG"' EXIT

if ! run_release_build 2>&1 | tee "$BUILD_LOG"; then
  if grep -Eq "missing required module '_(Numerics|Atomics)Shims'" "$BUILD_LOG"; then
    echo "[supervoxtral] Detected stale SwiftPM shim artifacts. Cleaning and retrying once..."
    swift package clean || true
    rm -rf "$ROOT_DIR/.build"
    run_release_build
  else
    echo "[supervoxtral] Build failed. See log above."
    exit 1
  fi
fi

BIN_PATH="$(find "$ROOT_DIR/.build" -type f -path "*/release/supervoxtral" | head -n 1)"
if [[ -z "$BIN_PATH" ]]; then
  echo "[supervoxtral] Could not find built binary"
  exit 1
fi

APP_PATH="$ROOT_DIR/dist/Supervoxtral.app"
CONTENTS="$APP_PATH/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

rm -rf "$APP_PATH"
mkdir -p "$MACOS" "$RESOURCES"

cp "$BIN_PATH" "$MACOS/Supervoxtral"
chmod +x "$MACOS/Supervoxtral"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>Supervoxtral</string>
  <key>CFBundleExecutable</key>
  <string>Supervoxtral</string>
  <key>CFBundleIdentifier</key>
  <string>com.supervoxtral.dictation</string>
  <key>CFBundleName</key>
  <string>Supervoxtral</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Supervoxtral needs microphone access for realtime dictation.</string>
</dict>
</plist>
PLIST

cp "$ROOT_DIR/config/settings.json" "$RESOURCES/settings.default.json"
cp "$ROOT_DIR/assets/AppIcon.icns" "$RESOURCES/AppIcon.icns"

MLX_METALLIB_PATH="$(find_mlx_metallib || true)"
if [[ -z "$MLX_METALLIB_PATH" ]]; then
  echo "[supervoxtral] ERROR: Could not locate mlx.metallib."
  echo "[supervoxtral] Provide it via SUPERVOXTRAL_MLX_METALLIB=/path/to/mlx.metallib"
  echo "[supervoxtral] or install mlx in the project environment (for example: uv add mlx)."
  exit 1
fi

cp "$MLX_METALLIB_PATH" "$MACOS/mlx.metallib"
cp "$MLX_METALLIB_PATH" "$MACOS/default.metallib"
cp "$MLX_METALLIB_PATH" "$RESOURCES/default.metallib"
echo "[supervoxtral] Bundled Metal library: $MLX_METALLIB_PATH"

codesign --force --deep --sign - "$APP_PATH" >/dev/null 2>&1 || true

echo "[supervoxtral] App bundle built: $APP_PATH"
echo "[supervoxtral] Version: ${APP_VERSION} (build ${BUILD_NUMBER})"
echo "[supervoxtral] Launch with: open \"$APP_PATH\""
