#!/usr/bin/env python3
from __future__ import annotations

import json
import statistics
import time
from pathlib import Path

from paddleocr import TextRecognition


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "Tools/OCRLab/data/manifest.json"
RESULTS = ROOT / "Tools/OCRLab/results"
MODELS = ["PP-OCRv6_tiny_rec", "PP-OCRv6_small_rec"]


def clean(text: str) -> str:
    return "".join(char for char in text if char.isalpha())


def main() -> None:
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))["records"]
    RESULTS.mkdir(parents=True, exist_ok=True)
    for model_name in MODELS:
        loaded_at = time.perf_counter()
        model = TextRecognition(
            model_name=model_name,
            engine="onnxruntime",
            device="cpu",
        )
        load_seconds = time.perf_counter() - loaded_at
        output = []
        for _ in range(5):
            model.predict(input=manifest[0]["path"], batch_size=1)
        for record in manifest:
            times = []
            text = ""
            score = 0.0
            for _ in range(3):
                started = time.perf_counter()
                result = model.predict(input=record["path"], batch_size=1)[0]
                times.append((time.perf_counter() - started) * 1000)
                payload = result.json["res"]
                text = payload["rec_text"]
                score = float(payload["rec_score"])
            output.append(
                {
                    **record,
                    "raw": text,
                    "cleaned": clean(text),
                    "confidence": score,
                    "timesMs": times,
                }
            )
        path = RESULTS / f"{model_name.lower()}.json"
        path.write_text(
            json.dumps(output, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        all_times = [value for item in output for value in item["timesMs"]]
        print(
            f"{model_name}: load={load_seconds:.2f}s "
            f"warm_p50={statistics.median(all_times):.2f}ms "
            f"p95={statistics.quantiles(all_times, n=20)[18]:.2f}ms"
        )


if __name__ == "__main__":
    main()
