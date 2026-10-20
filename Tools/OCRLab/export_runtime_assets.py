#!/usr/bin/env python3
from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]
MODEL_SOURCE = (
    Path.home()
    / ".paddlex/official_models/PP-OCRv6_small_rec_onnx"
)
RUNTIME_SOURCE = (
    ROOT
    / "Tools/OCRLab/.venv/lib/python3.11/site-packages/onnxruntime/capi"
    / "libonnxruntime.1.31.0.dylib"
)
PLUGIN_DESTINATION = ROOT / "PluginAssets/ocr-ppocrv6-small"
MODEL_DESTINATION = PLUGIN_DESTINATION / "model"
CHARACTERS_DESTINATION = ROOT / "Resources/OCR/PP-OCRv6"
RUNTIME_DESTINATION = ROOT / "Resources/ONNXRuntime"
ONNXRUNTIME_SOURCE = Path("/tmp/onnxruntime-src.nqoxPX")
PADDLEOCR_SOURCE = Path("/tmp/PaddleOCR-src.bMysxs")


def main() -> None:
    if not (MODEL_SOURCE / "inference.onnx").is_file():
        raise SystemExit(f"missing model: {MODEL_SOURCE}")
    if not RUNTIME_SOURCE.is_file():
        raise SystemExit(f"missing ONNX Runtime: {RUNTIME_SOURCE}")

    MODEL_DESTINATION.mkdir(parents=True, exist_ok=True)
    CHARACTERS_DESTINATION.mkdir(parents=True, exist_ok=True)
    RUNTIME_DESTINATION.mkdir(parents=True, exist_ok=True)

    shutil.copy2(MODEL_SOURCE / "inference.onnx", MODEL_DESTINATION / "model.onnx")
    shutil.copy2(MODEL_SOURCE / "README.md", MODEL_DESTINATION / "README.md")
    shutil.copy2(MODEL_SOURCE / "inference.yml", MODEL_DESTINATION / "inference.yml")

    config = yaml.safe_load((MODEL_SOURCE / "inference.yml").read_text())
    characters = config["PostProcess"]["character_dict"]
    (CHARACTERS_DESTINATION / "characters.json").write_text(
        json.dumps(characters, ensure_ascii=False),
        encoding="utf-8",
    )

    shutil.copy2(
        RUNTIME_SOURCE,
        RUNTIME_DESTINATION / "libonnxruntime.1.dylib",
    )
    subprocess.run(
        [
            "codesign",
            "--force",
            "--sign",
            "-",
            str(RUNTIME_DESTINATION / "libonnxruntime.1.dylib"),
        ],
        check=True,
    )
    if PADDLEOCR_SOURCE.is_dir():
        model_license = subprocess.run(
            ["git", "-C", str(PADDLEOCR_SOURCE), "show", "HEAD:LICENSE"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        (MODEL_DESTINATION / "LICENSE.txt").write_text(
            model_license,
            encoding="utf-8",
        )
        (CHARACTERS_DESTINATION / "LICENSE.txt").write_text(
            model_license,
            encoding="utf-8",
        )
        shutil.copy2(
            MODEL_DESTINATION / "README.md",
            CHARACTERS_DESTINATION / "README.md",
        )

    if ONNXRUNTIME_SOURCE.is_dir():
        runtime_license = subprocess.run(
            ["git", "-C", str(ONNXRUNTIME_SOURCE), "show", "HEAD:LICENSE"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        (RUNTIME_DESTINATION / "LICENSE.txt").write_text(
            runtime_license,
            encoding="utf-8",
        )

    print(
        f"model={MODEL_DESTINATION} chars={len(characters)} "
        f"chars_dir={CHARACTERS_DESTINATION} runtime={RUNTIME_DESTINATION}"
    )


if __name__ == "__main__":
    main()
