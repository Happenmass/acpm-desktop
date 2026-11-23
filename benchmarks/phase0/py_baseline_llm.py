#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path


def split_think(raw_text: str) -> tuple[str, str, bool]:
    if "<think>" in raw_text and "</think>" in raw_text:
        after_open = raw_text.split("<think>", 1)[1]
        reasoning, content = after_open.split("</think>", 1)
        return reasoning.strip(), content.strip(), True
    if "</think>" in raw_text:
        reasoning, content = raw_text.split("</think>", 1)
        return reasoning.strip(), content.strip(), True
    return "", raw_text.strip(), False


def main() -> None:
    parser = argparse.ArgumentParser(description="Python mlx_lm baseline for Phase 0 4B CoT.")
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--corpus", required=True)
    parser.add_argument("--out-json", required=True)
    parser.add_argument("--max-tokens", type=int, default=512)
    args = parser.parse_args()

    from mlx_lm import generate, load
    from mlx_lm.sample_utils import make_sampler

    corpus = json.loads(Path(args.corpus).read_text(encoding="utf-8"))
    system_prompt = corpus["system_prompt"]
    cases = corpus["cases"]

    t0 = time.perf_counter()
    model, tokenizer = load(args.model_dir)
    load_ms = (time.perf_counter() - t0) * 1000.0

    sampler = make_sampler(temp=0.0)
    results = []

    for item in cases:
        messages = [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": item["input"]},
        ]
        try:
            prompt = tokenizer.apply_chat_template(
                messages, tokenize=False, add_generation_prompt=True, enable_thinking=True
            )
        except TypeError:
            prompt = tokenizer.apply_chat_template(
                messages, tokenize=False, add_generation_prompt=True
            )

        starts_in_think = prompt.rstrip().endswith("<think>")
        t_gen = time.perf_counter()
        generated = generate(
            model,
            tokenizer,
            prompt=prompt,
            max_tokens=args.max_tokens,
            sampler=sampler,
            verbose=False,
        )
        total_ms = (time.perf_counter() - t_gen) * 1000.0

        raw_text = generated
        if starts_in_think and not raw_text.lstrip().startswith("<think>"):
            raw_text = "<think>\n" + raw_text

        reasoning, content, think_closed = split_think(raw_text)
        results.append(
            {
                "id": item["id"],
                "input": item["input"],
                "raw_text": raw_text,
                "reasoning": reasoning,
                "content": content,
                "think_closed": think_closed,
                "total_ms": round(total_ms, 2),
            }
        )

    out_path = Path(args.out_json)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(
        json.dumps(
            {
                "engine": "python-mlx_lm",
                "model_dir": args.model_dir,
                "load_ms": round(load_ms, 2),
                "cases": results,
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
    print(f"Wrote Python LLM baseline ({len(results)} cases) to {out_path}")


if __name__ == "__main__":
    main()
