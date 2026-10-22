#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

plugin_directory="$repo_root/Resources/Plugins/mt-opus-zh-en"
lock_file="$plugin_directory/model-lock.json"
source_directory="$repo_root/Tools/ModelLab/.cache/opus-mt-zh-en"
python_script="$repo_root/Tools/ModelLab/prepare_opus_model.py"

if python3 "$python_script" \
  --lock "$lock_file" \
  --plugin-directory "$plugin_directory" \
  --source-directory "$source_directory" \
  --check; then
  exit 0
fi

venv="$repo_root/Tools/ModelLab/.venv"
if [[ ! -x "$venv/bin/python" ]]; then
  python3 -m venv "$venv"
fi

requirements="$repo_root/Tools/ModelLab/requirements-opus-conversion.txt"
if command -v uv >/dev/null 2>&1; then
  uv pip install \
    --python "$venv/bin/python" \
    --requirements "$requirements"
else
  "$venv/bin/python" -m pip install \
    --disable-pip-version-check \
    --requirement "$requirements"
fi

HF_ENDPOINT="${GLINT_HF_ENDPOINT:-https://hf-mirror.com}" \
  "$venv/bin/python" "$python_script" \
    --lock "$lock_file" \
    --plugin-directory "$plugin_directory" \
    --source-directory "$source_directory"
