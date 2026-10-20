#!/usr/bin/env python3
"""Build a Glint sqlite-v1 dictionary from Kaikki's Chinese JSONL.

The source data is extracted from English Wiktionary and is available under
CC BY-SA 4.0 and GFDL. The generated manifest keeps the attribution and
license fields; retain them when redistributing the package.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sqlite3
import sys
import urllib.request
from pathlib import Path

DEFAULT_URL = (
    "https://kaikki.org/dictionary/Chinese/"
    "kaikki.org-dictionary-Chinese.jsonl"
)
HAN = re.compile(r"[\u3400-\u9fff]")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--url", default=DEFAULT_URL)
    parser.add_argument("--max-lines", type=int, default=0)
    return parser.parse_args()


def clean_gloss(value: str) -> str:
    value = re.sub(r"\s+", " ", value).strip()
    value = re.sub(r"^\([^)]*\)\s*", "", value)
    return value.strip(" ;,.")


def iter_lines(args: argparse.Namespace):
    if args.input:
        with args.input.open("r", encoding="utf-8") as source:
            yield from source
    else:
        request = urllib.request.Request(
            args.url,
            headers={"User-Agent": "Glint dictionary builder/0.1"},
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            for raw in response:
                yield raw.decode("utf-8", errors="replace")


def main() -> None:
    args = parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    database_path = args.output / "dictionary.sqlite3"
    database_path.unlink(missing_ok=True)
    database = sqlite3.connect(database_path)
    database.execute(
        """
        CREATE TABLE entries (
          source TEXT NOT NULL,
          target TEXT NOT NULL,
          source_lang TEXT NOT NULL,
          target_lang TEXT NOT NULL,
          part_of_speech TEXT,
          frequency INTEGER,
          source_order INTEGER,
          UNIQUE(source, target, source_lang, target_lang)
        )
        """
    )
    database.execute(
        "CREATE INDEX entries_lookup ON entries(source_lang, target_lang, source)"
    )

    row_count = 0
    source_count = 0
    for line_number, line in enumerate(iter_lines(args), 1):
        if args.max_lines and line_number > args.max_lines:
            break
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        word = (record.get("word") or "").strip()
        if (
            record.get("lang_code") != "zh"
            or not HAN.search(word)
            or record.get("pos") in {"soft-redirect", "romanization"}
        ):
            continue

        glosses = []
        for sense in record.get("senses") or []:
            for gloss in sense.get("glosses") or []:
                cleaned = clean_gloss(gloss)
                if cleaned and HAN.search(cleaned) is None:
                    glosses.append(cleaned)
        if not glosses:
            continue

        source_count += 1
        unique_glosses = list(dict.fromkeys(glosses))[:5]
        for order, gloss in enumerate(unique_glosses):
            database.execute(
                """
                INSERT OR IGNORE INTO entries
                (source, target, source_lang, target_lang,
                 part_of_speech, frequency, source_order)
                VALUES (?, ?, 'zh-Hans', 'en', ?, NULL, ?)
                """,
                (word, gloss, record.get("pos"), order),
            )

    database.commit()
    row_count = database.total_changes
    database.close()
    digest = hashlib.sha256(database_path.read_bytes()).hexdigest()
    manifest = {
        "id": "dict-wiktionary-zh-en",
        "type": "dictionary",
        "name": "Wiktionary Chinese-English",
        "version": "2026.10",
        "runtime": "sqlite-v1",
        "capabilities": ["word", "phrase"],
        "languages": ["zh-Hans", "en"],
        "sizeBytes": database_path.stat().st_size,
        "sha256": digest,
        "url": "file:///tmp/dict-wiktionary-zh-en.zip",
        "license": "CC-BY-SA-4.0 AND GFDL",
        "minRAMBytes": 0,
        "quality": "broad",
        "recommended": False,
        "summary": "Wiktionary 开放词典，覆盖大量中文词语和短语；需保留署名与相同方式共享许可。",
    }
    (args.output / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"created: {args.output}", file=sys.stderr)
    print(f"source entries: {source_count}", file=sys.stderr)
    print(f"rows: {row_count}", file=sys.stderr)


if __name__ == "__main__":
    main()
