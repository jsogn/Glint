#!/usr/bin/env python3
"""Evaluate dictionary and model routes on independent product cases."""

from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from benchmark_lexicon import normalize_candidate
from evaluate_override_ablation import merge_candidates, visible_candidates


ROOT = Path(__file__).resolve().parents[2]
CASES_PATH = ROOT / "Tools/DictionaryLab/eval/product_heldout_cases.json"
ROUTE_PATH = (
    ROOT / "Tools/DictionaryLab/results/product-heldout-route-choices.json"
)
QWEN_PATH = Path("/tmp/glint-heldout-qwen-result.json")
OUTPUT_PATH = (
    ROOT / "Tools/DictionaryLab/results/product-heldout-evaluation.json"
)
MODEL_LAB_EVAL = ROOT / "Tools/ModelLab/eval"
DEFAULT_HY_MODEL = "mlx-community/Hy-MT2-1.8B-4bit"


def load_cases(path: Path) -> list[dict[str, Any]]:
    document = json.loads(path.read_text(encoding="utf-8"))
    cases = document["cases"]
    if not isinstance(cases, list):
        raise ValueError("product held-out cases must be a list")
    return cases


def load_route_choices(path: Path) -> dict[str, list[str]]:
    entries = json.loads(path.read_text(encoding="utf-8"))["entries"]
    return {
        case_id: list(entry.get("choices", []))
        for case_id, entry in entries.items()
    }


def load_frozen_model_rows(
    path: Path,
    variant: str,
) -> dict[str, dict[str, Any]]:
    rows = json.loads(path.read_text(encoding="utf-8"))["rows"]
    return {
        row["id"]: row
        for row in rows
        if row["variant"] == variant
    }


def score(
    candidates: list[str],
    references: list[str],
    unacceptable: list[str],
) -> tuple[bool, bool, bool, str]:
    normalized = [
        normalize_candidate(candidate)
        for candidate in candidates
    ]
    normalized = [value for value in normalized if value]
    expected = {
        normalize_candidate(reference)
        for reference in references
    }
    expected.discard("")
    rejected = {
        normalize_candidate(value)
        for value in unacceptable
    }
    rejected.discard("")
    coverage = bool(set(normalized) & expected)
    top1 = bool(normalized and normalized[0] in expected)
    top3 = any(value in expected for value in normalized[:3])
    if not normalized:
        reason = "empty"
    elif normalized[0] in rejected:
        reason = "listed_unacceptable"
    elif normalized[0] not in expected:
        reason = "not_in_reference_set"
    else:
        reason = ""
    return coverage, top1, top3, reason


def run_hy_target_only(
    cases: list[dict[str, Any]],
    model_id: str,
) -> tuple[dict[str, dict[str, Any]], dict[str, Any]]:
    sys.path.insert(0, str(MODEL_LAB_EVAL))
    import run_context_eval

    model_cases = [
        run_context_eval.ContextCase(
            id=case["id"],
            kind=case["kind"],
            category=case["category"],
            target=case["target"],
            before=case.get("before", ""),
            after=case.get("after", ""),
            references=tuple(case["references"]),
            unacceptable=tuple(case.get("unacceptable", [])),
            pair_id=case.get("pair_id"),
        )
        for case in cases
    ]
    adapter = run_context_eval.HyMTAdapter(model_id)
    system_prompt = run_context_eval.system_prompt(model_id)
    warmup_started = time.perf_counter()
    adapter.translate(
        run_context_eval.build_prompt(model_cases[0], "m0"),
        system=system_prompt,
    )
    warmup_seconds = time.perf_counter() - warmup_started

    rows: dict[str, dict[str, Any]] = {}
    for index, case in enumerate(model_cases, start=1):
        started = time.perf_counter()
        try:
            output = adapter.translate(
                run_context_eval.build_prompt(case, "m0"),
                system=system_prompt,
            )
            extracted, extraction = run_context_eval.extract_target_output(
                output
            )
            error = ""
        except Exception as exc:
            output = ""
            extracted = ""
            extraction = ""
            error = f"{type(exc).__name__}: {exc}"
        elapsed_ms = (time.perf_counter() - started) * 1000
        rows[case.id] = {
            "output": extracted,
            "raw_output": output,
            "extraction": extraction,
            "latency_ms": round(elapsed_ms, 4),
            "error": error,
        }
        print(
            f"[{index:03d}/{len(model_cases)}] {case.id} "
            f"{case.target} -> {extracted or '<error>'} "
            f"({elapsed_ms:.1f}ms)",
            flush=True,
        )
    return rows, {
        "hy_model_id": model_id,
        "hy_warmup_seconds": round(warmup_seconds, 4),
    }


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = min(
        len(ordered) - 1,
        max(0, round((len(ordered) - 1) * fraction)),
    )
    return round(ordered[index], 4)


def summarize(
    cases: list[dict[str, Any]],
    rows: list[dict[str, Any]],
) -> dict[str, Any]:
    grouped: defaultdict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        grouped[row["variant"]].append(row)

    result: dict[str, Any] = {}
    for variant, variant_rows in grouped.items():
        latencies = [
            row["latency_ms"]
            for row in variant_rows
            if row["latency_ms"] is not None
        ]
        categories: dict[str, Any] = {}
        for category in ("polysemy", "business", "sentence", "control"):
            category_rows = [
                row for row in variant_rows
                if row["category"] == category
            ]
            categories[category] = {
                "top1": sum(row["top1"] for row in category_rows),
                "top3": sum(row["top3"] for row in category_rows),
                "total": len(category_rows),
            }
        result[variant] = {
            "case_count": len(variant_rows),
            "top1": sum(row["top1"] for row in variant_rows),
            "top1_rate": (
                sum(row["top1"] for row in variant_rows)
                / len(variant_rows)
            ),
            "top3": sum(row["top3"] for row in variant_rows),
            "top3_rate": (
                sum(row["top3"] for row in variant_rows)
                / len(variant_rows)
            ),
            "coverage": sum(row["coverage"] for row in variant_rows),
            "invalid": sum(
                not row["candidates"] for row in variant_rows
            ),
            "p50_latency_ms": percentile(latencies, 0.50),
            "p95_latency_ms": percentile(latencies, 0.95),
            "categories": categories,
        }
    return {
        "case_count": len(cases),
        "variants": result,
    }


def render_markdown(result: dict[str, Any]) -> str:
    summary = result["summary"]
    lines = [
        "# Product Held-Out Evaluation",
        "",
        f"- Date: {result['generated_at']}",
        f"- Cases: {summary['case_count']}",
        "- Sources excluded from tuning: runtime overrides and M8",
        "",
        "| Variant | Top 1 | Top 3 | Coverage | p95 |",
        "| --- | ---: | ---: | ---: | ---: |",
    ]
    for name, stats in summary["variants"].items():
        p95 = (
            f"{stats['p95_latency_ms']:.2f}ms"
            if stats["p95_latency_ms"] is not None
            else "precomputed"
        )
        lines.append(
            f"| {name} | {stats['top1']}/{stats['case_count']} "
            f"({stats['top1_rate']:.1%}) | "
            f"{stats['top3']}/{stats['case_count']} "
            f"({stats['top3_rate']:.1%}) | "
            f"{stats['coverage']}/{stats['case_count']} | {p95} |"
        )
    lines.extend(
        [
            "",
            "## Categories",
            "",
            "| Variant | Polysemy | Business | Sentence | Control |",
            "| --- | ---: | ---: | ---: | ---: |",
        ]
    )
    for name, stats in summary["variants"].items():
        cells = []
        for category in ("polysemy", "business", "sentence", "control"):
            value = stats["categories"][category]
            cells.append(f"{value['top1']}/{value['total']}")
        lines.append(f"| {name} | {' | '.join(cells)} |")
    lines.append("")
    return "\n".join(lines)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cases", default=str(CASES_PATH))
    parser.add_argument("--route-choices", default=str(ROUTE_PATH))
    parser.add_argument("--qwen-result", default=str(QWEN_PATH))
    parser.add_argument("--hy-model-id", default=DEFAULT_HY_MODEL)
    parser.add_argument("--output", default=str(OUTPUT_PATH))
    parser.add_argument("--skip-model", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    cases = load_cases(Path(args.cases))
    case_ids = {case["id"] for case in cases}
    route_choices = load_route_choices(Path(args.route_choices))
    qwen_rows = load_frozen_model_rows(Path(args.qwen_result), "m2")
    missing_qwen = sorted(case_ids - set(qwen_rows))
    if missing_qwen:
        raise ValueError(
            "frozen Qwen results are missing cases: "
            + ", ".join(missing_qwen)
        )

    hy_rows: dict[str, dict[str, Any]] = {}
    model_metadata: dict[str, Any] = {}
    if not args.skip_model:
        hy_rows, model_metadata = run_hy_target_only(
            cases,
            args.hy_model_id,
        )

    rows: list[dict[str, Any]] = []
    for case in cases:
        case_id = case["id"]
        references = case["references"]
        unacceptable = case.get("unacceptable", [])
        route = route_choices[case_id]
        qwen = qwen_rows[case_id]
        qwen_output = qwen.get("target_output") or qwen.get("output", "")
        variants: list[tuple[str, list[str], float | None]] = [
            ("dictionary_first", route, None),
            (
                "qwen_context",
                [qwen_output],
                qwen.get("latency_ms"),
            ),
            (
                "qwen_context_plus_dictionary",
                merge_candidates([qwen_output], route),
                qwen.get("latency_ms"),
            ),
        ]
        if hy_rows:
            hy = hy_rows[case_id]
            variants.extend(
                [
                    (
                        "dictionary_first_with_model_fallback",
                        route or [hy["output"]],
                        hy["latency_ms"] if not route else None,
                    ),
                    (
                        "hy_target_only",
                        [hy["output"]],
                        hy["latency_ms"],
                    ),
                    (
                        "hy_model_first_plus_dictionary",
                        merge_candidates([hy["output"]], route),
                        hy["latency_ms"],
                    ),
                ]
            )
        for variant, candidates, latency in variants:
            visible = visible_candidates(candidates)
            coverage, top1, top3, reason = score(
                visible,
                references,
                unacceptable,
            )
            rows.append(
                {
                    "id": case_id,
                    "category": case["category"],
                    "target": case["target"],
                    "variant": variant,
                    "candidates": visible,
                    "coverage": coverage,
                    "top1": top1,
                    "top3": top3,
                    "reason": reason,
                    "latency_ms": latency,
                }
            )

    result = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "source_commit": "96edcfd",
        "excluded_targets": ["学生", "苹果", "谢谢", "里程碑"],
        **model_metadata,
        "qwen_model_id": "mlx-community/Qwen3-4B-Instruct-2507-4bit",
        "summary": summarize(cases, rows),
        "rows": rows,
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    markdown = render_markdown(result)
    output.with_suffix(".md").write_text(markdown + "\n", encoding="utf-8")
    print(markdown)
    print(f"saved {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
