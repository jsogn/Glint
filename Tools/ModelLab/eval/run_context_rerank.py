#!/usr/bin/env python3
"""Evaluate context as a reranker over candidate English senses."""

from __future__ import annotations

import argparse
import gc
import json
import re
import time
import unicodedata
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
    "Output only the selected option letter. Do not explain or translate the "
    "surrounding sentence."
)


def clean_choice_output(text: str) -> str:
    cleaned = unicodedata.normalize("NFKC", text).strip()
    cleaned = re.sub(r"^(?:[-*•]|\d+[.)])\s*", "", cleaned)
    return cleaned.strip().strip("`\"'“”‘’ ").strip()


def normalize_choice(text: str) -> str:
    normalized = clean_choice_output(text).lower()
    normalized = re.sub(r"^(?:\([^)]*\)\s*)+", "", normalized)
    normalized = normalized.replace("’", "'")
    normalized = re.sub(r"[^a-z0-9']+", " ", normalized).strip()
    normalized = re.sub(r"\s+", " ", normalized)
    return re.sub(r"^to ", "", normalized)


def reference_choices(case: ContextCase) -> list[str]:
    values: list[str] = []
    seen: set[str] = set()
    for value in (*case.references, *case.unacceptable):
        normalized = normalize_translation(value)
        if normalized not in seen:
            seen.add(normalized)
            values.append(value)
    return values


def choice_label(index: int) -> str:
    if index < 0 or index >= 26:
        raise ValueError("choice index out of range")
    return chr(ord("A") + index)


def load_choice_map(
    path: Path,
    generation_prompt: str = "",
    fallback_generation_prompt: str = "",
    minimum_choices: int = 2,
) -> dict[str, list[str]]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    entries = raw.get("entries", {})
    if generation_prompt:
        result = {}
        for case_id, entry in entries.items():
            generations = {
                value.get("prompt"): value.get("candidates", [])
                for value in entry.get("generations", [])
            }
            values = list(generations.get(generation_prompt, []))
            if (
                len(values) < minimum_choices
                and fallback_generation_prompt
            ):
                values.extend(
                    generations.get(fallback_generation_prompt, [])
                )
            deduped = []
            seen: set[str] = set()
            for value in values:
                key = normalize_choice(value)
                if key and key not in seen:
                    seen.add(key)
                    deduped.append(value)
            result[case_id] = deduped
        return result
    return {
        case_id: list(
            entry.get("choices")
            or entry.get("candidates")
            or []
        )
        for case_id, entry in entries.items()
    }


def load_gold_choices(path: Path) -> dict[str, list[str]]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    cases = raw.get("cases")
    if not isinstance(cases, dict):
        raise ValueError("gold choices must contain a cases object")
    result: dict[str, list[str]] = {}
    for case_id, values in cases.items():
        if (
            not isinstance(case_id, str)
            or not isinstance(values, list)
            or not values
            or not all(
                isinstance(value, str) and value.strip()
                for value in values
            )
        ):
            raise ValueError(f"{case_id}: invalid gold choices")
        result[case_id] = list(values)
    return result


def accepted_choices(
    case: ContextCase,
    gold_choices: dict[str, list[str]],
) -> list[str]:
    return gold_choices.get(case.id, list(case.references))


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
    option_lines = [
        f"{choice_label(index)}. {choice}"
        for index, choice in enumerate(values)
    ]
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
        + "\n只输出最符合语境的一个选项字母（例如 A）："
    )


def resolve_choice(
    output: str,
    case: ContextCase,
    choice_values: list[str] | None = None,
) -> str | None:
    values = choice_values or reference_choices(case)
    cleaned = clean_choice_output(output)
    normalized = normalize_choice(cleaned)
    for value in values:
        if normalized == normalize_choice(value):
            return value
    label_match = re.fullmatch(
        r"(?:option\s*)?([A-Z])(?:(?:[.)]|\s).*)?",
        cleaned,
        flags=re.IGNORECASE,
    )
    if label_match:
        index = ord(label_match.group(1).upper()) - ord("A")
        return values[index] if index < len(values) else None
    return None


def score_choice(
    output: str,
    case: ContextCase,
    choice_values: list[str] | None = None,
    accepted_values: list[str] | None = None,
) -> tuple[str, str]:
    cleaned = clean_choice_output(output)
    if not cleaned:
        return "invalid", "empty"
    if len(cleaned.splitlines()) > 1:
        return "invalid", "multiple_lines"
    selected = resolve_choice(cleaned, case, choice_values)
    if selected is None:
        return "incorrect", "not_an_option"
    reference_values = {
        normalize_choice(value)
        for value in (accepted_values or case.references)
    }
    if normalize_choice(selected) in reference_values:
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
    gold_choices: dict[str, list[str]],
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
        available_rows = [
            row
            for row in variant_rows
            if any(
                normalize_choice(choice)
                in {
                    normalize_choice(reference)
                    for reference in (
                        row.get("accepted_choices")
                        or accepted_choices(
                            by_id[row["id"]],
                            gold_choices,
                        )
                    )
                }
                for choice in row["choices"]
            )
        ]
        available_acceptable = sum(
            row["status"] == "acceptable"
            for row in available_rows
        )
        result[variant] = {
            "case_count": len(variant_rows),
            "acceptable": acceptable,
            "acceptable_rate": (
                acceptable / len(variant_rows)
                if variant_rows
                else None
            ),
            "correct_option_available": len(available_rows),
            "conditional_acceptable_rate": (
                available_acceptable / len(available_rows)
                if available_rows
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
            normalize_choice(choice)
            in {
                normalize_choice(reference)
                for reference in accepted_choices(case, gold_choices)
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
    gold_source: str,
) -> str:
    lines = [
        "# Context Reranking Evaluation",
        "",
        f"- Model: `{model_id}`",
        f"- Date: {datetime.now(timezone.utc).isoformat()}",
        f"- Choice set: {choice_source}",
        f"- Gold choices: {gold_source}",
        (
            "- Coverage: "
            f"{summary['coverage']['eligible_two_plus']}/"
            f"{summary['coverage']['case_count']} cases have two or more "
            "dictionary choices; "
            f"{summary['coverage']['correct_option_available']} include an "
            "acceptable sense"
        ),
        "",
        (
            "| Variant | Acceptable | Rate | Available | Conditional | "
            "Invalid | Errors | p50 ms | p95 ms |"
        ),
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for variant in VARIANTS:
        value = summary[variant]
        conditional = (
            f"{value['conditional_acceptable_rate']:.1%}"
            if value["conditional_acceptable_rate"] is not None
            else "n/a"
        )
        lines.append(
            f"| {variant} | {value['acceptable']}/{value['case_count']} | "
            f"{value['acceptable_rate']:.1%} | "
            f"{value['correct_option_available']} | "
            f"{conditional} | "
            f"{value['invalid']} | {value['errors']} | "
            f"{value['p50_latency_ms']} | {value['p95_latency_ms']} |"
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


def write_result(
    output_path: Path,
    markdown_path: Path,
    result: dict[str, Any],
    summary: dict[str, Any],
    model_id: str,
    choice_source: str,
    gold_source: str,
) -> None:
    output_path.write_text(
        json.dumps(result, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    markdown_path.write_text(
        render_markdown(
            summary,
            model_id,
            choice_source,
            gold_source,
        ),
        encoding="utf-8",
    )


def rescore_result(
    result: dict[str, Any],
    cases: list[ContextCase],
    gold_choices: dict[str, list[str]],
) -> tuple[dict[str, Any], dict[str, Any], dict[str, list[str]]]:
    by_id = {case.id: case for case in cases}
    choice_map: dict[str, list[str]] = {}
    for row in result["rows"]:
        choices = list(row.get("choices", []))
        choice_map.setdefault(row["id"], choices)
        case = by_id[row["id"]]
        row_accepted = list(
            gold_choices.get(case.id)
            or row.get("accepted_choices")
            or accepted_choices(case, gold_choices)
        )
        status, reason = score_choice(
            row["output"],
            case,
            choices,
            row_accepted,
        )
        row["status"] = status
        row["reason"] = reason
        row["selected_choice"] = resolve_choice(
            row["output"],
            case,
            choices,
        )
        row["accepted_choices"] = row_accepted
    summary = summarize(
        result["rows"],
        cases,
        choice_map,
        gold_choices,
    )
    result["summary"] = summary
    result["rescored_at"] = datetime.now(timezone.utc).isoformat()
    return result, summary, choice_map


def run(args: argparse.Namespace) -> int:
    gold_choices = (
        load_gold_choices(Path(args.gold_file))
        if args.gold_file
        else {}
    )
    gold_source = (
        args.gold_file
        if args.gold_file
        else "case references"
    )
    if args.rescore_from:
        result_path = Path(args.rescore_from)
        result = json.loads(result_path.read_text(encoding="utf-8"))
        all_cases = paired_polysemy_cases(load_cases(Path(args.cases)))
        result, summary, _ = rescore_result(
            result,
            all_cases,
            gold_choices,
        )
        result["gold_source"] = gold_source
        output_path = Path(args.output) if args.output else result_path
        markdown_path = output_path.with_suffix(".md")
        choice_source = result.get(
            "choice_source",
            "reference_set",
        )
        write_result(
            output_path,
            markdown_path,
            result,
            summary,
            result["model_id"],
            choice_source,
            gold_source,
        )
        print(f"rescored {output_path}")
        print(f"saved {markdown_path}")
        return 0

    all_cases = paired_polysemy_cases(load_cases(Path(args.cases)))
    cases = all_cases
    choice_map: dict[str, list[str]] = {}
    if args.choices_file:
        choice_map = load_choice_map(
            Path(args.choices_file),
            args.generation_prompt,
            args.fallback_generation_prompt,
        )
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
            accepted_values = accepted_choices(case, gold_choices)
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
                    accepted_values,
                )
                selected_choice = resolve_choice(
                    output,
                    case,
                    choice_values,
                )
                error = None
            except Exception as exc:
                output = ""
                selected_choice = None
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
                    "accepted_choices": accepted_values,
                    "output": output,
                    "selected_choice": selected_choice,
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

    summary = summarize(
        rows,
        all_cases,
        choice_map,
        gold_choices,
    )
    result = {
        "model_id": args.model_id,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "case_count": len(cases),
        "variant_count": len(VARIANTS),
        "choice_source": (
            args.choices_file if args.choices_file else "reference_set"
        ),
        "gold_source": gold_source,
        "load_seconds": round(load_seconds, 2),
        "warmup_seconds": round(warmup_seconds, 2),
        "peak_rss_mb": round(rss_mb(), 1),
        "summary": summary,
        "rows": rows,
    }
    write_result(
        output_path,
        markdown_path,
        result,
        summary,
        args.model_id,
        (
            "candidate output from `"
            + args.choices_file
            + "`"
            + (
                f" ({args.generation_prompt} prompt)"
                if args.generation_prompt
                else ""
            )
        )
        if args.choices_file
        else "references plus listed unacceptable senses",
        gold_source,
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
    parser.add_argument(
        "--generation-prompt",
        choices=["direct", "compound_aware"],
        default="",
    )
    parser.add_argument(
        "--fallback-generation-prompt",
        choices=["direct", "compound_aware"],
        default="",
    )
    parser.add_argument("--gold-file", default="")
    parser.add_argument("--rescore-from", default="")
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


if __name__ == "__main__":
    raise SystemExit(run(parse_args()))
