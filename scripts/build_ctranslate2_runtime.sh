#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

minimum_macos="15.0"
architecture="arm64"
ctranslate2_version="4.8.3"
ctranslate2_revision="8d91aa08225004755360daa43deb62b35b1ed65d"
sentencepiece_version="0.2.2"
sentencepiece_revision="e0cce7d37b065b5140349dbe12c6bcf6192fdd78"
abseil_revision="5650e9cf76d3be4318d5fa3af38ee483ddfd5e4a"

cache_root="${GLINT_CT2_BUILD_CACHE:-$repo_root/Tools/ModelLab/.cache/ctranslate2-runtime}"
ctranslate2_source="$cache_root/ctranslate2"
sentencepiece_source="$cache_root/sentencepiece"
sentencepiece_build="$cache_root/sentencepiece-build"
runtime_directory="$repo_root/Resources/Plugins/mt-opus-zh-en/bin"
lock_file="$repo_root/Resources/Plugins/mt-opus-zh-en/model-lock.json"

locked_ctranslate2_version="$(
  python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["conversion"]["tools"]["ctranslate2"])' \
    "$lock_file"
)"
locked_sentencepiece_version="$(
  python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["conversion"]["tools"]["sentencepiece"])' \
    "$lock_file"
)"
if [[ "$locked_ctranslate2_version" != "$ctranslate2_version" ]]; then
  echo "CTranslate2 version differs from model-lock.json." >&2
  exit 1
fi
if [[ "$locked_sentencepiece_version" != "$sentencepiece_version" ]]; then
  echo "SentencePiece version differs from model-lock.json." >&2
  exit 1
fi

for tool in cmake ninja xcrun codesign lipo otool vtool python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required build tool: $tool" >&2
    exit 1
  fi
done

ensure_checkout() {
  local repository="$1"
  local destination="$2"
  local revision="$3"

  if [[ ! -d "$destination/.git" ]]; then
    mkdir -p "$(dirname "$destination")"
    git clone \
      --filter=blob:none \
      --no-checkout \
      "$repository" \
      "$destination"
  fi

  if [[ "$(git -C "$destination" rev-parse HEAD 2>/dev/null || true)" != "$revision" ]]; then
    git -C "$destination" fetch --depth=1 origin "$revision"
    git -C "$destination" checkout --detach FETCH_HEAD
  fi
}

ensure_checkout \
  "https://github.com/OpenNMT/CTranslate2.git" \
  "$ctranslate2_source" \
  "$ctranslate2_revision"
ensure_checkout \
  "https://github.com/google/sentencepiece.git" \
  "$sentencepiece_source" \
  "$sentencepiece_revision"

cmake \
  -S "$sentencepiece_source" \
  -B "$sentencepiece_build" \
  --fresh \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES="$architecture" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$minimum_macos" \
  -DSPM_ENABLE_SHARED=ON \
  -DSPM_ENABLE_TCMALLOC=OFF \
  -DSPM_BUILD_TEST=OFF \
  -DSPM_ENABLE_BENCHMARK=OFF

actual_abseil_revision="$(
  git -C "$sentencepiece_source/third_party/abseil-cpp" rev-parse HEAD
)"
if [[ "$actual_abseil_revision" != "$abseil_revision" ]]; then
  echo "Unexpected Abseil revision: $actual_abseil_revision" >&2
  exit 1
fi

jobs="$(sysctl -n hw.logicalcpu 2>/dev/null || print 4)"
cmake --build \
  "$sentencepiece_build" \
  --target sentencepiece \
  -j "$jobs"

mkdir -p "$runtime_directory"
install -m 755 \
  "$sentencepiece_build/src/libsentencepiece.0.0.0.dylib" \
  "$runtime_directory/libsentencepiece.0.0.0.dylib"
ln -sfn \
  libsentencepiece.0.0.0.dylib \
  "$runtime_directory/libsentencepiece.0.dylib"

xcrun --sdk macosx clang++ \
  -std=c++17 \
  -O2 \
  -arch "$architecture" \
  -mmacosx-version-min="$minimum_macos" \
  -dynamiclib \
  -I "$ctranslate2_source/include" \
  -I "$sentencepiece_build/src/installed_headers" \
  -I "$sentencepiece_source/third_party/abseil-cpp" \
  "$repo_root/Bridges/CTranslate2Bridge/CT2Bridge.cpp" \
  -L "$runtime_directory" \
  -lctranslate2 \
  -L "$sentencepiece_build/src" \
  -lsentencepiece \
  -Wl,-rpath,@loader_path \
  -Wl,-install_name,@rpath/libglintct2.dylib \
  -o "$runtime_directory/libglintct2.dylib"

codesign \
  --force \
  --sign - \
  --timestamp=none \
  --identifier libsentencepiece.0 \
  "$runtime_directory/libsentencepiece.0.0.0.dylib"
codesign \
  --force \
  --sign - \
  --timestamp=none \
  --identifier libglintct2 \
  "$runtime_directory/libglintct2.dylib"

for library in \
  "$runtime_directory/libctranslate2.dylib" \
  "$runtime_directory/libglintct2.dylib" \
  "$runtime_directory/libsentencepiece.0.0.0.dylib"; do
  archs="$(lipo -archs "$library")"
  if [[ "$archs" != "$architecture" ]]; then
    echo "Unexpected architecture for $library: $archs" >&2
    exit 1
  fi

  library_minimum="$(vtool -show-build "$library" 2>/dev/null \
    | awk '/^[[:space:]]*minos / { print $2; exit }')"
  if [[ -z "$library_minimum" ]]; then
    echo "Missing minimum system version for $library" >&2
    exit 1
  fi
  if ! awk \
    -v actual="$library_minimum" \
    -v maximum="$minimum_macos" \
    'BEGIN {
      split(actual, a, ".")
      split(maximum, b, ".")
      for (i = 1; i <= 3; i++) {
        if ((a[i] + 0) < (b[i] + 0)) exit 0
        if ((a[i] + 0) > (b[i] + 0)) exit 1
      }
      exit 0
    }'; then
    echo "$library requires macOS $library_minimum, expected <= $minimum_macos" >&2
    exit 1
  fi

  codesign --verify --strict "$library"
done

for symbol in \
  glint_ct2_create \
  glint_ct2_translate \
  glint_ct2_free_string \
  glint_ct2_destroy; do
  if ! nm -gU "$runtime_directory/libglintct2.dylib" \
    | awk '{ print $3 }' \
    | grep -qx "_$symbol"; then
    echo "Missing bridge symbol: $symbol" >&2
    exit 1
  fi
done

python3 - "$lock_file" "$runtime_directory" <<'PY'
import hashlib
import json
import pathlib
import sys

lock_path = pathlib.Path(sys.argv[1])
runtime_directory = pathlib.Path(sys.argv[2])
lock = json.loads(lock_path.read_text(encoding="utf-8"))

for relative_path in (
    "bin/libctranslate2.dylib",
    "bin/libglintct2.dylib",
    "bin/libsentencepiece.0.0.0.dylib",
    "bin/libsentencepiece.0.dylib",
):
    path = runtime_directory / pathlib.Path(relative_path).name
    lock["files"][relative_path] = {
        "sizeBytes": path.stat().st_size,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }

lock_path.write_text(
    json.dumps(lock, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
PY

python3 \
  "$repo_root/Tools/ModelLab/prepare_opus_model.py" \
  --lock "$lock_file" \
  --plugin-directory "$repo_root/Resources/Plugins/mt-opus-zh-en" \
  --source-directory "$repo_root/Tools/ModelLab/.cache/opus-mt-zh-en" \
  --check

echo "ctranslate2_runtime_version=$ctranslate2_version"
echo "sentencepiece_version=$sentencepiece_version"
echo "abseil_revision=$abseil_revision"
echo "minimum_macos=$minimum_macos"
echo "architecture=$architecture"
