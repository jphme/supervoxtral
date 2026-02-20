#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v gh >/dev/null 2>&1; then
  echo "[supervoxtral] ERROR: gh CLI is required (https://cli.github.com/)"
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "[supervoxtral] ERROR: gh is not authenticated. Run: gh auth login"
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 vX.Y.Z [--draft]"
  exit 1
fi

TAG="$1"
shift || true

if [[ "$TAG" != v* ]]; then
  echo "[supervoxtral] ERROR: tag must start with 'v' (example: v0.2.0)"
  exit 1
fi

DRAFT_FLAG=false
if [[ "${1:-}" == "--draft" ]]; then
  DRAFT_FLAG=true
fi

VERSION="${TAG#v}"

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "[supervoxtral] ERROR: working tree is dirty. Commit or stash changes first."
  exit 1
fi

if ! git rev-parse "$TAG" >/dev/null 2>&1; then
  git tag "$TAG"
fi

git push origin HEAD
git push origin "$TAG"

SUPERVOXTRAL_VERSION="$VERSION" "$ROOT_DIR/scripts/build_dmg.sh"
DMG_PATH="$ROOT_DIR/dist/Supervoxtral-${VERSION}.dmg"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "[supervoxtral] ERROR: expected release artifact missing: $DMG_PATH"
  exit 1
fi

release_args=(
  --title "Supervoxtral ${VERSION}"
  --generate-notes
)
if [[ "$DRAFT_FLAG" == true ]]; then
  release_args+=(--draft)
fi

gh release create "$TAG" "$DMG_PATH" "${release_args[@]}"

echo "[supervoxtral] Release published: $TAG"
