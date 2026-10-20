#!/usr/bin/env python3
"""Benchmark the production CTranslate2 int8 OPUS-MT build."""

from __future__ import annotations

import argparse
import gc
import json
import statistics
import time
from datetime import datetime, timezone
from pathlib import Path

import psutil


ROOT = Path(__file__).resolve().parent.parent
MODEL_DIR = ROOT / "models" / "opus-ct2-int8"
CASES_PATH = ROOT / "eval" / "cases.json"
RESULTS_DIR = ROOT / "results"


def percentile(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round((len(ordered) - 1) * p)))
    return ordered[index]


def rss_mb() -> float:
    return psutil.Process().memory_info().rss / (1024 * 1024)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=0)
    args = parser.parse_args()

    import ctranslate2
    from transformers import MarianTokenizer

    cases = json.loads(CASES_PATH.read_text(encoding="utf-8"))
    cases = [case for case in cases if case["kind"] in {"word", "phrase", "sentence"}]
    if args.limit:
        cases = cases[: args.limit]

    print("loading tokenizer and CTranslate2 model...", flush=True)
    started = time.perf_counter()
    tokenizer = MarianTokenizer.from_pretrained(
        "Helsinki-NLP/opus-mt-zh-en",
        local_files_only=True,
    )
    translator = ctranslate2.Translator(
        str(MODEL_DIR),
        device="cpu",
        compute_type="int8",
    )
    load_seconds = time.perf_counter() - started
    gc.collect()

    def translate(text: str) -> str:
        # OPUS-MT expects the source EOS token. The Hugging Face tokenizer adds
        # it in encode(), but tokenize() alone does not.
        tokens = tokenizer.tokenize(text) + [tokenizer.eos_token]
        result = translator.translate_batch(
            [tokens],
            beam_size=4,
            max_decoding_length=48,
            max_batch_size=1,
        )[0]
        return tokenizer.convert_tokens_to_string(result.hypotheses[0]).strip()

    print("warmup...", flush=True)
    started = time.perf_counter()
    translate("你好")
    warmup_seconds = time.perf_counter() - started

    rows = []
    for index, case in enumerate(cases, start=1):
        started = time.perf_counter()
        try:
            output = translate(case["input"])
            error = None
        except Exception as exc:
            output = ""
            error = f"{type(exc).__name__}: {exc}"
        elapsed_ms = (time.perf_counter() - started) * 1000
        rows.append(
            {
                "id": case["id"],
                "input": case["input"],
                "kind": case["kind"],
                "reference": case["reference"],
                "output": output,
                "latency_ms": round(elapsed_ms, 2),
                "error": error,
            }
        )
        print(
            f"[{index:02d}/{len(cases)}] {case['input']} -> {output or '<error>'} "
            f"({elapsed_ms:.1f}ms)",
            flush=True,
        )

    latencies = [row["latency_ms"] for row in rows if row["error"] is None]
    result = {
        "model": "opus-ct2-int8",
        "model_id": "Helsinki-NLP/opus-mt-zh-en / CTranslate2 int8",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "case_count": len(rows),
        "load_seconds": round(load_seconds, 2),
        "warmup_seconds": round(warmup_seconds, 2),
        "model_size_mb": round(
            sum(path.stat().st_size for path in MODEL_DIR.rglob("*") if path.is_file())
            / (1024 * 1024),
            1,
        ),
        "peak_rss_mb": round(rss_mb(), 1),
        "mean_latency_ms": round(statistics.mean(latencies), 2) if latencies else None,
        "p50_latency_ms": round(percentile(latencies, 0.50), 2),
        "p95_latency_ms": round(percentile(latencies, 0.95), 2),
        "rows": rows,
    }
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    output_path = RESULTS_DIR / "opus-ct2.json"
    output_path.write_text(
        json.dumps(result, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(
        f"saved {output_path} | model={result['model_size_mb']}MB "
        f"load={load_seconds:.2f}s p50={result['p50_latency_ms']}ms "
        f"p95={result['p95_latency_ms']}ms rss={result['peak_rss_mb']}MB"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
