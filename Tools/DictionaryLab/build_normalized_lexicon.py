#!/usr/bin/env python3
"""Build a normalized research lexicon without collapsing polysemy."""

from __future__ import annotations

import argparse
import gzip
import json
import re
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


CEDICT_PATTERN = re.compile(
    r"^(\S+)\s+(\S+)\s+\[([^\]]+)\]\s+/(.*)/$"
)
SCHEMA_VERSION = 2


@dataclass(frozen=True)
class CedicEntry:
    traditional: str
    simplified: str
    pinyin: str
    definitions: tuple[str, ...]


def parse_cedict_line(line: str) -> CedicEntry | None:
    match = CEDICT_PATTERN.match(line.rstrip("\n"))
    if not match:
        return None
    traditional, simplified, pinyin, raw_definitions = match.groups()
    definitions = tuple(
        value.strip()
        for value in raw_definitions.split("/")
        if value.strip()
    )
    if not definitions:
        return None
    return CedicEntry(
        traditional=traditional,
        simplified=simplified,
        pinyin=pinyin,
        definitions=definitions,
    )


def create_schema(connection: sqlite3.Connection) -> None:
    connection.executescript(
        """
        PRAGMA journal_mode = OFF;
        PRAGMA synchronous = OFF;

        CREATE TABLE metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE lexicon_entries (
            sense_id INTEGER PRIMARY KEY,
            headword TEXT NOT NULL,
            traditional TEXT NOT NULL,
            pinyin TEXT,
            definition TEXT NOT NULL,
            part_of_speech TEXT,
            source TEXT NOT NULL,
            source_priority INTEGER NOT NULL,
            source_order INTEGER NOT NULL,
            sense_order INTEGER NOT NULL,
            frequency INTEGER
        );

        CREATE INDEX idx_lexicon_headword
            ON lexicon_entries(
                headword,
                source_priority DESC,
                frequency,
                source_order,
                sense_order
            );

        CREATE INDEX idx_lexicon_traditional
            ON lexicon_entries(
                traditional,
                source_priority DESC,
                frequency,
                source_order,
                sense_order
            );

        CREATE TABLE rankings (
            term TEXT NOT NULL,
            english TEXT NOT NULL,
            frequency INTEGER NOT NULL,
            collins INTEGER NOT NULL,
            oxford INTEGER NOT NULL,
            PRIMARY KEY (term, english)
        );

        CREATE INDEX idx_rankings_term
            ON rankings(term, frequency);
        """
    )


def load_cedict(
    connection: sqlite3.Connection,
    path: Path,
) -> tuple[int, int, dict[str, str]]:
    variants: dict[str, set[str]] = {}
    rows: list[tuple] = []
    matched = 0
    sense_count = 0
    with gzip.open(path, "rt", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if line.startswith("#"):
                continue
            entry = parse_cedict_line(line)
            if entry is None:
                continue
            matched += 1
            variants.setdefault(entry.traditional, set()).add(
                entry.simplified
            )
            for sense_order, definition in enumerate(
                entry.definitions
            ):
                rows.append(
                    (
                        entry.simplified,
                        entry.traditional,
                        entry.pinyin,
                        definition,
                        None,
                        "cedict",
                        30,
                        line_number,
                        sense_order,
                        None,
                    )
                )
                sense_count += 1
    connection.executemany(
        """
        INSERT INTO lexicon_entries(
            headword,
            traditional,
            pinyin,
            definition,
            part_of_speech,
            source,
            source_priority,
            source_order,
            sense_order,
            frequency
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        rows,
    )
    resolved_variants = {
        traditional: next(iter(simplified_values))
        for traditional, simplified_values in variants.items()
        if len(simplified_values) == 1
    }
    return matched, sense_count, resolved_variants


def load_wiktionary(
    connection: sqlite3.Connection,
    path: Path,
    variants: dict[str, str],
) -> int:
    source = sqlite3.connect(path)
    source.row_factory = sqlite3.Row
    rows: list[tuple] = []
    try:
        cursor = source.execute(
            """
            SELECT
                source,
                target,
                part_of_speech,
                frequency,
                source_order
            FROM entries
            WHERE source_lang IN ('zh-Hans', 'zh')
              AND target_lang = 'en'
            ORDER BY source, source_order, target
            """
        )
        for row in cursor:
            traditional = row["source"]
            headword = variants.get(traditional, traditional)
            rows.append(
                (
                    headword,
                    traditional,
                    None,
                    row["target"],
                    row["part_of_speech"],
                    "wiktionary",
                    20,
                    row["source_order"] or 0,
                    0,
                    row["frequency"],
                )
            )
    finally:
        source.close()
    connection.executemany(
        """
        INSERT INTO lexicon_entries(
            headword,
            traditional,
            pinyin,
            definition,
            part_of_speech,
            source,
            source_priority,
            source_order,
            sense_order,
            frequency
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        rows,
    )
    return len(rows)


def load_rankings(
    connection: sqlite3.Connection,
    path: Path,
) -> int:
    source = sqlite3.connect(path)
    try:
        rows = source.execute(
            """
            SELECT term, english, frequency, collins, oxford
            FROM ranks
            """
        ).fetchall()
    finally:
        source.close()
    connection.executemany(
        """
        INSERT INTO rankings(
            term,
            english,
            frequency,
            collins,
            oxford
        ) VALUES (?, ?, ?, ?, ?)
        """,
        rows,
    )
    return len(rows)


def build(
    cedict_path: Path,
    wiktionary_path: Path,
    ecdict_path: Path,
    output_path: Path,
) -> dict:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    if output_path.exists():
        output_path.unlink()
    connection = sqlite3.connect(output_path)
    try:
        create_schema(connection)
        cedict_entries, cedict_senses, variants = load_cedict(
            connection,
            cedict_path,
        )
        wiktionary_senses = load_wiktionary(
            connection,
            wiktionary_path,
            variants,
        )
        ranking_rows = load_rankings(connection, ecdict_path)
        total_senses = connection.execute(
            "SELECT COUNT(*) FROM lexicon_entries"
        ).fetchone()[0]
        distinct_headwords = connection.execute(
            "SELECT COUNT(DISTINCT headword) FROM lexicon_entries"
        ).fetchone()[0]
        metadata = {
            "schema_version": SCHEMA_VERSION,
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "cedict_entries": cedict_entries,
            "cedict_senses": cedict_senses,
            "wiktionary_senses": wiktionary_senses,
            "ranking_rows": ranking_rows,
            "total_senses": total_senses,
            "distinct_headwords": distinct_headwords,
        }
        connection.executemany(
            "INSERT INTO metadata(key, value) VALUES (?, ?)",
            [
                (key, json.dumps(value, ensure_ascii=False))
                for key, value in metadata.items()
            ],
        )
        connection.execute(
            f"PRAGMA user_version = {SCHEMA_VERSION}"
        )
        connection.commit()
    finally:
        connection.close()
    metadata["database_bytes"] = output_path.stat().st_size
    return metadata


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cedict-gz", required=True)
    parser.add_argument("--wiktionary-db", required=True)
    parser.add_argument("--ecdict-db", required=True)
    parser.add_argument("--output", required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    metadata = build(
        cedict_path=Path(args.cedict_gz),
        wiktionary_path=Path(args.wiktionary_db),
        ecdict_path=Path(args.ecdict_db),
        output_path=Path(args.output),
    )
    print(json.dumps(metadata, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
