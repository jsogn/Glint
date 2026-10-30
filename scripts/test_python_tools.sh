#!/bin/zsh

set -euo pipefail
cd "$(dirname "$0")/.."

export PYTHONDONTWRITEBYTECODE=1

for test_dir in \
  Tools/CandidateLab \
  Tools/DictionaryLab \
  Tools/ModelLab/eval; do
  test_files=("$test_dir"/test_*.py(N))
  if (( ${#test_files} > 0 )); then
    python3 -m unittest discover -s "$test_dir" -p 'test_*.py'
  fi
done
