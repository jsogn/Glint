#!/usr/bin/env python3
"""Evaluate static overrides against dictionary and contextual model paths."""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
import time
import unicodedata
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from benchmark_lexicon import normalize_candidate, normalized_candidates


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CASES = ROOT / "Tools/DictionaryLab/eval/override_stress_cases.json"
DEFAULT_OVERRIDES = ROOT / "Resources/Dictionary/overrides.json"
DEFAULT_LEXICON = ROOT / "build/dictionary-core/normalized_lexicon.sqlite3"
DEFAULT_CURRENT_CHOICES = (
    ROOT / "Tools/DictionaryLab/results/current-route-choices.json"
)
DEFAULT_OUTPUT = (
    ROOT / "Tools/DictionaryLab/results/override-ablation.json"
)
DEFAULT_MODEL_ID = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
MODEL_LAB_EVAL = ROOT / "Tools/ModelLab/eval"


@dataclass(frozen=True)
class StressCase:
    id: str
    pair_id: str
    target: str
    before: str
    after: str
    references: tuple[str, ...]
    unacceptable: tuple[str, ...]
    role: str


def load_overrides(path: Path) -> dict[str, list[str]]:
    document = json.loads(path.read_text(encoding="utf-8"))
    raw = {
        **document.get("retiredOverrides", {}),
        **document.get("overrides", {}),
    }
    values: dict[str, list[str]] = {}
    for term, value in raw.items():
        items = [value] if isinstance(value, str) else value
        if (
            not isinstance(items, list)
            or not items
            or not all(isinstance(item, str) and item.strip() for item in items)
        ):
            raise ValueError(f"invalid override for {term!r}")
        values[term] = [item.strip() for item in items]
    return values


def load_cases(
    path: Path,
    overrides: dict[str, list[str]],
) -> list[StressCase]:
    raw_document = json.loads(path.read_text(encoding="utf-8"))
    raw_cases = raw_document.get("cases")
    if not isinstance(raw_cases, list):
        raise ValueError("override stress corpus must contain a cases array")

    cases: list[StressCase] = []
    ids: set[str] = set()
    pair_counts: defaultdict[str, int] = defaultdict(int)
    pair_targets: defaultdict[str, set[str]] = defaultdict(set)
    pair_roles: defaultdict[str, set[str]] = defaultdict(set)
    target_pairs: defaultdict[str, set[str]] = defaultdict(set)
    for index, raw in enumerate(raw_cases):
        if not isinstance(raw, dict):
            raise ValueError(f"case {index} must be an object")
        case_id = raw.get("id")
        pair_id = raw.get("pair_id")
        target = raw.get("target")
        if not isinstance(case_id, str) or not case_id.strip():
            raise ValueError(f"case {index} has an invalid id")
        if case_id in ids:
            raise ValueError(f"duplicate case id: {case_id}")
        ids.add(case_id)
        if not isinstance(pair_id, str) or not pair_id.strip():
            raise ValueError(f"{case_id}: pair_id must be non-empty")
        if not isinstance(target, str) or not target.strip():
            raise ValueError(f"{case_id}: target must be non-empty")
        target = target.strip()
        if target not in overrides:
            raise ValueError(
                f"{case_id}: target {target!r} is not a runtime override"
            )
        references = raw.get("references")
        unacceptable = raw.get("unacceptable", [])
        if not isinstance(references, list) or not references or not all(
            isinstance(value, str) and value.strip()
            for value in references
        ):
            raise ValueError(f"{case_id}: references must be non-empty")
        if not isinstance(unacceptable, list) or not all(
            isinstance(value, str) and value.strip()
            for value in unacceptable
        ):
            raise ValueError(f"{case_id}: unacceptable must be strings")
        before = raw.get("before", "")
        after = raw.get("after", "")
        if not isinstance(before, str) or not isinstance(after, str):
            raise ValueError(f"{case_id}: context must be strings")
        if case_id.endswith("-aligned"):
            role = "aligned"
        elif case_id.endswith("-conflict"):
            role = "conflict"
        else:
            raise ValueError(
                f"{case_id}: id must end in -aligned or -conflict"
            )
        cases.append(
            StressCase(
                id=case_id,
                pair_id=pair_id,
                target=target,
                before=before,
                after=after,
                references=tuple(references),
                unacceptable=tuple(unacceptable),
                role=role,
            )
        )
        pair_counts[pair_id] += 1
        pair_targets[pair_id].add(target)
        pair_roles[pair_id].add(role)
        target_pairs[target].add(pair_id)

    invalid_pairs = sorted(
        pair_id
        for pair_id, count in pair_counts.items()
        if count != 2
    )
    if invalid_pairs:
        raise ValueError(
            "pair_id values must occur exactly twice: "
            + ", ".join(invalid_pairs)
        )
    invalid_targets = sorted(
        pair_id
        for pair_id, targets in pair_targets.items()
        if len(targets) != 1
    )
    if invalid_targets:
        raise ValueError(
            "paired cases must share one target: "
            + ", ".join(invalid_targets)
        )
    invalid_roles = sorted(
        pair_id
        for pair_id, roles in pair_roles.items()
        if roles != {"aligned", "conflict"}
    )
    if invalid_roles:
        raise ValueError(
            "each pair needs one aligned and one conflict case: "
            + ", ".join(invalid_roles)
        )
    repeated_targets = sorted(
        target for target, pairs in target_pairs.items() if len(pairs) != 1
    )
    if repeated_targets:
        raise ValueError(
            "each target must have exactly one pair: "
            + ", ".join(repeated_targets)
        )
    return cases


def load_current_choices(
    path: Path,
    cases: list[StressCase],
) -> dict[str, list[str]]:
    raw = json.loads(path.read_text(encoding="utf-8"))["entries"]
    choices = {
        target: list(entry.get("choices", []))
        for target, entry in raw.items()
    }
    missing = sorted({case.target for case in cases} - set(choices))
    if missing:
        raise ValueError(
            "current route choices are missing targets: "
            + ", ".join(missing)
        )
    return choices


def prediction_status(
    prediction: str,
    case: StressCase,
) -> tuple[str, str]:
    cleaned = unicodedata.normalize("NFKC", prediction).strip()
    if not cleaned:
        return "invalid", "empty"
    if "\n" in cleaned:
        return "invalid", "multiple_lines"
    if any("\u3400" <= character <= "\u9fff" for character in cleaned):
        return "invalid", "chinese_output"
    key = normalize_candidate(cleaned)
    references = {normalize_candidate(value) for value in case.references}
    if key in references:
        return "acceptable", ""
    unacceptable = {
        normalize_candidate(value) for value in case.unacceptable
    }
    if key in unacceptable:
        return "incorrect", "listed_unacceptable"
    return "incorrect", "not_in_reference_set"


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = min(
        len(ordered) - 1,
        max(0, round((len(ordered) - 1) * fraction)),
    )
    return round(ordered[index], 4)


def dictionary_predictions(
    connection: sqlite3.Connection,
    target: str,
    rank: bool,
) -> list[str]:
    return normalized_candidates(
        connection,
        target,
        source=None,
        rank=rank,
    )


def merge_candidates(*groups: list[str]) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for group in groups:
        for value in group:
            key = normalize_candidate(value)
            if key and key not in seen:
                seen.add(key)
                result.append(value)
    return result


def visible_candidates(
    candidates: list[str],
    max_characters: int = 48,
) -> list[str]:
    selected: list[str] = []
    length = 0
    for candidate in candidates[:3]:
        separator_length = 3 if selected else 0
        proposed_length = length + separator_length + len(candidate)
        if selected and proposed_length > max_characters:
            break
        selected.append(candidate)
        length = proposed_length
    return selected


def make_row(
    case: StressCase,
    variant: str,
    candidates: list[str],
    latency_ms: float | None,
    raw_output: str = "",
) -> dict[str, Any]:
    candidates = [
        candidate.strip()
        for candidate in candidates
        if candidate.strip()
    ]
    prediction = candidates[0] if candidates else ""
    status, reason = prediction_status(prediction, case)
    visible = visible_candidates(candidates)
    top3_status = (
        "acceptable"
        if any(
            prediction_status(candidate, case)[0] == "acceptable"
            for candidate in visible
        )
        else status
    )
    return {
        "id": case.id,
        "pair_id": case.pair_id,
        "target": case.target,
        "role": case.role,
        "variant": variant,
        "references": list(case.references),
        "candidates": candidates[:6],
        "visible_candidates": visible,
        "prediction": prediction,
        "raw_output": raw_output,
        "status": status,
        "top3_status": top3_status,
        "reason": reason,
        "latency_ms": latency_ms,
    }


def run_static_variants(
    cases: list[StressCase],
    overrides: dict[str, list[str]],
    lexicon: sqlite3.Connection,
    current_choices: dict[str, list[str]] | None,
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    dictionary_by_term: dict[str, list[str]] = {}
    for case in cases:
        dictionary_by_term[case.target] = dictionary_predictions(
            lexicon,
            case.target,
            rank=True,
        )
    for case in cases:
        started = time.perf_counter()
        candidates = (
            current_choices[case.target]
            if current_choices is not None
            else merge_candidates(
                overrides[case.target],
                dictionary_by_term[case.target],
            )
        )
        elapsed_ms = (time.perf_counter() - started) * 1000
        rows.append(
            make_row(
                case,
                "current_override",
                candidates,
                round(elapsed_ms, 4),
            )
        )

        for variant, rank in (
            ("dictionary_unranked", False),
            ("dictionary_ranked", True),
        ):
            started = time.perf_counter()
            candidates = dictionary_predictions(
                lexicon,
                case.target,
                rank,
            )
            elapsed_ms = (time.perf_counter() - started) * 1000
            rows.append(
                make_row(
                    case,
                    variant,
                    candidates,
                    round(elapsed_ms, 4),
                )
            )
    return rows


def load_model_evaluator():
    sys.path.insert(0, str(MODEL_LAB_EVAL))
    import run_context_eval

    return run_context_eval


def run_model_variants(
    cases: list[StressCase],
    model_id: str,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    evaluator = load_model_evaluator()
    model_cases = [
        evaluator.ContextCase(
            id=case.id,
            kind="word",
            category=case.role,
            target=case.target,
            before=case.before,
            after=case.after,
            references=case.references,
            unacceptable=case.unacceptable,
            pair_id=case.pair_id,
        )
        for case in cases
    ]
    by_id = {case.id: case for case in cases}

    adapter = evaluator.HyMTAdapter(model_id)
    system_prompt = evaluator.system_prompt(model_id)
    started = time.perf_counter()
    adapter.translate(
        evaluator.build_prompt(model_cases[0], "m2"),
        system=system_prompt,
    )
    warmup_seconds = time.perf_counter() - started

    rows: list[dict[str, Any]] = []
    for index, model_case in enumerate(model_cases, start=1):
        case = by_id[model_case.id]
        for variant, prompt_variant, label in (
            ("model_target_only", "m0", "target-only"),
            ("model_context", "m2", "context"),
        ):
            started = time.perf_counter()
            try:
                output = adapter.translate(
                    evaluator.build_prompt(model_case, prompt_variant),
                    system=system_prompt,
                )
                extracted, _ = evaluator.extract_target_output(output)
                prediction = extracted.strip()
                error = ""
            except Exception as exc:
                output = ""
                prediction = ""
                error = f"{type(exc).__name__}: {exc}"
            elapsed_ms = (time.perf_counter() - started) * 1000
            row = make_row(
                case,
                variant,
                [prediction],
                round(elapsed_ms, 4),
                output,
            )
            if error:
                row["status"] = "error"
                row["reason"] = error
            rows.append(row)
            print(
                f"[{index:02d}/{len(cases)}] {case.id} "
                f"{label} -> {prediction or '<error>'} "
                f"({row['status']}, {elapsed_ms:.1f}ms)",
                flush=True,
            )
    metadata = {
        "model_id": model_id,
        "warmup_seconds": round(warmup_seconds, 4),
    }
    return rows, metadata


def add_hybrid_rows(
    cases: list[StressCase],
    rows: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    current = {
        row["id"]: row
        for row in rows
        if row["variant"] == "current_override"
    }
    hybrid_rows: list[dict[str, Any]] = []
    by_id = {case.id: case for case in cases}
    for row in list(rows):
        if row["variant"] not in {
            "model_target_only",
            "model_context",
        }:
            continue
        case = by_id[row["id"]]
        candidates = merge_candidates(
            [row["prediction"]] if row["prediction"] else [],
            current[row["id"]]["candidates"],
        )
        hybrid_rows.append(
            make_row(
                case,
                f"{row['variant']}_plus_dictionary",
                candidates,
                row["latency_ms"],
                row["raw_output"],
            )
        )
    return hybrid_rows


def summarize(
    cases: list[StressCase],
    rows: list[dict[str, Any]],
) -> dict[str, Any]:
    by_variant: defaultdict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        by_variant[row["variant"]].append(row)

    summary: dict[str, Any] = {}
    for variant, variant_rows in by_variant.items():
        latencies = [
            row["latency_ms"]
            for row in variant_rows
            if row["latency_ms"] is not None
        ]
        roles = {
            role: [
                row for row in variant_rows if row["role"] == role
            ]
            for role in ("aligned", "conflict")
        }
        pair_scores: defaultdict[str, int] = defaultdict(int)
        pair_top3_scores: defaultdict[str, int] = defaultdict(int)
        for row in variant_rows:
            pair_scores[row["pair_id"]] += row["status"] == "acceptable"
            pair_top3_scores[row["pair_id"]] += (
                row["top3_status"] == "acceptable"
            )
        summary[variant] = {
            "case_count": len(variant_rows),
            "acceptable": sum(
                row["status"] == "acceptable" for row in variant_rows
            ),
            "acceptable_rate": (
                sum(
                    row["status"] == "acceptable"
                    for row in variant_rows
                )
                / len(variant_rows)
            ),
            "top3_acceptable": sum(
                row["top3_status"] == "acceptable"
                for row in variant_rows
            ),
            "top3_acceptable_rate": (
                sum(
                    row["top3_status"] == "acceptable"
                    for row in variant_rows
                )
                / len(variant_rows)
            ),
            "invalid": sum(
                row["status"] in {"invalid", "error"}
                for row in variant_rows
            ),
            "aligned_acceptable": sum(
                row["status"] == "acceptable" for row in roles["aligned"]
            ),
            "conflict_acceptable": sum(
                row["status"] == "acceptable" for row in roles["conflict"]
            ),
            "conflict_count": len(roles["conflict"]),
            "conflict_top3_acceptable": sum(
                row["top3_status"] == "acceptable"
                for row in roles["conflict"]
            ),
            "paired_both_acceptable": sum(
                score == 2 for score in pair_scores.values()
            ),
            "paired_both_top3_acceptable": sum(
                score == 2 for score in pair_top3_scores.values()
            ),
            "pair_count": len(pair_scores),
            "p50_latency_ms": percentile(latencies, 0.50),
            "p95_latency_ms": percentile(latencies, 0.95),
        }

    current = {
        row["id"]: row["status"] == "acceptable"
        for row in by_variant["current_override"]
    }
    current_top3 = {
        row["id"]: row["top3_status"] == "acceptable"
        for row in by_variant["current_override"]
    }
    pair_current: defaultdict[str, int] = defaultdict(int)
    pair_current_top3: defaultdict[str, int] = defaultdict(int)
    for row in by_variant["current_override"]:
        pair_current[row["pair_id"]] += row["status"] == "acceptable"
        pair_current_top3[row["pair_id"]] += (
            row["top3_status"] == "acceptable"
        )
    comparisons: dict[str, Any] = {}
    for variant, variant_rows in by_variant.items():
        if variant == "current_override":
            continue
        wins = losses = ties = 0
        pair_wins = pair_losses = pair_ties = 0
        top3_wins = top3_losses = top3_ties = 0
        pair_top3_wins = pair_top3_losses = pair_top3_ties = 0
        variant_by_pair: defaultdict[str, int] = defaultdict(int)
        variant_top3_by_pair: defaultdict[str, int] = defaultdict(int)
        for row in variant_rows:
            variant_by_pair[row["pair_id"]] += row["status"] == "acceptable"
            variant_top3_by_pair[row["pair_id"]] += (
                row["top3_status"] == "acceptable"
            )
            candidate = row["status"] == "acceptable"
            baseline = current[row["id"]]
            if candidate and not baseline:
                wins += 1
            elif baseline and not candidate:
                losses += 1
            else:
                ties += 1
            candidate_top3 = row["top3_status"] == "acceptable"
            baseline_top3 = current_top3[row["id"]]
            if candidate_top3 and not baseline_top3:
                top3_wins += 1
            elif baseline_top3 and not candidate_top3:
                top3_losses += 1
            else:
                top3_ties += 1
        for pair_id, score in variant_by_pair.items():
            baseline = pair_current[pair_id]
            if score > baseline:
                pair_wins += 1
            elif score < baseline:
                pair_losses += 1
            else:
                pair_ties += 1
            top3_score = variant_top3_by_pair[pair_id]
            top3_baseline = pair_current_top3[pair_id]
            if top3_score > top3_baseline:
                pair_top3_wins += 1
            elif top3_score < top3_baseline:
                pair_top3_losses += 1
            else:
                pair_top3_ties += 1
        comparisons[variant] = {
            "case_wins": wins,
            "case_losses": losses,
            "case_ties": ties,
            "pair_wins": pair_wins,
            "pair_losses": pair_losses,
            "pair_ties": pair_ties,
            "top3_case_wins": top3_wins,
            "top3_case_losses": top3_losses,
            "top3_case_ties": top3_ties,
            "top3_pair_wins": pair_top3_wins,
            "top3_pair_losses": pair_top3_losses,
            "top3_pair_ties": pair_top3_ties,
        }

    return {
        "case_count": len(cases),
        "pair_count": len({case.pair_id for case in cases}),
        "variants": summary,
        "versus_current_override": comparisons,
    }


def render_markdown(result: dict[str, Any]) -> str:
    summary = result["summary"]
    lines = [
        "# Override Ablation",
        "",
        f"- Date: {result['generated_at']}",
        f"- Model: `{result.get('model_id', 'not run')}`",
        f"- Cases: {summary['case_count']} "
        f"({summary['pair_count']} paired targets)",
        "- Corpus: adversarial override stress set",
        "",
        "| Variant | Top 1 | Top 3 | Aligned 1/3 | "
        "Conflict 1/3 | Both in pair 1/3 | p95 |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for name, stats in summary["variants"].items():
        p95 = (
            f"{stats['p95_latency_ms']:.4f}ms"
            if stats["p95_latency_ms"] is not None
            else "n/a"
        )
        lines.append(
            f"| {name} | {stats['acceptable']}/{stats['case_count']} "
            f"({stats['acceptable_rate']:.1%}) | "
            f"{stats['top3_acceptable']}/{stats['case_count']} "
            f"({stats['top3_acceptable_rate']:.1%}) | "
            f"{stats['aligned_acceptable']}/{stats['pair_count']} | "
            f"{stats['conflict_acceptable']}/{stats['conflict_count']} / "
            f"{stats['conflict_top3_acceptable']} | "
            f"{stats['paired_both_acceptable']}/{stats['pair_count']} / "
            f"{stats['paired_both_top3_acceptable']} | "
            f"{p95} |"
        )
    lines.extend(
        [
            "",
            "## Paired Comparison vs Current Override",
            "",
            "| Variant | Top-1 pair W/L/T | Top-3 pair W/L/T |",
            "| --- | ---: | ---: |",
        ]
    )
    for name, comparison in summary["versus_current_override"].items():
        lines.append(
            f"| {name} | {comparison['pair_wins']}/"
            f"{comparison['pair_losses']}/{comparison['pair_ties']} | "
            f"{comparison['top3_pair_wins']}/"
            f"{comparison['top3_pair_losses']}/"
            f"{comparison['top3_pair_ties']} |"
        )
    lines.append("")
    return "\n".join(lines)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cases", default=str(DEFAULT_CASES))
    parser.add_argument("--overrides", default=str(DEFAULT_OVERRIDES))
    parser.add_argument("--lexicon", default=str(DEFAULT_LEXICON))
    parser.add_argument(
        "--current-choices",
        default=str(DEFAULT_CURRENT_CHOICES),
        help="DictionaryChoices output; use an empty value to disable",
    )
    parser.add_argument("--model-id", default=DEFAULT_MODEL_ID)
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT))
    parser.add_argument("--skip-model", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    overrides = load_overrides(Path(args.overrides))
    cases = load_cases(Path(args.cases), overrides)
    print(
        f"cases={len(cases)} pairs={len({case.pair_id for case in cases})}"
    )
    if args.dry_run:
        print("dry-run valid")
        return 0

    lexicon_path = Path(args.lexicon)
    if not lexicon_path.is_file():
        raise FileNotFoundError(
            f"normalized lexicon not found: {lexicon_path}"
        )
    current_choices = None
    if args.current_choices:
        current_choices = load_current_choices(
            Path(args.current_choices),
            cases,
        )
    lexicon = sqlite3.connect(lexicon_path)
    try:
        rows = run_static_variants(
            cases,
            overrides,
            lexicon,
            current_choices,
        )
    finally:
        lexicon.close()

    model_metadata: dict[str, Any] = {}
    if not args.skip_model:
        model_rows, model_metadata = run_model_variants(
            cases,
            args.model_id,
        )
        rows.extend(model_rows)
        rows.extend(add_hybrid_rows(cases, rows))

    result = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "cases": str(Path(args.cases)),
        "overrides": str(Path(args.overrides)),
        "lexicon": str(lexicon_path),
        "current_choices": args.current_choices or None,
        **model_metadata,
        "summary": summarize(cases, rows),
        "rows": rows,
    }
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    markdown = render_markdown(result)
    output_path.with_suffix(".md").write_text(
        markdown + "\n",
        encoding="utf-8",
    )
    print(markdown)
    print(f"saved {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
