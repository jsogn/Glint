#!/usr/bin/env python3
"""Evaluate context as a reranker over candidate English senses."""

from __future__ import annotations

import argparse
import gc
import json
import time
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from run_context_eval import (
    DEFAULT_CASES_PATH,
    DEFAULT_MODEL_ID,
    RESULTS_DIR,
    ContextCase,
    HyMTAdapter,
    clip_context,
    load_cases,
    normalize_translation,
    percentile,
    rss_mb,
)


VARIANTS = {
    "r0": (0, 0),
    "r2": (24, 8),
}
SYSTEM_PROMPT = (
    "You disambiguate Chinese translation choices. "
    "Select exactly one option that best fits the marked target in context. "
    "Output only the selected option text. Do not explain or translate the "
    "surrounding sentence."
)


def reference_choices(case: ContextCase) -> list[str]:
    values: list[str] = []
    seen: set[str] = set()
    for value in (*case.references, *case.unacceptable):
        normalized = normalize_translation(value)
        if normalized not in seen:
            seen.add(normalized)
            values.append(value)
    return values


def load_choice_map(path: Path) -> dict[str, list[str]]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    entries = raw.get("entries", {})
    return {
        case_id: list(entry.get("choices", []))
        for case_id, entry in entries.items()
    }


def selected_choices(
    case: ContextCase,
    choice_map: dict[str, list[str]],
) -> list[str]:
    if choice_map:
        return choice_map.get(case.id, [])
    return reference_choices(case)


def build_choice_prompt(
    case: ContextCase,
    variant: str,
    choice_values: list[str] | None = None,
) -> str:
    if variant not in VARIANTS:
        raise ValueError(f"unknown rerank variant: {variant}")
    before_limit, after_limit = VARIANTS[variant]
    before = clip_context(case.before, before_limit, from_end=True)
    after = clip_context(case.after, after_limit, from_end=False)
    values = choice_values or reference_choices(case)
    option_lines = [f"- {choice}" for choice in values]
    if before or after:
        sentence = f"{before}【{case.target}】{after}"
        context = f"句子：{sentence}\n"
    else:
        context = ""
    return (
        f"{context}"
        f"目标：{case.target}\n"
        "选项：\n"
        + "\n".join(option_lines)
        + "\n只输出最符合语境的一个选项原文："
    )


def score_choice(
    output: str,
    case: ContextCase,
    choice_values: list[str] | None = None,
) -> tuple[str, str]:
    cleaned = output.strip().strip("`\"'“”‘’ ")
    if not cleaned:
        return "invalid", "empty"
    if len(cleaned.splitlines()) > 1:
        return "invalid", "multiple_lines"
    normalized = normalize_translation(cleaned)
    option_values = {
        normalize_translation(value)
        for value in (choice_values or reference_choices(case))
    }
    if normalized not in option_values:
        return "incorrect", "not_an_option"
    reference_values = {
        normalize_translation(value)
        for value in case.references
    }
    if normalized in reference_values:
        return "acceptable", ""
    return "incorrect", "wrong_option"


def paired_polysemy_cases(cases: list[ContextCase]) -> list[ContextCase]:
    return [
        case
        for case in cases
        if case.category == "polysemy" and case.pair_id
    ]


def summarize(
    rows: list[dict[str, Any]],
    cases: list[ContextCase],
    choice_map: dict[str, list[str]],
) -> dict[str, Any]:
    by_id = {case.id: case for case in cases}
    result: dict[str, Any] = {}
    for variant in VARIANTS:
        variant_rows = [row for row in rows if row["variant"] == variant]
        latencies = [
            row["latency_ms"]
            for row in variant_rows
            if row["status"] != "error"
        ]
        acceptable = sum(
            row["status"] == "acceptable"
            for row in variant_rows
        )
        result[variant] = {
            "case_count": len(variant_rows),
            "acceptable": acceptable,
            "acceptable_rate": (
                acceptable / len(variant_rows)
                if variant_rows
                else None
            ),
            "invalid": sum(
                row["status"] == "invalid"
                for row in variant_rows
            ),
            "errors": sum(
                row["status"] == "error"
                for row in variant_rows
            ),
            "p50_latency_ms": round(
                percentile(latencies, 0.50),
                2,
            ),
            "p95_latency_ms": round(
                percentile(latencies, 0.95),
                2,
            ),
            "paired_vs_r0": compare_pairs(
                variant_rows,
                rows,
                by_id,
            ),
        }
    eligible_cases = [
        case
        for case in cases
        if len(selected_choices(case, choice_map)) >= 2
    ]
    correct_option_cases = [
        case
        for case in eligible_cases
        if any(
            normalize_translation(choice)
            in {
                normalize_translation(reference)
                for reference in case.references
            }
            for choice in selected_choices(case, choice_map)
        )
    ]
    result["coverage"] = {
        "case_count": len(cases),
        "eligible_two_plus": len(eligible_cases),
        "correct_option_available": len(correct_option_cases),
    }
    return result


def compare_pairs(
    variant_rows: list[dict[str, Any]],
    all_rows: list[dict[str, Any]],
    by_id: dict[str, ContextCase],
) -> dict[str, int]:
    baseline = {
        row["id"]: row["status"] == "acceptable"
        for row in all_rows
        if row["variant"] == "r0"
    }
    grouped: defaultdict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in variant_rows:
        pair_id = by_id[row["id"]].pair_id
        if pair_id:
            grouped[pair_id].append(row)
    wins = losses = ties = 0
    for pair_rows in grouped.values():
        current = sum(
            row["status"] == "acceptable"
            for row in pair_rows
        )
        base = sum(
            baseline.get(row["id"], False)
            for row in pair_rows
        )
        if current > base:
            wins += 1
        elif current < base:
            losses += 1
        else:
            ties += 1
    return {"wins": wins, "losses": losses, "ties": ties}


def render_markdown(
    summary: dict[str, Any],
    model_id: str,
    choice_source: str,
) -> str:
    lines = [
        "# Context Reranking Evaluation",
        "",
        f"- Model: `{model_id}`",
        f"- Date: {datetime.now(timezone.utc).isoformat()}",
        f"- Choice set: {choice_source}",
        (
            "- Coverage: "
            f"{summary['coverage']['eligible_two_plus']}/"
            f"{summary['coverage']['case_count']} cases have two or more "
            "dictionary choices; "
            f"{summary['coverage']['correct_option_available']} include an "
            "acceptable sense"
        ),
        "",
        "| Variant | Acceptable | Rate | Invalid | Errors | p50 ms | p95 ms |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for variant in VARIANTS:
        value = summary[variant]
        lines.append(
            f"| {variant} | {value['acceptable']}/{value['case_count']} | "
            f"{value['acceptable_rate']:.1%} | {value['invalid']} | "
            f"{value['errors']} | {value['p50_latency_ms']} | "
            f"{value['p95_latency_ms']} |"
        )
    lines.extend(
        [
            "",
            "| Variant | Wins | Losses | Ties |",
            "| --- | ---: | ---: | ---: |",
        ]
    )
    for variant in ["r2"]:
        value = summary[variant]["paired_vs_r0"]
        lines.append(
            f"| {variant} | {value['wins']} | "
            f"{value['losses']} | {value['ties']} |"
        )
    lines.append("")
    return "\n".join(lines)


def run(args: argparse.Namespace) -> int:
    all_cases = paired_polysemy_cases(load_cases(Path(args.cases)))
    cases = all_cases
    choice_map: dict[str, list[str]] = {}
    if args.choices_file:
        choice_map = load_choice_map(Path(args.choices_file))
        cases = [
            case
            for case in cases
            if len(selected_choices(case, choice_map)) >= 2
        ]
    if args.limit:
        cases = cases[: args.limit]
    if args.dry_run:
        for variant in VARIANTS:
            for case in cases:
                prompt = build_choice_prompt(
                    case,
                    variant,
                    selected_choices(case, choice_map),
                )
                if len(selected_choices(case, choice_map)) < 2:
                    raise ValueError(f"{case.id}: rerank needs two options")
                if case.target not in prompt:
                    raise ValueError(f"{case.id}: prompt omits target")
        print(f"dry-run valid cases={len(cases)}")
        return 0

    output_path = (
        Path(args.output)
        if args.output
        else RESULTS_DIR / (
            "context-rerank-hy-mt2-dictionary.json"
            if args.choices_file
            else "context-rerank-hy-mt2.json"
        )
    )
    markdown_path = output_path.with_suffix(".md")
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)

    print("loading model...", flush=True)
    started = time.perf_counter()
    adapter = HyMTAdapter(args.model_id)
    load_seconds = time.perf_counter() - started
    gc.collect()

    print("warmup...", flush=True)
    warmup_started = time.perf_counter()
    adapter.translate(
        build_choice_prompt(
            cases[0],
            "r0",
            selected_choices(cases[0], choice_map),
        ),
        system=SYSTEM_PROMPT,
    )
    warmup_seconds = time.perf_counter() - warmup_started

    rows: list[dict[str, Any]] = []
    total = len(cases) * len(VARIANTS)
    completed = 0
    for case in cases:
        for variant in VARIANTS:
            choice_values = selected_choices(case, choice_map)
            prompt = build_choice_prompt(
                case,
                variant,
                choice_values,
            )
            started = time.perf_counter()
            try:
                output = adapter.translate(
                    prompt,
                    system=SYSTEM_PROMPT,
                )
                status, reason = score_choice(
                    output,
                    case,
                    choice_values,
                )
                error = None
            except Exception as exc:
                output = ""
                status = "error"
                reason = ""
                error = f"{type(exc).__name__}: {exc}"
            elapsed_ms = (time.perf_counter() - started) * 1000
            rows.append(
                {
                    "id": case.id,
                    "variant": variant,
                    "target": case.target,
                    "choices": choice_values,
                    "output": output,
                    "status": status,
                    "reason": reason,
                    "latency_ms": round(elapsed_ms, 2),
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

    summary = summarize(rows, all_cases, choice_map)
    result = {
        "model_id": args.model_id,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "case_count": len(cases),
        "variant_count": len(VARIANTS),
        "choice_source": (
            args.choices_file if args.choices_file else "reference_set"
        ),
        "load_seconds": round(load_seconds, 2),
        "warmup_seconds": round(warmup_seconds, 2),
        "peak_rss_mb": round(rss_mb(), 1),
        "summary": summary,
        "rows": rows,
    }
    output_path.write_text(
        json.dumps(result, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    markdown_path.write_text(
        render_markdown(
            summary,
            args.model_id,
            (
                "dictionary output from `"
                + args.choices_file
                + "`"
            )
            if args.choices_file
            else "references plus listed unacceptable senses",
        ),
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
    parser.add_argument("--choices-file", default="")
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


if __name__ == "__main__":
    raise SystemExit(run(parse_args()))
