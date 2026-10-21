#!/usr/bin/env python3
"""Generate supplementary context candidates for research."""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MODEL_EVAL = ROOT / "Tools" / "ModelLab" / "eval"
sys.path.insert(0, str(MODEL_EVAL))

from run_context_eval import (  # noqa: E402
    GENERAL_MODEL_SYSTEM_PROMPT,
    HyMTAdapter,
    load_cases,
    percentile,
)
from run_context_rerank import normalize_choice  # noqa: E402


DEFAULT_MODEL_ID = "mlx-community/Qwen3-4B-Instruct-2507-4bit"

PROMPTS = (
    (
        "direct",
        "句子：{sentence}\n"
        "目标词：{target}\n"
        "请根据语境列出目标词最可能的3个英文翻译候选。"
        "每行一个，只输出候选，不要解释，不要翻译整句。",
        3,
    ),
    (
        "compound_aware",
        "句子：{sentence}\n"
        "目标词：{target}\n"
        "如果目标词是复合词的一部分，请先根据整句确定复合词，"
        "再给出目标词在该语境中的英文候选。"
        "列出3个候选，每行一个，只输出候选，不要解释，不要翻译整句。",
        3,
    ),
)


def parse_candidate_lines(
    text: str,
    limit: int = 3,
) -> list[str]:
    values: list[str] = []
    seen: set[str] = set()
    for raw_line in text.splitlines():
        line = raw_line.strip().strip("-*0123456789.`\"'“”‘’ ")
        line = re.sub(r"\s+", " ", line).strip()
        if not line or len(line) > 64 or re.search(r"[\u3400-\u9fff]", line):
            continue
        key = line.lower()
        if key in seen:
            continue
        seen.add(key)
        values.append(line)
        if len(values) >= limit:
            break
    return values


def build_prompt(case, prompt_template: str) -> str:
    sentence = f"{case.before}【{case.target}】{case.after}"
    return prompt_template.format(
        sentence=sentence,
        target=case.target,
    )


def load_gold(path: Path) -> dict[str, list[str]]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    cases = raw.get("cases")
    if not isinstance(cases, dict):
        raise ValueError("gold file must contain a cases object")
    return {
        case_id: list(values)
        for case_id, values in cases.items()
    }


def evaluate_candidates(
    entries: dict,
    gold: dict[str, list[str]],
) -> dict:
    generated = 0
    accepted = 0
    top1_hits = 0
    available = 0
    prompt_stats = {
        prompt_name: {
            "generated": 0,
            "accepted": 0,
            "top1_hits": 0,
        }
        for prompt_name, _, _ in PROMPTS
    }
    for case_id, entry in entries.items():
        accepted_values = {
            normalize_choice(value)
            for value in gold.get(case_id, entry["references"])
        }
        candidate_keys = [
            normalize_choice(value)
            for value in entry["candidates"]
        ]
        generated += len(candidate_keys)
        accepted += sum(
            value in accepted_values
            for value in candidate_keys
        )
        top1_hits += bool(
            candidate_keys
            and candidate_keys[0] in accepted_values
        )
        available += bool(set(candidate_keys) & accepted_values)
        for generation in entry["generations"]:
            keys = [
                normalize_choice(value)
                for value in generation["candidates"]
            ]
            stats = prompt_stats[generation["prompt"]]
            stats["generated"] += len(keys)
            stats["accepted"] += sum(
                value in accepted_values
                for value in keys
            )
            stats["top1_hits"] += bool(
                keys and keys[0] in accepted_values
            )

    case_count = len(entries)
    return {
        "case_count": case_count,
        "available": available,
        "recall": available / case_count if case_count else None,
        "candidate_precision": (
            accepted / generated if generated else None
        ),
        "top1_accuracy": (
            top1_hits / case_count if case_count else None
        ),
        "prompts": {
            name: {
                **stats,
                "precision": (
                    stats["accepted"] / stats["generated"]
                    if stats["generated"]
                    else None
                ),
                "top1_accuracy": (
                    stats["top1_hits"] / case_count
                    if case_count
                    else None
                ),
            }
            for name, stats in prompt_stats.items()
        },
    }


def run(args: argparse.Namespace) -> int:
    cases = [
        case
        for case in load_cases(Path(args.cases))
        if case.category == "polysemy"
    ]
    if args.limit:
        cases = cases[: args.limit]
    if args.dry_run:
        for case in cases:
            for _, template, _ in PROMPTS:
                build_prompt(case, template)
        print(f"dry-run valid cases={len(cases)}")
        return 0
    if not args.output:
        raise ValueError("--output is required unless --dry-run is used")
    gold = (
        load_gold(Path(args.gold_file))
        if args.gold_file
        else {}
    )

    print("loading model...", flush=True)
    adapter = HyMTAdapter(args.model_id)
    entries = {}
    total = len(cases) * len(PROMPTS)
    completed = 0
    for case in cases:
        candidates: list[str] = []
        sources = []
        for prompt_name, template, limit in PROMPTS:
            prompt = build_prompt(case, template)
            started = time.perf_counter()
            output = adapter.translate(
                prompt,
                system=GENERAL_MODEL_SYSTEM_PROMPT,
            )
            elapsed_ms = (time.perf_counter() - started) * 1000
            parsed = parse_candidate_lines(output, limit)
            candidates.extend(parsed)
            sources.append(
                {
                    "prompt": prompt_name,
                    "output": output,
                    "candidates": parsed,
                    "latency_ms": round(elapsed_ms, 2),
                }
            )
            completed += 1
            print(
                f"[{completed:03d}/{total}] {case.id} "
                f"{prompt_name} -> {parsed} ({elapsed_ms:.1f}ms)",
                flush=True,
            )
        deduped = []
        seen = set()
        for candidate in candidates:
            key = candidate.lower()
            if key not in seen:
                seen.add(key)
                deduped.append(candidate)
        entries[case.id] = {
            "target": case.target,
            "category": case.category,
            "references": list(case.references),
            "candidates": deduped,
            "generations": sources,
        }

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    latencies = [
        generation["latency_ms"]
        for entry in entries.values()
        for generation in entry["generations"]
    ]
    evaluation = (
        evaluate_candidates(entries, gold)
        if gold
        else None
    )
    output.write_text(
        json.dumps(
            {
                "generated_at": datetime.now(timezone.utc).isoformat(),
                "model_id": args.model_id,
                "validated": False,
                "p50_latency_ms": round(
                    percentile(latencies, 0.50),
                    2,
                ),
                "p95_latency_ms": round(
                    percentile(latencies, 0.95),
                    2,
                ),
                "evaluation": evaluation,
                "entries": entries,
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
    print(f"saved {output}")
    if evaluation:
        print(
            "recall={available}/{cases} precision={precision:.1%} "
            "top1={top1:.1%}".format(
                available=evaluation["available"],
                cases=evaluation["case_count"],
                precision=evaluation["candidate_precision"],
                top1=evaluation["top1_accuracy"],
            )
        )
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--model-id",
        default=DEFAULT_MODEL_ID,
    )
    parser.add_argument(
        "--cases",
        default=str(
            ROOT / "Tools/ModelLab/eval/context_cases.json"
        ),
    )
    parser.add_argument("--output", default="")
    parser.add_argument("--gold-file", default="")
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


if __name__ == "__main__":
    raise SystemExit(run(parse_args()))
