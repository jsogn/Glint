#!/usr/bin/env python3
"""Merge dictionary and generated candidates into one research bank."""

from __future__ import annotations

import argparse
import json
import re
import unicodedata
from datetime import datetime, timezone
from pathlib import Path


def normalize(text: str) -> str:
    text = unicodedata.normalize("NFKC", text).lower()
    text = re.sub(r"[^a-z0-9]+", " ", text).strip()
    return re.sub(r"\s+", " ", text)


def merge(
    bank: dict,
    generated: dict,
    maximum_choices: int,
    gold: dict[str, list[str]] | None = None,
    preferred_source: str = "dictionary",
) -> dict:
    if preferred_source not in {"dictionary", "generated"}:
        raise ValueError(f"unknown preferred source: {preferred_source}")
    output = json.loads(json.dumps(bank))
    output["generated_at"] = datetime.now(timezone.utc).isoformat()
    output["generated_sources"] = {
        "model_id": generated.get("model_id"),
        "validated": False,
    }
    source_counts = output.setdefault("source_counts", {})
    source_counts["generated"] = sum(
        len(entry.get("candidates", []))
        for entry in generated.get("entries", {}).values()
    )

    coverage = output.setdefault("coverage", {})
    correct = 0
    gold_correct = 0
    gold_cases = 0
    choice_count = 0
    accepted_choice_count = 0
    eligible = 0
    cases = generated.get("entries", {})
    for case_id, entry in output.get("entries", {}).items():
        existing = entry.get("choices", [])
        generated_entry = cases.get(case_id, {})
        generated_values = generated_entry.get("candidates", [])
        values: list[str] = []
        seen: set[str] = set()
        values_in_order = (
            [*existing, *generated_values]
            if preferred_source == "dictionary"
            else [*generated_values, *existing]
        )
        for value in values_in_order:
            key = normalize(value)
            if key and key not in seen:
                seen.add(key)
                values.append(value)
        entry["choices"] = values[:maximum_choices]
        selected_keys = {
            normalize(value)
            for value in entry["choices"]
        }
        if len(entry["choices"]) >= 2:
            eligible += 1
        references = generated_entry.get("references", [])
        if any(
            normalize(reference) in selected_keys
            for reference in references
        ):
            correct += 1
        if gold is not None and case_id in gold:
            gold_cases += 1
            choice_count += len(selected_keys)
            accepted_keys = {
                normalize(value)
                for value in gold[case_id]
            }
            accepted_choice_count += len(
                selected_keys & accepted_keys
            )
            if selected_keys & accepted_keys:
                gold_correct += 1
    coverage["merged_eligible_two_plus"] = eligible
    coverage["generated_reference_present"] = correct
    if gold is not None:
        coverage["gold_case_count"] = gold_cases
        coverage["gold_correct_option_available"] = gold_correct
        coverage["gold_choice_precision"] = (
            accepted_choice_count / choice_count
            if choice_count
            else None
        )
    return output


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bank", required=True)
    parser.add_argument("--generated", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--gold-file", default="")
    parser.add_argument(
        "--preferred-source",
        choices=["dictionary", "generated"],
        default="dictionary",
    )
    parser.add_argument("--maximum-choices", type=int, default=12)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    bank = json.loads(Path(args.bank).read_text(encoding="utf-8"))
    generated = json.loads(
        Path(args.generated).read_text(encoding="utf-8")
    )
    gold = None
    if args.gold_file:
        gold = json.loads(
            Path(args.gold_file).read_text(encoding="utf-8")
        )["cases"]
    merged = merge(
        bank,
        generated,
        max(2, args.maximum_choices),
        gold,
        args.preferred_source,
    )
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(merged, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    message = (
        "eligible={eligible}/{cases} generated_reference={correct}".format(
            eligible=merged["coverage"]["merged_eligible_two_plus"],
            cases=merged["coverage"]["case_count"],
            correct=merged["coverage"]["generated_reference_present"],
        )
    )
    if gold is not None:
        message += (
            " gold={gold}/{gold_cases} precision={precision:.1%}"
        ).format(
            gold=merged["coverage"]["gold_correct_option_available"],
            gold_cases=merged["coverage"]["gold_case_count"],
            precision=merged["coverage"]["gold_choice_precision"],
        )
    print(message)


if __name__ == "__main__":
    main()
