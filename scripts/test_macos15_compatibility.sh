#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

expected_macos="15.0"
runtime_directory="Resources/CTranslate2Runtime/bin"
runtime_lock_file="Resources/CTranslate2Runtime/runtime-lock.json"
model_directory="Resources/OnlineModels/mt-opus-zh-en"
model_lock_file="$model_directory/model-lock.json"

if ! grep -q "macOS: \"$expected_macos\"" project.yml \
  || ! grep -q "MACOSX_DEPLOYMENT_TARGET: \"$expected_macos\"" project.yml; then
  echo "project.yml does not target macOS $expected_macos." >&2
  exit 1
fi

for package_file in Packages/*/Package.swift Tools/*/Package.swift; do
  if ! grep -q "platforms: \[.macOS(\"$expected_macos\")\]" "$package_file"; then
    echo "$package_file does not target macOS $expected_macos." >&2
    exit 1
  fi
done

if [[ ! -x scripts/build_ctranslate2_runtime.sh ]]; then
  echo "CTranslate2 runtime rebuild script is missing or not executable." >&2
  exit 1
fi

for expected in \
  'Glint-$version-macOS-arm64.dmg' \
  'Glint-$version-macOS-arm64.pkg' \
  '--min-os-version "$minimum_system"'; do
  if ! grep -Fq -- "$expected" scripts/package_test_lib.zsh; then
    echo "Package naming or minimum system guard is missing: $expected" >&2
    exit 1
  fi
done

for library in \
  "$runtime_directory/libctranslate2.dylib" \
  "$runtime_directory/libglintct2.dylib" \
  "$runtime_directory/libsentencepiece.0.0.0.dylib"; do
  archs="$(lipo -archs "$library")"
  if [[ "$archs" != "arm64" ]]; then
    echo "Unexpected architecture for $library: $archs" >&2
    exit 1
  fi

  minos="$(vtool -show-build "$library" 2>/dev/null \
    | awk '/^[[:space:]]*minos / { print $2; exit }')"
  if [[ -z "$minos" ]]; then
    echo "Missing minimum system version for $library." >&2
    exit 1
  fi
  if ! awk \
    -v actual="$minos" \
    -v maximum="$expected_macos" \
    'BEGIN {
      split(actual, a, ".")
      split(maximum, b, ".")
      for (i = 1; i <= 3; i++) {
        if ((a[i] + 0) < (b[i] + 0)) exit 0
        if ((a[i] + 0) > (b[i] + 0)) exit 1
      }
      exit 0
    }'; then
    echo "$library requires macOS $minos, expected <= $expected_macos." >&2
    exit 1
  fi

  codesign --verify --strict "$library"
done

if ! otool -L "$runtime_directory/libglintct2.dylib" \
  | grep -q '@rpath/libctranslate2.dylib'; then
  echo "CTranslate2 bridge does not use the bundled library." >&2
  exit 1
fi
if ! otool -L "$runtime_directory/libglintct2.dylib" \
  | grep -q '@rpath/libsentencepiece.0.dylib'; then
  echo "CTranslate2 bridge does not use the bundled SentencePiece library." >&2
  exit 1
fi

for symbol in \
  glint_ct2_create \
  glint_ct2_translate \
  glint_ct2_free_string \
  glint_ct2_destroy; do
  if ! nm -gU "$runtime_directory/libglintct2.dylib" \
    | awk '{ print $3 }' \
    | grep -qx "_$symbol"; then
    echo "Missing bridge symbol: $symbol." >&2
    exit 1
  fi
done

python3 \
  Tools/ModelLab/prepare_opus_model.py \
  --lock "$model_lock_file" \
  --plugin-directory "$model_directory" \
  --source-directory Tools/ModelLab/.cache/opus-mt-zh-en \
  --check

python3 - "$runtime_lock_file" "$runtime_directory" <<'PY'
import hashlib
import json
import pathlib
import sys

lock_path = pathlib.Path(sys.argv[1])
runtime_directory = pathlib.Path(sys.argv[2])
lock = json.loads(lock_path.read_text(encoding="utf-8"))

for relative_path, expected in lock["files"].items():
    path = runtime_directory / pathlib.Path(relative_path).name
    if not path.is_file() or path.stat().st_size != expected["sizeBytes"]:
        raise SystemExit(f"Runtime file mismatch: {relative_path}")
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != expected["sha256"]:
        raise SystemExit(f"Runtime checksum mismatch: {relative_path}")
PY

echo "macos15_compatibility_test: ok"
