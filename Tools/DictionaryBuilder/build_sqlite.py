#!/usr/bin/env python3
"""Compatibility wrapper for the authoritative Swift CC-CEDICT builder."""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_OUTPUT = (
    ROOT / "Resources" / "Plugins" / "dict-cedict" / "cedict.sqlite3"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cedict-gz", required=True)
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT))
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
            "cedict",
            "--input",
            args.cedict_gz,
            "--output",
            args.output,
        ],
        check=True,
    )


if __name__ == "__main__":
    main()
