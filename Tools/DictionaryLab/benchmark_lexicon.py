#!/usr/bin/env python3
"""Benchmark current and normalized dictionary cores."""

from __future__ import annotations

import argparse
import json
import re
import sqlite3
import statistics
import time
import unicodedata
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Iterable


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CONTEXT_CASES = ROOT / "Tools/ModelLab/eval/context_cases.json"
DEFAULT_CONTEXT_CHOICES = (
    ROOT / "Tools/ModelLab/results/context-choices.json"
)
DEFAULT_REGRESSION_CASES = (
    ROOT / "Resources/Evaluation/dictionary-benchmark.json"
)
DEFAULT_OUTPUT = (
    ROOT / "Tools/DictionaryLab/results/dictionary-core-benchmark.json"
)

LEADING_PREFIXES = ("to ", "the ", "a ", "an ", "be ", "of ")
METADATA_PREFIX = re.compile(r"^(?:\([^)]*\)\s*)+")


def normalize_candidate(text: str) -> str:
    value = unicodedata.normalize("NFKC", text).lower()
    value = METADATA_PREFIX.sub("", value)
    value = re.sub(r"[^a-z0-9']+", " ", value).strip()
    value = re.sub(r"\s+", " ", value)
    for prefix in LEADING_PREFIXES:
        if value.startswith(prefix):
            value = value[len(prefix):]
            break
    return value.strip()


def split_definition_candidates(definition: str) -> list[str]:
    candidates: list[str] = []
    seen: set[str] = set()
    for part in re.split(r"\s*[/;]\s*", definition):
        value = METADATA_PREFIX.sub("", part).strip(
            " .!?()[]{}\"'“”‘’"
        )
        normalized = normalize_candidate(value)
        if (
            not normalized
            or normalized in seen
            or re.search(r"[\u3400-\u9fff]", value)
            or normalized.startswith("cl ")
        ):
            continue
        seen.add(normalized)
        candidates.append(value)
    return candidates


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(
        len(ordered) - 1,
        max(0, round((len(ordered) - 1) * fraction)),
    )
    return ordered[index]


def current_cedict_candidates(
    connection: sqlite3.Connection,
    term: str,
) -> list[str]:
    row = connection.execute(
        "SELECT gloss FROM entries WHERE word = ? LIMIT 1",
        (term,),
    ).fetchone()
    return split_definition_candidates(row[0]) if row else []


def normalized_candidates(
    connection: sqlite3.Connection,
    term: str,
    source: str | None,
    rank: bool = False,
) -> list[str]:
    source_clause = "AND source = ?" if source else ""
    parameters: tuple[str, ...] = (
        (term, source)
        if source
        else (term,)
    )
    rows = connection.execute(
        f"""
        SELECT definition
        FROM lexicon_entries
        WHERE (headword = ? OR traditional = ?)
          {source_clause}
        ORDER BY
          source_priority DESC,
          COALESCE(frequency, 2147483647),
          source_order,
          sense_order,
          sense_id
        """,
        (term, *parameters),
    ).fetchall()
    rankings = {}
    if rank:
        ranking_rows = connection.execute(
            """
            SELECT english, frequency, collins, oxford
            FROM rankings
            WHERE term = ?
            ORDER BY frequency, collins DESC, oxford DESC, english
            """,
            (term,),
        ).fetchall()
        for index, row in enumerate(ranking_rows):
            rankings.setdefault(
                normalize_candidate(row[0]),
                (
                    index,
                    row[1],
                    row[2],
                    row[3],
                ),
            )

    ranked_candidates: list[tuple[tuple, int, str]] = []
    sequence = 0
    for row in rows:
        for value in split_definition_candidates(row[0]):
            key = normalize_candidate(value)
            if not key:
                continue
            ranking = rankings.get(key)
            if ranking is not None:
                rank_index, frequency, collins, oxford = ranking
                sort_key = (
                    0,
                    rank_index,
                    frequency,
                    -collins,
                    -oxford,
                    len(key.split()),
                    key,
                )
            else:
                sort_key = (
                    1,
                    2_147_483_647,
                    2_147_483_647,
                    0,
                    0,
                    len(key.split()),
                    key,
                )
            ranked_candidates.append((sort_key, sequence, value))
            sequence += 1
    if rank:
        ranked_candidates.sort(key=lambda item: (item[0], item[1]))

    candidates: list[str] = []
    seen: set[str] = set()
    for _, _, value in ranked_candidates:
        key = normalize_candidate(value)
        if key not in seen:
            seen.add(key)
            candidates.append(value)
    return candidates


def evaluate(
    cases: Iterable[dict],
    get_candidates: Callable[[dict], list[str]],
) -> dict:
    rows: list[dict] = []
    grouped: defaultdict[str, list[dict]] = defaultdict(list)
    for case in cases:
        started = time.perf_counter()
        candidates = get_candidates(case)
        latency_ms = (time.perf_counter() - started) * 1000
        expected = [
            normalize_candidate(value)
            for value in case.get("expected", case.get("references", []))
        ]
        expected = [value for value in expected if value]
        normalized = [
            normalize_candidate(value)
            for value in candidates
        ]
        expected_set = set(expected)
        if expected:
            coverage = bool(set(normalized) & expected_set)
            top1 = bool(normalized and normalized[0] in expected_set)
            top3 = any(
                value in expected_set
                for value in normalized[:3]
            )
            recall = (
                len(set(normalized) & expected_set) / len(expected_set)
            )
        else:
            coverage = not candidates
            top1 = not candidates
            top3 = not candidates
            recall = 1.0 if not candidates else 0.0
        category = case.get("category", "unknown")
        row = {
            "id": case.get("id", case.get("text")),
            "target": case.get("target", case.get("text")),
            "category": category,
            "expected": expected,
            "candidates": candidates[:12],
            "coverage": coverage,
            "top1": top1,
            "top3": top3,
            "reference_recall": recall,
            "latency_ms": latency_ms,
        }
        rows.append(row)
        grouped[category].append(row)

    def stats(values: list[dict]) -> dict:
        latencies = [
            row["latency_ms"]
            for row in values
            if row["latency_ms"] is not None
        ]
        evaluated = [
            row for row in values if row["expected"]
        ]
        blocked = [
            row for row in values if not row["expected"]
        ]
        return {
            "case_count": len(values),
            "lookup_hit_rate": (
                sum(bool(row["candidates"]) for row in values)
                / len(values)
                if values
                else None
            ),
            "coverage": sum(row["coverage"] for row in values),
            "coverage_rate": (
                sum(row["coverage"] for row in values) / len(values)
                if values
                else None
            ),
            "top1": sum(row["top1"] for row in values),
            "top1_rate": (
                sum(row["top1"] for row in values) / len(values)
                if values
                else None
            ),
            "top3": sum(row["top3"] for row in values),
            "top3_rate": (
                sum(row["top3"] for row in values) / len(values)
                if values
                else None
            ),
            "reference_recall": (
                statistics.mean(
                    row["reference_recall"]
                    for row in evaluated
                )
                if evaluated
                else None
            ),
            "blocked_correct": sum(
                row["top1"] for row in blocked
            ),
            "blocked_count": len(blocked),
            "p50_latency_ms": (
                round(percentile(latencies, 0.50), 4)
                if latencies
                else None
            ),
            "p95_latency_ms": (
                round(percentile(latencies, 0.95), 4)
                if latencies
                else None
            ),
        }

    evaluated_rows = [
        row for row in rows if row["category"] != "blocked"
    ]
    return {
        "overall": stats(evaluated_rows),
        "blocked": (
            stats([row for row in rows if row["category"] == "blocked"])
            if any(row["category"] == "blocked" for row in rows)
            else None
        ),
        "categories": {
            category: stats(values)
            for category, values in sorted(grouped.items())
        },
        "rows": rows,
    }


def production_choices(path: Path) -> dict[str, list[str]]:
    raw = json.loads(path.read_text(encoding="utf-8"))["entries"]
    return {
        case_id: list(entry.get("choices", []))
        for case_id, entry in raw.items()
    }


def benchmark_suite(
    cases: list[dict],
    variants: dict[str, Callable[[dict], list[str]]],
) -> dict:
    return {
        name: evaluate(cases, get_candidates)
        for name, get_candidates in variants.items()
    }


def remove_precomputed_latency(result: dict) -> None:
    for row in result["rows"]:
        row["latency_ms"] = None
    all_stats = [result["overall"], *result["categories"].values()]
    if result.get("blocked") is not None:
        all_stats.append(result["blocked"])
    for stats in all_stats:
        stats["p50_latency_ms"] = None
        stats["p95_latency_ms"] = None


def render_markdown(result: dict) -> str:
    lines = [
        "# Dictionary Core Benchmark",
        "",
        f"- Date: {result['generated_at']}",
        f"- Normalized lexicon: `{result['lexicon']}`",
        "",
        "## Context Corpus",
        "",
        "| Variant | Coverage | Top 1 | Top 3 | Reference recall | p95 |",
        "| --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    for name, value in result["suites"]["context"].items():
        stats = value["overall"]
        latency = (
            f"{stats['p95_latency_ms']:.4f}ms"
            if stats["p95_latency_ms"] is not None
            else "precomputed"
        )
        lines.append(
            f"| {name} | {stats['coverage_rate']:.1%} | "
            f"{stats['top1_rate']:.1%} | {stats['top3_rate']:.1%} | "
            f"{stats['reference_recall']:.1%} | {latency} |"
        )
    lines.extend(
        [
            "",
            "## Regression Corpus",
            "",
            "| Variant | Coverage | Top 1 | Top 3 | Reference recall | p95 |",
            "| --- | ---: | ---: | ---: | ---: | ---: |",
        ]
    )
    for name, value in result["suites"]["regression"].items():
        stats = value["overall"]
        latency = (
            f"{stats['p95_latency_ms']:.4f}ms"
            if stats["p95_latency_ms"] is not None
            else "precomputed"
        )
        lines.append(
            f"| {name} | {stats['coverage_rate']:.1%} | "
            f"{stats['top1_rate']:.1%} | {stats['top3_rate']:.1%} | "
            f"{stats['reference_recall']:.1%} | {latency} |"
        )
    lines.append("")
    return "\n".join(lines)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lexicon", required=True)
    parser.add_argument("--current-cedict", required=True)
    parser.add_argument(
        "--context-cases",
        default=str(DEFAULT_CONTEXT_CASES),
    )
    parser.add_argument(
        "--context-choices",
        default=str(DEFAULT_CONTEXT_CHOICES),
    )
    parser.add_argument(
        "--regression-cases",
        default=str(DEFAULT_REGRESSION_CASES),
    )
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT))
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    context_cases = json.loads(
        Path(args.context_cases).read_text(encoding="utf-8")
    )
    regression_cases = json.loads(
        Path(args.regression_cases).read_text(encoding="utf-8")
    )
    choices = production_choices(Path(args.context_choices))

    current = sqlite3.connect(Path(args.current_cedict))
    normalized = sqlite3.connect(Path(args.lexicon))
    try:
        context_variants = {
            "production_router": lambda case: choices.get(
                case["id"],
                [],
            ),
            "current_cedict": lambda case: current_cedict_candidates(
                current,
                case["target"],
            ),
            "normalized_cedict": lambda case: normalized_candidates(
                normalized,
                case["target"],
                "cedict",
            ),
            "normalized_union": lambda case: normalized_candidates(
                normalized,
                case["target"],
                None,
            ),
            "normalized_ranked_union": lambda case: normalized_candidates(
                normalized,
                case["target"],
                None,
                True,
            ),
        }
        by_text = {
            row["text"]: row.get("category", "general")
            for row in regression_cases
        }
        regression_variants = {
            "current_cedict": lambda case: current_cedict_candidates(
                current,
                case["text"],
            ),
            "normalized_cedict": lambda case: normalized_candidates(
                normalized,
                case["text"],
                "cedict",
            ),
            "normalized_union": lambda case: normalized_candidates(
                normalized,
                case["text"],
                None,
            ),
            "normalized_ranked_union": lambda case: normalized_candidates(
                normalized,
                case["text"],
                None,
                True,
            ),
        }
        context_suite = benchmark_suite(
            context_cases,
            context_variants,
        )
        remove_precomputed_latency(
            context_suite["production_router"]
        )
        result = {
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "lexicon": args.lexicon,
            "suites": {
                "context": context_suite,
                "regression": benchmark_suite(
                    regression_cases,
                    regression_variants,
                ),
            },
            "regression_categories": by_text,
        }
    finally:
        current.close()
        normalized.close()

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    output.with_suffix(".md").write_text(
        render_markdown(result),
        encoding="utf-8",
    )
    print(response := render_markdown(result))
    print(f"saved {output}")
    del response


if __name__ == "__main__":
    main()
