# Supervoxtral

Native macOS menubar realtime dictation app using Voxtral Mini Realtime 8bit on Apple Silicon.

## Why this stack

- **Swift + AppKit** for native menubar UX, macOS permissions, global hotkeys, and `.app` packaging.
- **MLX (swift)** for native Apple-accelerated inference.
- **Voxtral realtime model code vendored from `mlx-audio-swift`** (target: `VoxtralRuntime`) to keep the app self-contained and avoid a Python runtime.

## Language decision (macOS focus)

- **Chosen: Swift**
  - First-class macOS app model (`NSApplication`, status bar, permissions APIs, global hotkeys).
  - Direct access to Apple's MLX Swift runtime for Apple Silicon acceleration.
  - Clean `.app` packaging with `Info.plist` and ad-hoc signing for local install.
- **Not chosen: Go (for this app)**
  - Go can do menu apps, but MLX inference integration is not a first-class path.
  - Would require bridge layers to Swift/C++ for MLX model execution.
- **Not chosen: Rust (for this app)**
  - Great systems language, but macOS desktop + MLX integration would still require heavy FFI/UI glue.
  - Higher complexity than Swift for a native macOS STT product.

Reference links:
- [mlx-audio (Python)](https://github.com/Blaizzy/mlx-audio)
- [MLX](https://github.com/ml-explore/mlx)
- [Voxtral Mini Realtime 8bit model](https://huggingface.co/ellamind/Voxtral-Mini-4B-Realtime-8bit-mlx)

## Features (v1)

- Menubar status indicator with persistent icon states (loading / ready / listening / error)
- Global hotkey to toggle dictation (default `right_cmd`)
- Realtime mic capture at 16 kHz
- Incremental text injection at current cursor position
- Streaming inference pipeline (incremental mel + incremental encoder + cached decoder)
- Model download and cache through Hugging Face Swift client
- Settings file based configuration
- Settings hot-reload (polls file changes and applies without app restart)

## Requirements

- macOS 14+
- Apple Silicon Mac recommended
- Xcode/Swift toolchain available
- `HF_TOKEN` environment variable for gated model access (if needed)

## Run from source

```bash
swift run --disable-sandbox supervoxtral
```

## Build app bundle

```bash
./scripts/build_app.sh
open dist/Supervoxtral.app
```

## Settings

Default settings are in:

- `config/settings.json`

Runtime lookup order:

1. `SUPERVOXTRAL_SETTINGS`
2. `./config/settings.json` (current working directory)
3. `~/Library/Application Support/Supervoxtral/settings.json`

Example:

```json
{
  "hfToken": null,
  "modelId": "ellamind/Voxtral-Mini-4B-Realtime-8bit-mlx",
  "hotkey": "right_cmd",
  "decodeIntervalMs": 40,
  "contextWindowSeconds": 18,
  "minSamplesForDecode": 1280,
  "temperature": 0,
  "maxTokens": 512,
  "language": "auto",
  "transcriptionDelayMs": 480,
  "mlxDevice": "gpu"
}
```

Set `"hfToken"` only if your selected model requires authentication.

Setting details:
- `modelId`: Hugging Face repo id for the MLX Voxtral realtime model.
- `hfToken`: optional token for gated/private models.
- `hotkey`: `right_cmd` (recommended) or combo format like `ctrl+alt+cmd+space`.
- `mlxDevice`: `gpu` (Apple Silicon Metal) or `cpu`.
- `decodeIntervalMs`: tick interval for streaming decode/injection loop.
- `maxTokens`: max generated tokens per utterance before forced stop.
- `temperature`: `0` for deterministic greedy decode; higher values increase variability.
- `language`: `auto` (recommended for mixed EN/DE), or fixed tag such as `en` / `de`.
- `transcriptionDelayMs`: streaming delay trade-off; higher values usually improve punctuation/word boundary stability at the cost of latency.
- `contextWindowSeconds`: legacy compatibility field; retained in config format.
- `minSamplesForDecode`: minimum audio batch size (samples at 16kHz) before a decode pass. `1280` is 80ms and is the realtime-recommended default.

Hot-reload behavior:
- Saving `settings.json` while the app is running applies changes automatically (within ~2s).
- `hotkey` and `decodeIntervalMs` apply immediately.
- `temperature`, `maxTokens`, `language`, `transcriptionDelayMs` rebuild the streaming session.
- `modelId`, `hfToken`, `mlxDevice` trigger model/runtime reload.

## macOS permissions

- **Microphone**: requested by the app on launch.
- **Accessibility**: required for text injection at cursor position.
  - Trigger prompt via menubar: `Grant Accessibility`.

## Notes

- This implementation is append-only for realtime cursor injection (it does not backspace previously typed text).
- First model download can be several GB and takes time.
- The app log is written to `~/Library/Logs/Supervoxtral/app.log` with operational events only.

## Engineering Learnings

- **Bundle MLX shaders in the app**: On machines with Command Line Tools only (without full Xcode Metal toolchain), MLX can fail to locate `default.metallib` at runtime. The build script now bundles `mlx.metallib` into the app and startup validates it before model load.
- **Use true streaming, not periodic full-window re-decode**: Full context re-decode each timer tick causes latency spikes and clunky UX. Incremental `encode_step` + decoder KV cache yields stable realtime behavior.
- **Precompute static tensors and warm up kernels**: Prompt/text conditioning tensors are computed once per model load, and a warmup pass compiles hot kernels before the first live dictation.
- **Bound long-running cache growth**: Encoder attention uses sliding-window cache behavior so long sessions do not degrade over time.
- **Force graph materialization after concat/slice**: MLX is lazy; repeated concatenation without `eval()` creates large deferred graphs and eventual slowdown. Streaming path explicitly materializes these steps.
- **Batch controller decode on token boundaries**: Running decode on sub-token audio slices increases overhead and can cause visible stalls. Controller now batches at token-aligned sample counts (`1280` minimum) for stable realtime throughput.
