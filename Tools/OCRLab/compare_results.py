#!/usr/bin/env python3
from __future__ import annotations

import json
import statistics
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
RESULTS = ROOT / "Tools/OCRLab/results"
REPORT = RESULTS / "report.md"


def edit_distance(left: str, right: str) -> int:
    previous = list(range(len(right) + 1))
    for row, left_char in enumerate(left, 1):
        current = [row]
        for column, right_char in enumerate(right, 1):
            current.append(
                min(
                    current[-1] + 1,
                    previous[column] + 1,
                    previous[column - 1] + (left_char != right_char),
                )
            )
        previous = current
    return previous[-1]


def summarize(items: list[dict], group: str | None = None) -> dict:
    selected = [
        item for item in items if group is None or item["group"] == group
    ]
    exact = sum(item["cleaned"] == item["text"] for item in selected)
    errors = sum(
        edit_distance(item["cleaned"], item["text"]) for item in selected
    )
    characters = sum(max(1, len(item["text"])) for item in selected)
    times = [value for item in selected for value in item["timesMs"]]
    return {
        "count": len(selected),
        "exact": exact,
        "exactRate": exact / max(1, len(selected)),
        "cer": errors / max(1, characters),
        "p50": statistics.median(times),
        "p95": statistics.quantiles(times, n=20)[18],
    }


def main() -> None:
    files = {
        "Apple Vision": RESULTS / "vision.json",
        "PP-OCRv6 tiny": RESULTS / "pp-ocrv6_tiny_rec.json",
        "PP-OCRv6 small": RESULTS / "pp-ocrv6_small_rec.json",
    }
    data = {}
    for label, path in files.items():
        items = json.loads(path.read_text(encoding="utf-8"))
        data[label] = {
            "all": summarize(items),
            "real": summarize(items, "real"),
            "real_augmented": summarize(items, "real_augmented"),
            "synthetic": summarize(items, "synthetic"),
        }

    lines = [
        "# OCR benchmark",
        "",
        "Environment: Apple M4 Pro, 48GB RAM, macOS 26.5.",
        "",
        "Scope: recognition-only. Text detection and blue-capsule detection are "
        "excluded because Glint already provides the candidate crop. The set "
        "contains one real candidate screenshot, four variants of that screenshot, "
        "and 400 controlled synthetic candidates.",
        "",
        "| Backend | Scope | Exact match | CER | p50 | p95 |",
        "| --- | --- | ---: | ---: | ---: | ---: |",
    ]
    scopes = [
        ("all", "all"),
        ("real", "real screenshot"),
        ("real_augmented", "real screenshot variants"),
        ("synthetic", "synthetic variants"),
    ]
    for label, groups in data.items():
        for key, name in scopes:
            value = groups[key]
            lines.append(
                f"| {label} | {name} | "
                f"{value['exactRate'] * 100:.2f}% ({value['exact']}/{value['count']}) | "
                f"{value['cer'] * 100:.2f}% | "
                f"{value['p50']:.2f}ms | {value['p95']:.2f}ms |"
            )

    failures = []
    for label, path in files.items():
        items = json.loads(path.read_text(encoding="utf-8"))
        for item in items:
            if item["cleaned"] != item["text"]:
                failures.append(
                    (
                        label,
                        item["id"],
                        item["text"],
                        item["raw"],
                        item["cleaned"],
                        item["confidence"],
                    )
                )
    lines.extend(["", "## Failures", ""])
    if failures:
        for failure in failures[:80]:
            lines.append(
                f"- {failure[0]} `{failure[1]}` expected `{failure[2]}` "
                f"raw `{failure[3]}` cleaned `{failure[4]}` "
                f"score={failure[5]:.4f}"
            )
    else:
        lines.append("No failures.")

    lines.extend(
        [
            "",
            "## Notes",
            "",
            "- The current full OCRService pipeline correctly read the original "
            "real screenshot as `你好`; the isolated re-encoded crop returned only "
            "`1` to Vision, so Vision is sensitive to crop and encoding context.",
            "- Synthetic results validate model behavior and relative latency, "
            "but they are not a substitute for a larger real-screen corpus.",
            "- Latency covers image decode, model preprocessing, and recognition. "
            "It excludes screenshot capture, blue-capsule detection, and a future "
            "Swift-to-ONNX Runtime bridge.",
        ]
    )

    REPORT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines[:20]))
    print(f"wrote {REPORT}")


if __name__ == "__main__":
    main()
