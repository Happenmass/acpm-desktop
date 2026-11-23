#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description="Python mlx_audio ASR baseline for Phase 0.")
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--audio", action="append", default=[])
    parser.add_argument("--swift-report", default=None)
    parser.add_argument("--out-json", required=True)
    args = parser.parse_args()

    audio_items: list[tuple[str, str]] = [
        (f"audio_{idx + 1}", p) for idx, p in enumerate(args.audio)
    ]
    if args.swift_report and Path(args.swift_report).is_file():
        swift = json.loads(Path(args.swift_report).read_text(encoding="utf-8"))
        for run in swift.get("asr", {}).get("runs", []):
            path = run.get("audio_path")
            label = run.get("label", Path(path).stem if path else "clip")
            if path and all(existing != path for _, existing in audio_items):
                audio_items.append((label, path))

    payload: dict = {
        "engine": "python-mlx_audio",
        "model_dir": args.model_dir,
        "available": False,
        "error": None,
        "runs": [],
    }

    try:
        from mlx_audio.stt.utils import load_model

        t0 = time.perf_counter()
        model = load_model(args.model_dir)
        payload["load_ms"] = round((time.perf_counter() - t0) * 1000.0, 2)
        payload["available"] = True

        for label, audio_path in audio_items:
            t_run = time.perf_counter()
            result = model.generate(audio_path)
            decode_ms = (time.perf_counter() - t_run) * 1000.0
            text = getattr(result, "text", None)
            if text is None and isinstance(result, dict):
                text = result.get("text", "")
            elif text is None:
                text = str(result)
            payload["runs"].append(
                {
                    "label": label,
                    "audio_path": audio_path,
                    "text": str(text).strip(),
                    "language": getattr(result, "language", None),
                    "decode_ms": round(decode_ms, 2),
                }
            )
    except Exception as exc:
        payload["error"] = f"{type(exc).__name__}: {exc}"

    out_path = Path(args.out_json)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Wrote Python ASR baseline (available={payload['available']}) to {out_path}")


if __name__ == "__main__":
    main()
