#!/usr/bin/env python3
"""Build a research candidate bank from open dictionary sources."""

from __future__ import annotations

import argparse
import gzip
import json
import re
import sqlite3
import unicodedata
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path


SOURCE_WEIGHT = {
    "cedict": 3,
    "wiktionary": 2,
    "ecdict": 1,
}

LOW_VALUE_PREFIXES = (
    "a surname",
    "abbr. for",
    "old variant",
    "surname ",
    "variant of",
    "see ",
)


@dataclass
class Candidate:
    text: str
    sources: set[str] = field(default_factory=set)
    details: list[dict] = field(default_factory=list)

    @property
    def normalized(self) -> str:
        return normalize(self.text)

    @property
    def weight(self) -> int:
        return max(SOURCE_WEIGHT.get(source, 0) for source in self.sources)


def normalize(text: str) -> str:
    text = unicodedata.normalize("NFKC", text).lower().strip()
    text = re.sub(r"[^a-z0-9]+", " ", text).strip()
    return re.sub(r"\s+", " ", text)


def clean_sense(text: str) -> str | None:
    text = re.sub(r"\s+", " ", text).strip(" /;")
    if not text or re.search(r"[\u3400-\u9fff]", text):
        return None
    lowered = text.lower()
    if any(lowered.startswith(prefix) for prefix in LOW_VALUE_PREFIXES):
        return None
    return text


def split_senses(text: str) -> list[str]:
    senses: list[str] = []
    for part in re.split(r"\s*;\s*", text):
        cleaned = clean_sense(part)
        if cleaned and cleaned not in senses:
            senses.append(cleaned)
    return senses


def add_candidate(
    candidates: dict[str, Candidate],
    text: str,
    source: str,
    detail: dict,
) -> None:
    for sense in split_senses(text):
        key = normalize(sense)
        if not key:
            continue
        candidate = candidates.setdefault(key, Candidate(text=sense))
        candidate.sources.add(source)
        candidate.details.append(
            {
                "source": source,
                **detail,
            }
        )


def load_cases(path: Path) -> list[dict]:
    cases = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(cases, list):
        raise ValueError("cases must be a JSON array")
    return cases


def load_cedict(
    path: Path,
    targets: set[str],
    candidates_by_target: dict[str, dict[str, Candidate]],
) -> int:
    line_pattern = re.compile(
        r"^(\S+)\s+(\S+)\s+\[([^\]]+)\]\s+/(.*)/$"
    )
    count = 0
    with gzip.open(path, "rt", encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("#"):
                continue
            match = line_pattern.match(line.rstrip("\n"))
            if not match:
                continue
            traditional, simplified, reading, gloss = match.groups()
            matching_targets = targets.intersection(
                {traditional, simplified}
            )
            if not matching_targets:
                continue
            for target in matching_targets:
                for sense in gloss.split("/"):
                    add_candidate(
                        candidates_by_target[target],
                        sense,
                        "cedict",
                        {
                            "reading": reading,
                            "traditional": traditional,
                            "simplified": simplified,
                        },
                    )
                    count += 1
    return count


def load_ecdict(
    path: Path,
    targets: set[str],
    candidates_by_target: dict[str, dict[str, Candidate]],
) -> int:
    connection = sqlite3.connect(path)
    count = 0
    try:
        for target in targets:
            rows = connection.execute(
                """
                SELECT english, frequency, collins, oxford
                FROM ranks
                WHERE term = ?
                ORDER BY frequency ASC, english
                LIMIT 32
                """,
                (target,),
            )
            for english, frequency, collins, oxford in rows:
                add_candidate(
                    candidates_by_target[target],
                    english,
                    "ecdict",
                    {
                        "frequency": frequency,
                        "collins": collins,
                        "oxford": oxford,
                    },
                )
                count += 1
    finally:
        connection.close()
    return count


def load_wiktionary(
    path: Path,
    targets: set[str],
    candidates_by_target: dict[str, dict[str, Candidate]],
) -> int:
    connection = sqlite3.connect(path)
    count = 0
    try:
        for target in targets:
            rows = connection.execute(
                """
                SELECT target, part_of_speech, frequency, source_order
                FROM entries
                WHERE source = ?
                  AND source_lang IN ('zh-Hans', 'zh')
                  AND target_lang = 'en'
                ORDER BY
                  COALESCE(frequency, 2147483647),
                  COALESCE(source_order, 2147483647),
                  target
                LIMIT 64
                """,
                (target,),
            )
            for english, part_of_speech, frequency, source_order in rows:
                add_candidate(
                    candidates_by_target[target],
                    english,
                    "wiktionary",
                    {
                        "part_of_speech": part_of_speech,
                        "frequency": frequency,
                        "source_order": source_order,
                    },
                )
                count += 1
    finally:
        connection.close()
    return count


def reference_in_candidates(
    references: list[str],
    candidates: list[Candidate],
) -> bool:
    candidate_keys = {candidate.normalized for candidate in candidates}
    return any(normalize(reference) in candidate_keys for reference in references)


def build_bank(
    cases: list[dict],
    candidates_by_target: dict[str, dict[str, Candidate]],
    source_paths: dict[str, str],
    source_counts: dict[str, int],
) -> dict:
    by_target: dict[str, list[Candidate]] = {}
    for target, candidates in candidates_by_target.items():
        by_target[target] = sorted(
            candidates.values(),
            key=lambda candidate: (
                -candidate.weight,
                candidate.text.lower(),
            ),
        )

    entries: dict[str, dict] = {}
    coverage_cases = 0
    coverage_correct = 0
    coverage_two_plus = 0
    for case in cases:
        target_candidates = by_target.get(case["target"], [])
        texts: list[str] = []
        seen: set[str] = set()
        for candidate in target_candidates:
            if candidate.normalized in seen:
                continue
            seen.add(candidate.normalized)
            texts.append(candidate.text)
            if len(texts) >= 8:
                break
        entries[case["id"]] = {
            "target": case["target"],
            "category": case["category"],
            "references": case.get("references", []),
            "choices": texts,
        }
        if len(texts) >= 2:
            coverage_two_plus += 1
        if reference_in_candidates(
            case.get("references", []),
            target_candidates,
        ):
            coverage_correct += 1
        coverage_cases += 1

    target_output = {}
    for target, candidates in sorted(by_target.items()):
        target_output[target] = [
            {
                "text": candidate.text,
                "sources": sorted(candidate.sources),
                "details": candidate.details,
            }
            for candidate in candidates
        ]

    return {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "sources": source_paths,
        "source_counts": source_counts,
        "coverage": {
            "case_count": coverage_cases,
            "eligible_two_plus": coverage_two_plus,
            "correct_reference_present": coverage_correct,
        },
        "candidates": target_output,
        "entries": entries,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cedict-gz", required=True)
    parser.add_argument("--ecdict-db", required=True)
    parser.add_argument("--wiktionary-db", required=True)
    parser.add_argument("--cases", required=True)
    parser.add_argument("--output", required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    cases = load_cases(Path(args.cases))
    targets = {case["target"] for case in cases}
    candidates_by_target = {
        target: {}
        for target in targets
    }
    source_counts = {
        "cedict": load_cedict(
            Path(args.cedict_gz),
            targets,
            candidates_by_target,
        ),
        "ecdict": load_ecdict(
            Path(args.ecdict_db),
            targets,
            candidates_by_target,
        ),
        "wiktionary": load_wiktionary(
            Path(args.wiktionary_db),
            targets,
            candidates_by_target,
        ),
    }
    bank = build_bank(
        cases,
        candidates_by_target,
        {
            "cedict": args.cedict_gz,
            "ecdict": args.ecdict_db,
            "wiktionary": args.wiktionary_db,
        },
        source_counts,
    )
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(bank, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(
        "targets={targets} candidates={candidates} "
        "eligible={eligible}/{cases} correct={correct}".format(
            targets=len(targets),
            candidates=sum(
                len(values)
                for values in bank["candidates"].values()
            ),
            eligible=bank["coverage"]["eligible_two_plus"],
            cases=bank["coverage"]["case_count"],
            correct=bank["coverage"]["correct_reference_present"],
        )
    )


if __name__ == "__main__":
    main()
