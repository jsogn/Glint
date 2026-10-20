#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$root/scripts/build_dictionary_benchmark.py"
swift run \
  --package-path "$root/Packages/GlintBenchmark" \
  GlintBenchmark \
  --root "$root" \
  --cases "$root/Resources/Evaluation/dictionary-benchmark.json" \
  --output "$root/build/dictionary-benchmark.json"
