# AGENTS.md

Operational guide for working on `Supervoxtral`

## Project snapshot

- Native macOS menubar STT app (Swift/AppKit).
- Model/runtime: MLX + Voxtral Mini Realtime 8bit (`ellamind/Voxtral-Mini-4B-Realtime-8bit-mlx`).
- Trigger hotkey default: `right_cmd`.
- Streaming design: incremental audio encode + decoder KV cache (no full re-decode loop).

## Key paths

- App bundle output: `dist/Supervoxtral.app`
- Default settings template: `config/settings.json`
- User runtime settings: `~/Library/Application Support/Supervoxtral/settings.json`
- App log: `~/Library/Logs/Supervoxtral/app.log`
- Crash reports: `~/Library/Logs/DiagnosticReports/Supervoxtral-*.ips`
- Model cache: `~/Library/Caches/supervoxtral/ellamind_Voxtral-Mini-4B-Realtime-8bit-mlx`

## Daily commands

### Build / run

```bash
swift run --disable-sandbox supervoxtral
```

```bash
./scripts/build_app.sh
open dist/Supervoxtral.app
```

```bash
./scripts/build_dmg.sh
open dist/Supervoxtral-$(cat VERSION).dmg
```

### Restart + live logs

```bash
pkill -f Supervoxtral || true
rm -f ~/Library/Logs/Supervoxtral/app.log
open dist/Supervoxtral.app
sleep 3
tail -n 200 -f ~/Library/Logs/Supervoxtral/app.log
```

### Integration test (long streaming stability with soundfile fixture)

```bash
uv run python tests/integration_streaming_soundfile.py
```

### GPU smoke test

```bash
.build/arm64-apple-macosx/release
SUPERVOXTRAL_SMOKE_DEVICE=gpu ./voxtral-smoke
```

## Settings that matter most

Current recommended realtime defaults:

- `hotkey`: `right_cmd`
- `decodeIntervalMs`: `40`
- `minSamplesForDecode`: `1280` (critical for responsiveness/stability)
- `language`: `auto` (mixed EN/DE)
- `temperature`: `0`
- `maxTokens`: `512`
- `transcriptionDelayMs`: `480`
- `mlxDevice`: `gpu`
- `contentBias`: `[]`
- `contentBiasStrength`: `5.0`
- `contentBiasFirstTokenFactor`: `0.2`
- `transcriptPrefix`: `""`
- `transcriptSuffix`: `""`

Notes:

- Settings hot-reload is enabled (~2s polling).
- `modelId`, `hfToken`, `mlxDevice` trigger model/runtime reload.
- `temperature`, `maxTokens`, `language`, `transcriptionDelayMs` rebuild the streaming session.

## Known gotchas

1. **`mlx.metallib` must be bundled**
- If missing, model init can hang/fail on Metal shader loading.
- Always use `./scripts/build_app.sh` to produce the `.app` with bundled metallib.

2. **Permissions**
- Microphone permission should popup on app launch/use.
- Text injection requires Accessibility permission (Privacy & Security -> Accessibility).

3. **First run looks idle while downloading**
- Initial model fetch is multi-GB and can take time.
- Watch `~/Library/Logs/Supervoxtral/app.log` for `Loading model` / `Model ready`.

4. **Streaming appears to stop**
- Check logs for: `Streaming guard: no transcript output ... resetting session`.
- This guard was added to auto-recover from prolonged no-output windows.

5. **Throughput regressions**
- If realtime feels clunky, first check `minSamplesForDecode` is not large (`6400` is too coarse for low-latency streaming).
- Prefer token-aligned decode batches (the controller now enforces this).

6. **SwiftPM shim errors (`_NumericsShims`, etc.)**
- The build script auto-cleans and retries once.
- Manual fallback:

```bash
swift package clean
rm -rf .build
swift build --disable-sandbox -c release
```

## Useful diagnostics

### Check recent crash files

```bash
ls -1t ~/Library/Logs/DiagnosticReports/Supervoxtral-*.ips | head -n 5
```

### Check process exists

```bash
pgrep -fal Supervoxtral
```

### Verify model cache files exist

```bash
ls -lah ~/Library/Caches/supervoxtral/ellamind_Voxtral-Mini-4B-Realtime-8bit-mlx
```
