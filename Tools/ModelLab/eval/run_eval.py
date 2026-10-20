#!/usr/bin/env python3
"""M1 model comparison for Glint.

Usage:
  HF_ENDPOINT=https://hf-mirror.com uv run python eval/run_eval.py --model opus
  HF_ENDPOINT=https://hf-mirror.com uv run python eval/run_eval.py --model m2m100
  HF_ENDPOINT=https://hf-mirror.com uv run python eval/run_eval.py --model qwen
"""

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
CASES_PATH = ROOT / "eval" / "cases.json"
RESULTS_DIR = ROOT / "results"

MODEL_IDS = {
    "opus": "Helsinki-NLP/opus-mt-zh-en",
    "m2m100": "facebook/m2m100_418M",
    "qwen": "mlx-community/Qwen3-4B-Instruct-2507-4bit",
}

SYSTEM_PROMPT = (
    "You are a concise Chinese-to-English translator. "
    "If the input is a word or short phrase, output the most common English equivalent. "
    "If it is a sentence, translate it naturally. "
    "Output only the English result in one line. "
    "Do not explain, do not quote, and do not output Chinese."
)


class OpusMTAdapter:
    def __init__(self, model_id: str) -> None:
        import torch
        from transformers import MarianMTModel, MarianTokenizer

        self.torch = torch
        self.tokenizer = MarianTokenizer.from_pretrained(model_id)
        self.model = MarianMTModel.from_pretrained(model_id).eval()
        self.device = "cpu"

    def translate(self, text: str) -> str:
        batch = self.tokenizer([text], return_tensors="pt", padding=True)
        with self.torch.no_grad():
            generated = self.model.generate(
                **batch,
                max_new_tokens=48,
                num_beams=4,
            )
        return self.tokenizer.batch_decode(generated, skip_special_tokens=True)[0].strip()


class M2M100Adapter:
    def __init__(self, model_id: str) -> None:
        import torch
        from transformers import M2M100ForConditionalGeneration, M2M100Tokenizer

        self.torch = torch
        self.tokenizer = M2M100Tokenizer.from_pretrained(model_id)
        self.tokenizer.src_lang = "zh"
        self.model = M2M100ForConditionalGeneration.from_pretrained(model_id).eval()
        self.device = "cpu"

    def translate(self, text: str) -> str:
        batch = self.tokenizer([text], return_tensors="pt", padding=True)
        with self.torch.no_grad():
            generated = self.model.generate(
                **batch,
                forced_bos_token_id=self.tokenizer.get_lang_id("en"),
                max_new_tokens=48,
                num_beams=4,
            )
        return self.tokenizer.batch_decode(generated, skip_special_tokens=True)[0].strip()


class QwenMLXAdapter:
    def __init__(self, model_id: str, prompt_style: str = "general") -> None:
        from mlx_lm import load

        self.model, self.tokenizer = load(model_id)
        self.prompt_style = prompt_style

    def _prompt(self, text: str) -> str:
        if self.prompt_style == "translation":
            messages = [{
                "role": "user",
                "content": (
                    "将以下文本翻译为英语，注意只需要输出翻译后的结果，"
                    "不要额外解释：\n\n" + text
                ),
            }]
        else:
            messages = [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": text},
            ]
        try:
            return self.tokenizer.apply_chat_template(
                messages,
                tokenize=False,
                add_generation_prompt=True,
                enable_thinking=False,
            )
        except TypeError:
            return self.tokenizer.apply_chat_template(
                messages,
                tokenize=False,
                add_generation_prompt=True,
            )

    def translate(self, text: str) -> str:
        from mlx_lm import generate

        output = generate(
            self.model,
            self.tokenizer,
            prompt=self._prompt(text),
            max_tokens=64,
            verbose=False,
        )
        return output.strip().splitlines()[0].strip()


def make_adapter(name: str, model_id: str | None = None, prompt_style: str = "general"):
    model_id = model_id or MODEL_IDS[name]
    if name == "opus":
        return OpusMTAdapter(model_id), model_id
    if name == "m2m100":
        return M2M100Adapter(model_id), model_id
    if name == "qwen":
        return QwenMLXAdapter(model_id, prompt_style), model_id
    raise ValueError(f"unknown model: {name}")


def rss_mb() -> float:
    return psutil.Process().memory_info().rss / (1024 * 1024)


def percentile(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round((len(ordered) - 1) * p)))
    return ordered[index]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", choices=sorted(MODEL_IDS), required=True)
    parser.add_argument("--model-id", default="")
    parser.add_argument(
        "--prompt-style",
        choices=["general", "translation"],
        default="general",
    )
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--cases", default=str(CASES_PATH))
    parser.add_argument("--output", default="")
    args = parser.parse_args()

    cases = json.loads(Path(args.cases).read_text(encoding="utf-8"))
    cases = [case for case in cases if case["kind"] in {"word", "phrase", "sentence"}]
    if args.limit:
        cases = cases[: args.limit]

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    output_path = Path(args.output) if args.output else RESULTS_DIR / f"{args.model}.json"

    print(f"model={args.model} cases={len(cases)}")
    model_id = args.model_id or MODEL_IDS[args.model]
    print(f"model_id={model_id}")
    print("loading...", flush=True)

    started = time.perf_counter()
    adapter, model_id = make_adapter(args.model, model_id, args.prompt_style)
    load_seconds = time.perf_counter() - started
    gc.collect()
    loaded_rss = rss_mb()

    print("warmup...", flush=True)
    warmup_started = time.perf_counter()
    adapter.translate("你好")
    warmup_seconds = time.perf_counter() - warmup_started
    gc.collect()

    rows = []
    for index, case in enumerate(cases, start=1):
        started = time.perf_counter()
        try:
            output = adapter.translate(case["input"])
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
    peak_rss = rss_mb()
    result = {
        "model": args.model,
        "model_id": model_id,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "case_count": len(rows),
        "load_seconds": round(load_seconds, 2),
        "warmup_seconds": round(warmup_seconds, 2),
        "loaded_rss_mb": round(loaded_rss, 1),
        "peak_rss_mb": round(peak_rss, 1),
        "mean_latency_ms": round(statistics.mean(latencies), 2) if latencies else None,
        "p50_latency_ms": round(percentile(latencies, 0.50), 2),
        "p95_latency_ms": round(percentile(latencies, 0.95), 2),
        "rows": rows,
    }
    output_path.write_text(
        json.dumps(result, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(
        f"saved {output_path} | load={load_seconds:.2f}s "
        f"p50={result['p50_latency_ms']}ms p95={result['p95_latency_ms']}ms "
        f"rss={result['peak_rss_mb']}MB"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
