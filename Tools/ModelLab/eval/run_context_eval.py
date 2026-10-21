#!/usr/bin/env python3
"""Evaluate bounded context for model-first translation."""

from __future__ import annotations

import argparse
import gc
import json
import re
import statistics
import time
import unicodedata
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import psutil


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CASES_PATH = ROOT / "eval" / "context_cases.json"
RESULTS_DIR = ROOT / "results"
DEFAULT_MODEL_ID = "mlx-community/Hy-MT2-1.8B-4bit"

VARIANTS = {
    "m0": (0, 0),
    "m1": (24, 0),
    "m2": (24, 8),
    "m3": (48, 8),
}

VALID_KINDS = {"word", "phrase", "sentence"}
VALID_CATEGORIES = {"polysemy", "business", "sentence", "control"}
NO_CONTEXT_PROMPT = (
    "将「{target}」翻译成自然、简洁的英语。"
    "只输出英文翻译，不要解释。"
)
CONTEXT_PROMPT = (
    "下面文本中，方括号里的内容是当前输入焦点。"
    "请结合整句话判断「{target}」在这里的含义，"
    "只翻译方括号里的目标，并用方括号保留目标，"
    "不要翻译或解释括号外内容。\n"
    "文本：{text}\n"
    "只输出方括号中的英文翻译："
)
GENERAL_MODEL_SYSTEM_PROMPT = (
    "You are a Chinese-to-English translation engine for a typing companion. "
    "Follow the user's output constraints exactly. "
    "When a target is marked in brackets, translate only that target using "
    "the sentence as context. Never translate the surrounding sentence. "
    "Output one English line with no Chinese."
)


@dataclass(frozen=True)
class ContextCase:
    id: str
    kind: str
    category: str
    target: str
    before: str
    after: str
    references: tuple[str, ...]
    unacceptable: tuple[str, ...]
    pair_id: str | None


def rss_mb() -> float:
    return psutil.Process().memory_info().rss / (1024 * 1024)


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(
        len(ordered) - 1,
        max(0, round((len(ordered) - 1) * fraction)),
    )
    return ordered[index]


def clip_context(text: str, limit: int, from_end: bool) -> str:
    text = text.strip()
    if limit <= 0 or not text:
        return ""
    selected = text[-limit:] if from_end else text[:limit]
    if from_end:
        while selected and unicodedata.combining(selected[0]):
            prefix_length = len(text) - len(selected) - 1
            if prefix_length < 0:
                break
            selected = text[prefix_length:]
    else:
        while selected and unicodedata.combining(selected[-1]):
            suffix_index = len(selected)
            if suffix_index >= len(text):
                break
            selected = text[: suffix_index + 1]
    return selected


def load_cases(path: Path) -> list[ContextCase]:
    raw_cases = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw_cases, list):
        raise ValueError("context corpus must be a JSON array")

    cases: list[ContextCase] = []
    seen: set[str] = set()
    for index, raw in enumerate(raw_cases):
        if not isinstance(raw, dict):
            raise ValueError(f"case {index} must be an object")
        case_id = raw.get("id")
        kind = raw.get("kind")
        category = raw.get("category")
        target = raw.get("target")
        references = raw.get("references")
        if not isinstance(case_id, str) or not case_id.strip():
            raise ValueError(f"case {index} has an invalid id")
        if case_id in seen:
            raise ValueError(f"duplicate case id: {case_id}")
        seen.add(case_id)
        if kind not in VALID_KINDS:
            raise ValueError(f"{case_id}: invalid kind {kind!r}")
        if category not in VALID_CATEGORIES:
            raise ValueError(f"{case_id}: invalid category {category!r}")
        if not isinstance(target, str) or not target.strip():
            raise ValueError(f"{case_id}: target must be non-empty")
        if not isinstance(references, list) or not references or not all(
            isinstance(value, str) and value.strip()
            for value in references
        ):
            raise ValueError(f"{case_id}: references must be non-empty strings")
        before = raw.get("before", "")
        after = raw.get("after", "")
        if not isinstance(before, str) or not isinstance(after, str):
            raise ValueError(f"{case_id}: context must be strings")
        pair_id = raw.get("pair_id")
        if pair_id is not None and (
            not isinstance(pair_id, str) or not pair_id.strip()
        ):
            raise ValueError(f"{case_id}: pair_id must be a non-empty string")
        unacceptable = raw.get("unacceptable", [])
        if not isinstance(unacceptable, list) or not all(
            isinstance(value, str) for value in unacceptable
        ):
            raise ValueError(f"{case_id}: unacceptable must be strings")
        cases.append(
            ContextCase(
                id=case_id,
                kind=kind,
                category=category,
                target=target.strip(),
                before=before,
                after=after,
                references=tuple(references),
                unacceptable=tuple(unacceptable),
                pair_id=pair_id,
            )
        )

    pair_counts: defaultdict[str, int] = defaultdict(int)
    pair_targets: defaultdict[str, set[str]] = defaultdict(set)
    for case in cases:
        if case.pair_id:
            pair_counts[case.pair_id] += 1
            pair_targets[case.pair_id].add(case.target)
    incomplete_pairs = sorted(
        pair_id
        for pair_id, count in pair_counts.items()
        if count != 2
    )
    if incomplete_pairs:
        raise ValueError(
            "pair_id values must occur exactly twice: "
            + ", ".join(incomplete_pairs)
        )
    mismatched_targets = sorted(
        pair_id
        for pair_id, targets in pair_targets.items()
        if len(targets) != 1
    )
    if mismatched_targets:
        raise ValueError(
            "paired cases must share one target: "
            + ", ".join(mismatched_targets)
        )
    return cases


def build_prompt(case: ContextCase, variant: str) -> str:
    if variant not in VARIANTS:
        raise ValueError(f"unknown variant: {variant}")
    before_limit, after_limit = VARIANTS[variant]
    before = clip_context(case.before, before_limit, from_end=True)
    after = clip_context(case.after, after_limit, from_end=False)
    if not before and not after:
        return NO_CONTEXT_PROMPT.format(target=case.target)
    text = f"{before}【{case.target}】{after}"
    return CONTEXT_PROMPT.format(
        target=case.target,
        text=text,
    )


def system_prompt(model_id: str) -> str | None:
    if "Qwen3" in model_id:
        return GENERAL_MODEL_SYSTEM_PROMPT
    return None


def normalize_translation(text: str) -> str:
    text = unicodedata.normalize("NFKC", text).lower().strip()
    text = re.sub(r"\s+", " ", text)
    return text.rstrip(" .!?。！？")


def contains_han(text: str) -> bool:
    return bool(re.search(r"[\u3400-\u9fff]", text))


def extract_target_output(text: str) -> tuple[str, str]:
    matches = re.findall(r"【([^】]+)】|\[([^\]]+)\]", text)
    if not matches:
        return text.strip(), "direct"
    values = [
        first or second
        for first, second in matches
        if (first or second).strip()
    ]
    if len(values) != 1:
        return text.strip(), "ambiguous_brackets"
    value = values[0].strip()
    if contains_han(value):
        return value, "chinese_only"
    return value, "bracketed"


def score_output(
    output: str,
    case: ContextCase,
) -> tuple[str, str]:
    cleaned = output.strip()
    if not cleaned:
        return "invalid", "empty"
    if contains_han(cleaned):
        return "invalid", "chinese_output"
    if len(cleaned.splitlines()) > 1:
        return "invalid", "multiple_lines"
    target_output, _ = extract_target_output(cleaned)
    normalized = normalize_translation(target_output)
    references = {
        normalize_translation(reference)
        for reference in case.references
    }
    if normalized in references:
        return "acceptable", ""
    unacceptable = {
        normalize_translation(value)
        for value in case.unacceptable
    }
    if normalized in unacceptable:
        return "incorrect", "listed_unacceptable"
    return "incorrect", "not_in_reference_set"


class HyMTAdapter:
    def __init__(self, model_id: str) -> None:
        from mlx_lm import load

        self.model, self.tokenizer = load(model_id)

    def encode(self, text: str) -> list[int]:
        return self.tokenizer.encode(text)

    def translate(
        self,
        prompt: str,
        system: str | None = None,
    ) -> str:
        from mlx_lm import generate

        messages = []
        if system:
            messages.append({"role": "system", "content": system})
        messages.append({"role": "user", "content": prompt})
        try:
            formatted = self.tokenizer.apply_chat_template(
                messages,
                tokenize=False,
                add_generation_prompt=True,
                enable_thinking=False,
            )
        except TypeError:
            formatted = self.tokenizer.apply_chat_template(
                messages,
                tokenize=False,
                add_generation_prompt=True,
            )
        output = generate(
            self.model,
            self.tokenizer,
            prompt=formatted,
            max_tokens=64,
            verbose=False,
        )
        return output.strip()


def summarize(
    rows: list[dict[str, Any]],
    cases: list[ContextCase],
) -> dict[str, Any]:
    by_id = {case.id: case for case in cases}
    variants = list(VARIANTS)
    categories = ["polysemy", "business", "sentence", "control"]
    summary: dict[str, Any] = {}

    for variant in variants:
        variant_rows = [row for row in rows if row["variant"] == variant]
        latencies = [
            row["latency_ms"]
            for row in variant_rows
            if row["status"] != "error"
        ]
        token_counts = [
            row["prompt_tokens"]
            for row in variant_rows
            if row["prompt_tokens"] is not None
        ]
        category_stats = {}
        for category in categories:
            category_rows = [
                row
                for row in variant_rows
                if by_id[row["id"]].category == category
            ]
            acceptable = sum(
                row["status"] == "acceptable"
                for row in category_rows
            )
            category_stats[category] = {
                "acceptable": acceptable,
                "total": len(category_rows),
                "rate": (
                    acceptable / len(category_rows)
                    if category_rows
                    else None
                ),
            }
        acceptable = sum(
            row["status"] == "acceptable" for row in variant_rows
        )
        summary[variant] = {
            "case_count": len(variant_rows),
            "acceptable": acceptable,
            "acceptable_rate": (
                acceptable / len(variant_rows) if variant_rows else None
            ),
            "invalid": sum(
                row["status"] == "invalid" for row in variant_rows
            ),
            "errors": sum(
                row["status"] == "error" for row in variant_rows
            ),
            "p50_latency_ms": round(percentile(latencies, 0.50), 2),
            "p95_latency_ms": round(percentile(latencies, 0.95), 2),
            "p50_prompt_tokens": round(percentile(token_counts, 0.50), 2),
            "p95_prompt_tokens": round(percentile(token_counts, 0.95), 2),
            "categories": category_stats,
            "paired_vs_m0": paired_comparison(variant_rows, rows, by_id),
        }
    return summary


def paired_comparison(
    variant_rows: list[dict[str, Any]],
    all_rows: list[dict[str, Any]],
    by_id: dict[str, ContextCase],
) -> dict[str, int]:
    baseline = {
        row["id"]: row["status"] == "acceptable"
        for row in all_rows
        if row["variant"] == "m0"
    }
    grouped: defaultdict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in variant_rows:
        case = by_id[row["id"]]
        if case.pair_id:
            grouped[case.pair_id].append(row)

    wins = losses = ties = 0
    for pair_rows in grouped.values():
        variant_score = sum(
            row["status"] == "acceptable" for row in pair_rows
        )
        baseline_score = sum(
            baseline.get(row["id"], False) for row in pair_rows
        )
        if variant_score > baseline_score:
            wins += 1
        elif variant_score < baseline_score:
            losses += 1
        else:
            ties += 1
    return {"wins": wins, "losses": losses, "ties": ties}


def render_markdown(
    summary: dict[str, Any],
    model_id: str,
) -> str:
    lines = [
        "# Context Disambiguation Evaluation",
        "",
        f"- Model: `{model_id}`",
        f"- Date: {datetime.now(timezone.utc).isoformat()}",
        "",
        "## Summary",
        "",
        "| Variant | Acceptable | Rate | Invalid | Errors | p50 ms | p95 ms | p50 tokens |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for variant in VARIANTS:
        value = summary[variant]
        lines.append(
            f"| {variant} | {value['acceptable']}/{value['case_count']} | "
            f"{value['acceptable_rate']:.1%} | {value['invalid']} | "
            f"{value['errors']} | {value['p50_latency_ms']} | "
            f"{value['p95_latency_ms']} | {value['p50_prompt_tokens']} |"
        )
    lines.extend(
        [
            "",
            "## Category Accuracy",
            "",
            "| Variant | Polysemy | Business | Sentence | Control |",
            "| --- | ---: | ---: | ---: | ---: |",
        ]
    )
    for variant in VARIANTS:
        categories = summary[variant]["categories"]
        cells = []
        for category in ["polysemy", "business", "sentence", "control"]:
            stats = categories[category]
            cells.append(
                f"{stats['acceptable']}/{stats['total']}"
            )
        lines.append(f"| {variant} | {' | '.join(cells)} |")
    lines.extend(
        [
            "",
            "## Paired Comparison vs m0",
            "",
            "| Variant | Wins | Losses | Ties |",
            "| --- | ---: | ---: | ---: |",
        ]
    )
    for variant in ["m1", "m2", "m3"]:
        paired = summary[variant]["paired_vs_m0"]
        lines.append(
            f"| {variant} | {paired['wins']} | "
            f"{paired['losses']} | {paired['ties']} |"
        )
    lines.append("")
    return "\n".join(lines)


def run(args: argparse.Namespace) -> int:
    cases = load_cases(Path(args.cases))
    if args.category:
        cases = [
            case
            for case in cases
            if case.category == args.category
        ]
    if args.limit:
        cases = cases[: args.limit]
    if args.smoke:
        first_pair = next(
            (case.pair_id for case in cases if case.pair_id),
            None,
        )
        if first_pair:
            cases = [
                case for case in cases if case.pair_id == first_pair
            ]

    print(f"cases={len(cases)} variants={len(VARIANTS)}")
    if args.dry_run:
        for variant in VARIANTS:
            for case in cases:
                build_prompt(case, variant)
        print("dry-run valid")
        return 0

    output_path = (
        Path(args.output)
        if args.output
        else RESULTS_DIR / "context-hy-mt2.json"
    )
    markdown_path = output_path.with_suffix(".md")
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)

    print("loading model...", flush=True)
    started = time.perf_counter()
    adapter = HyMTAdapter(args.model_id)
    load_seconds = time.perf_counter() - started
    gc.collect()
    loaded_rss = rss_mb()

    print("warmup...", flush=True)
    model_system_prompt = system_prompt(args.model_id)
    warmup_started = time.perf_counter()
    adapter.translate(
        build_prompt(cases[0], "m0"),
        system=model_system_prompt,
    )
    warmup_seconds = time.perf_counter() - warmup_started

    rows: list[dict[str, Any]] = []
    total = len(cases) * len(VARIANTS)
    completed = 0
    for case in cases:
        for variant in VARIANTS:
            prompt = build_prompt(case, variant)
            prompt_tokens = len(adapter.encode(prompt))
            started = time.perf_counter()
            try:
                output = adapter.translate(
                    prompt,
                    system=model_system_prompt,
                )
                status, reason = score_output(output, case)
                target_output, extraction = extract_target_output(output)
                error = None
            except Exception as exc:
                output = ""
                target_output = ""
                extraction = ""
                status = "error"
                reason = ""
                error = f"{type(exc).__name__}: {exc}"
            elapsed_ms = (time.perf_counter() - started) * 1000
            rows.append(
                {
                    "id": case.id,
                    "variant": variant,
                    "target": case.target,
                    "before": case.before,
                    "after": case.after,
                    "references": list(case.references),
                    "output": output,
                    "target_output": target_output,
                    "extraction": extraction,
                    "status": status,
                    "reason": reason,
                    "latency_ms": round(elapsed_ms, 2),
                    "prompt_tokens": prompt_tokens,
                    "error": error,
                }
            )
            completed += 1
            print(
                f"[{completed:03d}/{total}] {variant} {case.id} "
                f"{case.target} -> {output or '<error>'} "
                f"({status}, {elapsed_ms:.1f}ms)",
                flush=True,
            )

    summary = summarize(rows, cases)
    result = {
        "model_id": args.model_id,
        "category_filter": args.category,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "case_count": len(cases),
        "variant_count": len(VARIANTS),
        "load_seconds": round(load_seconds, 2),
        "warmup_seconds": round(warmup_seconds, 2),
        "loaded_rss_mb": round(loaded_rss, 1),
        "peak_rss_mb": round(rss_mb(), 1),
        "summary": summary,
        "rows": rows,
    }
    output_path.write_text(
        json.dumps(result, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    markdown_path.write_text(
        render_markdown(summary, args.model_id),
        encoding="utf-8",
    )
    print(f"saved {output_path}")
    print(f"saved {markdown_path}")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-id", default=DEFAULT_MODEL_ID)
    parser.add_argument("--cases", default=str(DEFAULT_CASES_PATH))
    parser.add_argument("--output", default="")
    parser.add_argument(
        "--category",
        choices=["polysemy", "business", "sentence", "control"],
        default="",
    )
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


if __name__ == "__main__":
    raise SystemExit(run(parse_args()))
