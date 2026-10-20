#!/usr/bin/env python3
"""Build a compact Chinese-term → English-headword ranking index from ECDICT.

Only terms present in CC-CEDICT are kept, so this is a ranking layer rather
than a second full dictionary shown in the HUD.
"""

from __future__ import annotations

import csv
import re
import sqlite3
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
ECDICT = ROOT / "Vendor" / "ECDICT" / "ecdict.csv"
OUT = ROOT / "Resources" / "Plugins" / "dict-ecdict" / "ecdict_rank.sqlite3"

CHINESE_RE = re.compile(r"[\u4e00-\u9fff]{2,6}")
STOP_TERMS = {
    "一个", "一种", "一些", "所有", "每个", "自己", "其他", "以及", "对于",
    "关于", "根据", "由于", "可以", "进行", "表示", "用于", "通过", "没有",
    "不是", "就是", "因为", "所以", "如果", "但是", "而且", "然后", "其中",
    "这个", "那个", "什么", "怎么", "这样", "那样", "我们", "他们", "她们",
    "你们", "这些", "那些", "等等", "一个", "一种", "以及", "或者", "并且",
}


def parse_frequency(row: dict[str, str]) -> int:
    for key in ("frq", "bnc"):
        try:
            value = int(row.get(key) or 0)
        except ValueError:
            value = 0
        if value > 0:
            return value
    return 500_000


def main() -> None:
    candidates: dict[str, dict[str, tuple[int, int, int]]] = {}
    parsed = 0
    with ECDICT.open(encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            word = (row.get("word") or "").strip()
            translation = (row.get("translation") or "").replace("\\n", "\n")
            if not word or not translation or any("\u4e00" <= c <= "\u9fff" for c in word):
                continue
            if len(word) > 32:
                continue
            frequency = parse_frequency(row)
            if frequency > 200_000:
                continue
            try:
                collins = int(row.get("collins") or 0)
            except ValueError:
                collins = 0
            oxford = 1 if (row.get("oxford") or "").strip() else 0

            terms = set()
            for part in re.split(r"[;\n；，,/]", translation):
                for term in CHINESE_RE.findall(part):
                    if term not in STOP_TERMS:
                        terms.add(term)
            if not terms:
                continue
            parsed += 1
            for term in terms:
                bucket = candidates.setdefault(term, {})
                previous = bucket.get(word)
                value = (frequency, collins, oxford)
                if previous is None or value > previous:
                    bucket[word] = value

    OUT.parent.mkdir(parents=True, exist_ok=True)
    if OUT.exists():
        OUT.unlink()
    db = sqlite3.connect(OUT)
    db.execute(
        """
        CREATE TABLE ranks (
            term TEXT NOT NULL,
            english TEXT NOT NULL,
            frequency INTEGER NOT NULL,
            collins INTEGER NOT NULL,
            oxford INTEGER NOT NULL,
            PRIMARY KEY (term, english)
        )
        """
    )
    rows = []
    for term, bucket in candidates.items():
        ranked = sorted(
            bucket.items(),
            key=lambda item: (
                item[1][0],
                -item[1][1],
                -item[1][2],
                len(item[0]),
                item[0],
            ),
        )[:8]
        for english, (frequency, collins, oxford) in ranked:
            rows.append((term, english, frequency, collins, oxford))
    db.executemany(
        "INSERT INTO ranks(term, english, frequency, collins, oxford) VALUES (?, ?, ?, ?, ?)",
        rows,
    )
    db.execute("CREATE INDEX idx_ranks_term ON ranks(term, frequency)")
    db.commit()
    db.close()
    size_mb = OUT.stat().st_size / (1024 * 1024)
    print(f"parsed_rows={parsed} terms={len(candidates)} rows={len(rows)} size={size_mb:.1f}MB")


if __name__ == "__main__":
    main()
