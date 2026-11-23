#!/usr/bin/env python3
from __future__ import annotations

import argparse
import difflib
import json
import re
import statistics
import wave
from pathlib import Path


def normalize_for_similarity(text: str) -> str:
    # Remove whitespace and common Chinese/ASCII punctuation to compare semantic content
    return re.sub(r"[\s，。！？、；：“”‘’\"',.!?;:()（）《》【】\-—]+", "", text).lower()


def seq_ratio(a: str, b: str) -> float:
    return difflib.SequenceMatcher(None, a, b).ratio()


def inspect_wav(path: str) -> dict:
    with wave.open(path, "rb") as wf:
        frames = wf.getnframes()
        rate = wf.getframerate()
        channels = wf.getnchannels()
        sampwidth = wf.getsampwidth()
        duration_ms = round((frames / max(1, rate)) * 1000.0, 1)
        return {
            "sample_rate": rate,
            "channels": channels,
            "bits_per_sample": sampwidth * 8,
            "duration_ms": duration_ms,
            "bytes": Path(path).stat().st_size,
        }


def main() -> None:
    parser = argparse.ArgumentParser(description="Aggregate and compare Phase 0 benchmark results.")
    parser.add_argument("--swift-report", required=True)
    parser.add_argument("--py-llm", default=None)
    parser.add_argument("--py-asr", default=None)
    parser.add_argument("--exit-reclaim", default=None)
    parser.add_argument("--out-json", required=True)
    args = parser.parse_args()

    swift = json.loads(Path(args.swift_report).read_text(encoding="utf-8"))
    py_llm = (
        json.loads(Path(args.py_llm).read_text(encoding="utf-8"))
        if args.py_llm and Path(args.py_llm).is_file()
        else None
    )
    py_asr = (
        json.loads(Path(args.py_asr).read_text(encoding="utf-8"))
        if args.py_asr and Path(args.py_asr).is_file()
        else None
    )
    exit_reclaim = (
        json.loads(Path(args.exit_reclaim).read_text(encoding="utf-8"))
        if args.exit_reclaim and Path(args.exit_reclaim).is_file()
        else None
    )

    summary: dict = {"items": {}}

    # Item 1 & Item 2: LLM CoT + KV prefix cache
    if "llm" in swift:
        llm = swift["llm"]
        cold_cases = llm.get("cold_cases", [])
        closed_count = sum(1 for c in cold_cases if c.get("think_closed"))
        cold_ttfts = [c["ttft_ms"] for c in cold_cases if "ttft_ms" in c]

        py_map = {}
        if py_llm:
            py_map = {c["id"]: c for c in py_llm.get("cases", [])}

        comparisons = []
        exact_raw_matches = 0
        exact_content_matches = 0
        norm_content_ratios = []

        for c in cold_cases:
            cid = c["id"]
            if cid in py_map:
                pc = py_map[cid]
                raw_eq = c.get("raw_text", "").strip() == pc.get("raw_text", "").strip()
                content_eq = c.get("content", "").strip() == pc.get("content", "").strip()
                ratio = seq_ratio(
                    normalize_for_similarity(c.get("content", "")),
                    normalize_for_similarity(pc.get("content", "")),
                )
                if raw_eq:
                    exact_raw_matches += 1
                if content_eq:
                    exact_content_matches += 1
                norm_content_ratios.append(ratio)
                comparisons.append(
                    {
                        "id": cid,
                        "swift_content": c.get("content", ""),
                        "python_content": pc.get("content", ""),
                        "content_exact_match": content_eq,
                        "content_similarity": round(ratio, 4),
                    }
                )

        kv_runs = llm.get("kv_prefix_cache_runs", [])
        kv_hits = [r for r in kv_runs if r.get("kv_cache_hit")]
        hit_ttfts = [r["ttft_ms"] for r in kv_hits]
        cold_by_id = {c["id"]: c for c in cold_cases}
        kv_content_matches = sum(
            1
            for r in kv_hits
            if r.get("content", "").strip() == cold_by_id.get(r["id"], {}).get("content", "").strip()
        )
        median_cold_ttft = round(statistics.median(cold_ttfts), 2) if cold_ttfts else 0.0
        median_hit_ttft = round(statistics.median(hit_ttfts), 2) if hit_ttfts else 0.0

        summary["items"]["1_llm_cot_alignment"] = {
            "total_cases": len(cold_cases),
            "think_closed_count": closed_count,
            "think_closure_rate": round(closed_count / max(1, len(cold_cases)), 4),
            "python_compared_count": len(comparisons),
            "exact_raw_matches": exact_raw_matches,
            "exact_content_matches": exact_content_matches,
            "mean_content_similarity": round(statistics.mean(norm_content_ratios), 4)
            if norm_content_ratios
            else None,
            "comparisons": comparisons,
        }
        summary["items"]["2_kv_prefix_cache"] = {
            "cold_ttft_median_ms": median_cold_ttft,
            "warm_hit_ttft_median_ms": median_hit_ttft,
            "ttft_speedup_ratio": round(median_cold_ttft / max(0.01, median_hit_ttft), 2)
            if hit_ttfts
            else None,
            "warm_hits_count": len(kv_hits),
            "warm_vs_cold_exact_content_matches": kv_content_matches,
            "runs": [
                {
                    "run_index": r.get("run_index"),
                    "id": r.get("id"),
                    "kv_cache_hit": r.get("kv_cache_hit"),
                    "ttft_ms": round(r.get("ttft_ms", 0.0), 2),
                }
                for r in kv_runs
            ],
        }

    # Item 3: ASR alignment
    if "asr" in swift:
        asr = swift["asr"]
        py_asr_map = {}
        if py_asr and py_asr.get("available"):
            py_asr_map = {r["label"]: r for r in py_asr.get("runs", [])}

        asr_details = []
        py_sims = []
        roundtrip_sims = []
        for r in asr.get("runs", []):
            label = r.get("label")
            item = {
                "label": label,
                "swift_text": r.get("text", ""),
                "language": r.get("language"),
                "duration_ms": r.get("duration_ms"),
                "decode_ms": round(r.get("decode_ms", 0.0), 2),
            }
            if r.get("expected_text"):
                rt_sim = seq_ratio(
                    normalize_for_similarity(r.get("text", "")),
                    normalize_for_similarity(r["expected_text"]),
                )
                item["expected_text"] = r["expected_text"]
                item["tts_roundtrip_similarity"] = round(rt_sim, 4)
                roundtrip_sims.append(rt_sim)
            if label in py_asr_map:
                pr = py_asr_map[label]
                psim = seq_ratio(
                    normalize_for_similarity(r.get("text", "")),
                    normalize_for_similarity(pr.get("text", "")),
                )
                item["python_text"] = pr.get("text", "")
                item["python_decode_ms"] = pr.get("decode_ms")
                item["swift_vs_python_similarity"] = round(psim, 4)
                py_sims.append(psim)
            asr_details.append(item)

        summary["items"]["3_asr_alignment"] = {
            "python_available": bool(py_asr and py_asr.get("available")),
            "python_error": py_asr.get("error") if py_asr else "not_run",
            "mean_swift_vs_python_similarity": round(statistics.mean(py_sims), 4) if py_sims else None,
            "mean_tts_roundtrip_similarity": round(statistics.mean(roundtrip_sims), 4)
            if roundtrip_sims
            else None,
            "runs": asr_details,
        }

    # Item 4: TTS cloning & cache
    if "tts" in swift:
        tts_runs = swift["tts"].get("runs", [])
        wav_checks = []
        for r in tts_runs:
            info = inspect_wav(r["output_path"])
            wav_checks.append(
                {
                    "index": r["index"],
                    "voice_cache_hit": r["voice_cache_hit"],
                    "voice_encode_ms": round(r["voice_encode_ms"], 2),
                    "decode_ms": round(r["decode_ms"], 2),
                    "wav": info,
                }
            )
        summary["items"]["4_tts_cloning_and_cache"] = {
            "total_utterances": len(wav_checks),
            "first_voice_encode_ms": wav_checks[0]["voice_encode_ms"] if wav_checks else None,
            "cached_hits_2_to_5": sum(1 for w in wav_checks[1:] if w["voice_cache_hit"]),
            "cached_voice_encode_ms": [w["voice_encode_ms"] for w in wav_checks[1:]],
            "all_24khz_mono_pcm16": all(
                w["wav"]["sample_rate"] == 24000
                and w["wav"]["channels"] == 1
                and w["wav"]["bits_per_sample"] == 16
                for w in wav_checks
            ),
            "runs": wav_checks,
        }

    # Item 5: Memory footprints
    footprints = {}
    for key in ("llm", "asr", "tts"):
        if key in swift:
            section = swift[key]
            footprints[key] = {
                "load_ms": round(section.get("load_ms", 0.0), 2),
                "pre_load_unified_mb": section.get("pre_load_unified_mb"),
                "warm_unified_mb": section.get("warm_unified_mb"),
                "running_peak_unified_mb": section.get("running_peak_unified_mb"),
                "delta_warm_mb": section.get("delta_warm_mb"),
                "delta_peak_mb": section.get("delta_peak_mb"),
            }
    summary["items"]["5_phys_footprint"] = footprints

    # Item 6: Subprocess exit reclamation
    if exit_reclaim is not None:
        summary["items"]["6_exit_reclamation"] = exit_reclaim

    out_path = Path(args.out_json)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
