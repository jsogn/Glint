#!/usr/bin/env python3
"""Build the schema-v2 read-only CC-CEDICT SQLite dictionary."""

from __future__ import annotations

import argparse
import gzip
import re
import sqlite3
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_OUTPUT = (
    ROOT / "Resources" / "Plugins" / "dict-cedict" / "cedict.sqlite3"
)
SCHEMA_VERSION = 2
ENTRY_PATTERN = re.compile(
    r"^(\S+)\s+(\S+)\s+\[([^\]]+)\]\s+/(.*)/$"
)


def parse_entry(line: str) -> tuple[str, str, str, tuple[str, ...]] | None:
    match = ENTRY_PATTERN.match(line.rstrip("\n"))
    if match is None:
        return None
    traditional, simplified, pinyin, raw_gloss = match.groups()
    senses = tuple(
        sense.strip()
        for sense in raw_gloss.split("/")
        if sense.strip()
    )
    if not senses:
        return None
    return traditional, simplified, pinyin, senses


def create_schema(connection: sqlite3.Connection) -> None:
    connection.executescript(
        """
        PRAGMA journal_mode = OFF;
        PRAGMA synchronous = OFF;

        CREATE TABLE metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE entries (
            sense_id INTEGER PRIMARY KEY,
            simplified TEXT NOT NULL,
            traditional TEXT NOT NULL,
            pinyin TEXT NOT NULL,
            gloss TEXT NOT NULL,
            line_order INTEGER NOT NULL,
            sense_order INTEGER NOT NULL
        );

        CREATE INDEX idx_entries_simplified
            ON entries(simplified, line_order, sense_order);

        CREATE INDEX idx_entries_traditional
            ON entries(traditional, line_order, sense_order);
        """
    )
    connection.executemany(
        "INSERT INTO metadata(key, value) VALUES (?, ?)",
        (
            ("schema", "cc-cedict-senses-v2"),
            ("source", "CC-CEDICT"),
            ("license", "CC-BY-SA-4.0"),
        ),
    )


def build(source_gz: Path, output: Path) -> tuple[int, int]:
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(".sqlite3.tmp")
    temporary.unlink(missing_ok=True)
    connection = sqlite3.connect(temporary)
    entry_count = 0
    sense_count = 0
    try:
        create_schema(connection)
        with gzip.open(source_gz, "rt", encoding="utf-8") as handle:
            for line in handle:
                if line.startswith("#"):
                    continue
                parsed = parse_entry(line)
                if parsed is None:
                    continue
                traditional, simplified, pinyin, senses = parsed
                entry_count += 1
                connection.executemany(
                    """
                    INSERT INTO entries(
                        simplified,
                        traditional,
                        pinyin,
                        gloss,
                        line_order,
                        sense_order
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    (
                        (
                            simplified,
                            traditional,
                            pinyin,
                            gloss,
                            entry_count,
                            sense_order,
                        )
                        for sense_order, gloss in enumerate(senses)
                    ),
                )
                sense_count += len(senses)
        connection.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
        connection.commit()
    finally:
        connection.close()

    temporary.replace(output)
    return entry_count, sense_count


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cedict-gz", required=True)
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT))
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    entries, senses = build(
        Path(args.cedict_gz),
        Path(args.output),
    )
    output = Path(args.output)
    print(
        f"entries={entries} senses={senses} "
        f"bytes={output.stat().st_size} db={output}"
    )


if __name__ == "__main__":
    main()
