#!/usr/bin/env python3
"""Manual integration test for long streaming stability.

This test synthesizes a long speech fixture (macOS `say`), normalizes it with
soundfile, then runs the Swift streaming pipeline on GPU and checks for dropout.

Usage:
  uv run python tests/integration_streaming_soundfile.py
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf

ROOT = Path(".")
MODEL_DIR = Path.home() / "Library/Caches/supervoxtral/ellamind_Voxtral-Mini-4B-Realtime-8bit-mlx"

TEXT = (
    "Test test test one two three. "
    "Das geht super schnell und wir testen, ob das Streaming stabil bleibt. "
    "Can you understand English and German continuously without interruptions? "
    "Wir sprechen weiter und weiter, damit der Stream nicht zu frueh abbricht. "
    "This sentence is repeated to make the audio long enough for a stress test. "
) * 8


def run(
    cmd: list[str], *, cwd: Path | None = None, env: dict[str, str] | None = None
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, cwd=cwd, env=env, check=True, text=True, capture_output=True)


def build_fixture(tmp: Path) -> Path:
    aiff = tmp / "fixture.aiff"
    wav = tmp / "fixture.wav"

    run(["say", "-v", "Samantha", "-o", str(aiff), TEXT])

    audio, sr = sf.read(aiff, dtype="float32", always_2d=True)
    mono = audio.mean(axis=1)

    target_sr = 16000
    if sr != target_sr:
        duration = len(mono) / float(sr)
        out_n = max(1, int(duration * target_sr))
        idx = np.linspace(0, len(mono) - 1, out_n, dtype=np.float64)
        lo = np.floor(idx).astype(np.int64)
        hi = np.minimum(lo + 1, len(mono) - 1)
        frac = idx - lo
        mono = (mono[lo] * (1 - frac) + mono[hi] * frac).astype(np.float32)

    sf.write(wav, mono, target_sr)
    return wav


def ensure_metallib_near_binary() -> None:
    rel = ROOT / ".build/arm64-apple-macosx/release"
    rel.mkdir(parents=True, exist_ok=True)

    candidates = []
    explicit = os.environ.get("SUPERVOXTRAL_MLX_METALLIB", "").strip()
    if explicit:
        candidates.append(Path(explicit))

    candidates.extend(
        [
            ROOT.parent / ".venv/lib/python3.12/site-packages/mlx/lib/mlx.metallib",
            ROOT / ".venv/lib/python3.12/site-packages/mlx/lib/mlx.metallib",
            Path.home() / ".venv/lib/python3.12/site-packages/mlx/lib/mlx.metallib",
        ]
    )

    try:
        import mlx.core as core

        candidates.append(Path(core.__file__).resolve().parent / "lib" / "mlx.metallib")
    except Exception:
        pass

    src = next((c for c in candidates if c.exists()), None)
    if src is None:
        raise SystemExit("mlx.metallib not found. Set SUPERVOXTRAL_MLX_METALLIB=/path/to/mlx.metallib")

    for name in ("mlx.metallib", "default.metallib"):
        dst = rel / name
        if not dst.exists():
            dst.write_bytes(src.read_bytes())


def main() -> int:
    print("[integration] Building release binary...")
    run(["swift", "build", "--disable-sandbox", "-c", "release"], cwd=ROOT)
    ensure_metallib_near_binary()

    with tempfile.TemporaryDirectory(prefix="sv2-stream-") as t:
        tmp = Path(t)
        wav = build_fixture(tmp)

        cmd = [
            str(ROOT / ".build/arm64-apple-macosx/release/voxtral-stream-file"),
            "--audio",
            str(wav),
            "--device",
            "gpu",
            "--language",
            "auto",
            "--max-tokens",
            "4096",
            "--temperature",
            "0",
            "--delay-ms",
            "480",
            "--ingest-samples",
            "640",
        ]
        env = os.environ.copy()
        env["SUPERVOXTRAL_MODEL_DIR"] = str(MODEL_DIR)

        print("[integration] Running streaming fixture on GPU...")
        proc = run(cmd, env=env)
        out = proc.stdout
        print(out)

    m = re.search(r"SUMMARY chars=(\d+) deltas=(\d+) max_gap_chunks=(\d+)", out)
    if not m:
        print("[integration] ERROR: summary not found", file=sys.stderr)
        return 2

    chars = int(m.group(1))
    deltas = int(m.group(2))
    max_gap = int(m.group(3))

    result = {
        "chars": chars,
        "deltas": deltas,
        "max_gap_chunks": max_gap,
    }
    print("[integration] Parsed:", json.dumps(result, indent=2))

    # Conservative thresholds for dropout detection.
    if chars < 120:
        print("[integration] FAIL: too little decoded text", file=sys.stderr)
        return 3
    if deltas < 20:
        print("[integration] FAIL: too few streaming deltas", file=sys.stderr)
        return 4
    if max_gap > 260:
        print("[integration] FAIL: long output gap indicates streaming stall", file=sys.stderr)
        return 5

    print("[integration] PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
