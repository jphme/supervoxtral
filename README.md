# Supervoxtral

Native macOS menubar realtime dictation app using MLX + Voxtral Mini Realtime 8bit.

## Highlights

- Native menubar app with clear status states: loading, ready, listening, error.
- Real Preferences UI (no manual JSON editing required for normal use).
- Live model status with a visual download indicator.
- Model cache path surfaced directly in the menu and Preferences.
- Streaming inference pipeline (incremental encoder + decoder KV cache).
- `content_bias` support via local trie-based logit boosting.
- Optional transcript prefix/suffix framing for AI prompt wrappers.

## Requirements

- macOS 14+
- Apple Silicon recommended
- Swift toolchain (Xcode or command line tools)
- Optional: `HF_TOKEN` for gated/private models

## Run From Source

```bash
swift run --disable-sandbox supervoxtral
```

## Build App Bundle

```bash
./scripts/build_app.sh
open dist/Supervoxtral.app
```

Packaging note: `build_app.sh` bundles `mlx.metallib` and expects Python `mlx==0.30.3` (matching `mlx-swift` in this repo).

## Build Installable DMG

```bash
./scripts/build_dmg.sh
open dist/Supervoxtral-$(cat VERSION).dmg
```

`build_dmg.sh` builds `dist/Supervoxtral-<version>.dmg` and includes:
- `Supervoxtral.app`
- `Applications` shortcut for drag-and-drop install

## Settings

Template defaults:
- `config/settings.json`

Runtime settings (user machine, not committed):
- `~/Library/Application Support/Supervoxtral/settings.json`

Lookup order:
1. `SUPERVOXTRAL_SETTINGS`
2. `./config/settings.json`
3. `~/Library/Application Support/Supervoxtral/settings.json`

Key defaults:

```json
{
  "modelId": "ellamind/Voxtral-Mini-4B-Realtime-8bit-mlx",
  "hotkey": "right_cmd",
  "decodeIntervalMs": 40,
  "minSamplesForDecode": 1280,
  "language": "auto",
  "temperature": 0,
  "maxTokens": 512,
  "transcriptionDelayMs": 480,
  "mlxDevice": "gpu",
  "contentBias": [],
  "contentBiasStrength": 5.0,
  "contentBiasFirstTokenFactor": 0.2,
  "transcriptPrefix": "",
  "transcriptSuffix": ""
}
```

### `content_bias`

The local implementation mirrors the Python prototype approach in `docs/content_bias.md`:

- Prefix-trie token matching over configured terms/phrases.
- Continuation token boosting to `max_logit + strength`.
- Mild first-token boost via `contentBiasFirstTokenFactor`.
- EOS guard to avoid unwanted biasing when the model should stop.

Related settings:
- `contentBias`: list of terms/phrases (up to 100)
- `contentBiasStrength`: continuation boost strength (default `5.0`)
- `contentBiasFirstTokenFactor`: first-token fraction (default `0.2`)

Aliases from older configs are supported:
- `contextBias` / `context_bias`
- `contextBiasStrength` / `context_bias_strength`
- `contextBiasFirstTokenFactor` / `context_bias_first_token_factor`

### Transcript Prefix/Suffix

Use:
- `transcriptPrefix`
- `transcriptSuffix`

Behavior:
- Prefix is injected once when dictation starts.
- Streaming transcription is injected in the middle.
- Suffix is injected once when dictation stops.

Useful for wrapping transcription inside XML-like prompt scaffolding before sending text to AI tools.

## Permissions

- Microphone permission is requested on first launch.
- Accessibility permission is required for text injection.

Menu shortcuts:
- `Grant Accessibility`
- `Open Microphone Settings`

## Diagnostics

App log:
- `~/Library/Logs/Supervoxtral/app.log`

Crash reports:
- `~/Library/Logs/DiagnosticReports/Supervoxtral-*.ips`

Model cache:
- `~/Library/Caches/supervoxtral/ellamind_Voxtral-Mini-4B-Realtime-8bit-mlx`

Useful commands:

```bash
pkill -f Supervoxtral || true
rm -f ~/Library/Logs/Supervoxtral/app.log
open dist/Supervoxtral.app
sleep 3
tail -n 200 -f ~/Library/Logs/Supervoxtral/app.log
```

## Tests

Run focused unit tests:

```bash
swift test --disable-sandbox -c debug --filter "(ContentBiasProcessorTests|SettingsTests)"
```

Run integration streaming stress test (requires audio/model environment):

```bash
uv run python tests/integration_streaming_soundfile.py
```

## Maintainer Release Flow

### Local CLI release command

```bash
./scripts/release_github.sh v0.1.0
```

What it does:
- validates clean git state and `gh` auth
- pushes branch + tag
- builds versioned DMG
- creates GitHub release and uploads DMG

Use draft releases:

```bash
./scripts/release_github.sh v0.1.0 --draft
```

### GitHub Actions release workflow

File:
- `.github/workflows/release.yml`

Trigger:
- push tag `v*`

It builds the DMG on macOS and publishes it as a downloadable GitHub Release asset.
