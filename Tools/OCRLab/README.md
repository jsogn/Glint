# Glint OCR Benchmark

Compares Apple Vision and PP-OCRv6 recognition-only models on the same
candidate crops.

The benchmark intentionally omits PaddleOCR text detection because Glint
already locates the blue candidate capsule. The real screenshot is kept
separate from generated font/scale/background variants.

```bash
uv venv --python 3.11 Tools/OCRLab/.venv
uv pip install --python Tools/OCRLab/.venv/bin/python \
  paddlepaddle paddleocr onnxruntime pillow numpy opencv-contrib-python
```

```bash
Tools/OCRLab/.venv/bin/python Tools/OCRLab/generate_dataset.py
swift Tools/OCRLab/vision_benchmark.swift
PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK=True \
  Tools/OCRLab/.venv/bin/python Tools/OCRLab/benchmark_paddle.py
Tools/OCRLab/.venv/bin/python Tools/OCRLab/compare_results.py
```

The report is written to `Tools/OCRLab/results/report.md`.

Runtime assets live outside the app bundle in
`PluginAssets/ocr-ppocrv6-small`. For a local PP-OCR self-check:

```bash
GLINT_OCR_BACKEND=ppocr \
GLINT_OCR_PLUGIN_DIR="$PWD/PluginAssets/ocr-ppocrv6-small" \
  build/Build/Products/Debug/Glint.app/Contents/MacOS/Glint --selfcheck
```
