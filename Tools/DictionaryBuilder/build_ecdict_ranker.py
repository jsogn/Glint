#!/usr/bin/env python3
"""Compatibility wrapper for the authoritative Swift ECDICT builder."""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_INPUT = ROOT / "Vendor" / "ECDICT" / "ecdict.csv"
DEFAULT_OUTPUT = (
    ROOT
    / "Resources"
    / "Plugins"
    / "dict-ecdict"
    / "ecdict_rank.sqlite3"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--source-checksum", default="")
    parser.add_argument("--source-date", default="")
    parser.add_argument("--source-revision", default="")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    subprocess.run(
        [
            "swift",
            "run",
            "--package-path",
            str(ROOT / "Packages" / "GlintDictionary"),
            "glint-dictionary-builder",
            "ecdict",
            "--input",
            str(args.csv.resolve()),
            "--output",
            str(args.output.resolve()),
            "--source-checksum",
            args.source_checksum,
            "--source-date",
            args.source_date,
            "--source-revision",
            args.source_revision,
        ],
        check=True,
    )


if __name__ == "__main__":
    main()
