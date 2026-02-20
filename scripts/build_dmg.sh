#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

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

VERSION="$(read_version)"
APP_PATH="$ROOT_DIR/dist/Supervoxtral.app"
DMG_PATH="$ROOT_DIR/dist/Supervoxtral-${VERSION}.dmg"
VOLUME_NAME="Supervoxtral ${VERSION}"

"$ROOT_DIR/scripts/build_app.sh"

if [[ ! -d "$APP_PATH" ]]; then
  echo "[supervoxtral] ERROR: app bundle missing at $APP_PATH"
  exit 1
fi

STAGING_DIR="$(mktemp -d -t supervoxtral-dmg.XXXXXX)"
trap 'rm -rf "$STAGING_DIR"' EXIT

cp -R "$APP_PATH" "$STAGING_DIR/Supervoxtral.app"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  -ov \
  "$DMG_PATH" >/dev/null

echo "[supervoxtral] DMG built: $DMG_PATH"
