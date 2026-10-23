#!/bin/zsh

set -euo pipefail
cd "$(dirname "$0")/.."

export PYTHONDONTWRITEBYTECODE=1

python3 -m unittest discover -s Tools/CandidateLab -p 'test_*.py'
python3 -m unittest discover -s Tools/DictionaryBuilder -p 'test_*.py'
python3 -m unittest discover -s Tools/DictionaryLab -p 'test_*.py'
python3 -m unittest discover -s Tools/ModelLab/eval -p 'test_*.py'
