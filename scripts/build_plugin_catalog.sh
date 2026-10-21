#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

base_url="${1:-http://127.0.0.1:8765}"
output="build/plugin-catalog"
staging="build/plugin-catalog-staging"

rm -rf "$output" "$staging"
mkdir -p "$output" "$staging"

build_plugin() {
  local id="$1"
  local source="$2"
  local manifest="$3"
  local archive="$output/$id.zip"

  /usr/bin/ditto -c -k --keepParent "$source" "$archive"
  local sha
  sha=$(shasum -a 256 "$archive" | awk '{print $1}')
  local size
  size=$(stat -f%z "$archive")
  jq \
    --arg sha "$sha" \
    --arg url "$base_url/$id.zip" \
    --argjson size "$size" \
    '.sha256 = $sha | .url = $url | .sizeBytes = $size' \
    "$manifest" > "$staging/$id.json"
}

mkdir -p "$staging/dict-cedict"
cp Resources/Plugins/dict-cedict/manifest.json "$staging/dict-cedict/"
cp Resources/Dictionary/cedict.sqlite3 "$staging/dict-cedict/"
cp Resources/Dictionary/overrides.json "$staging/dict-cedict/"
build_plugin \
  "dict-cedict" \
  "$staging/dict-cedict" \
  "Resources/Plugins/dict-cedict/manifest.json"

mkdir -p "$staging/dict-ecdict"
cp Resources/Plugins/dict-ecdict/manifest.json "$staging/dict-ecdict/"
cp Resources/Plugins/dict-ecdict/ecdict_rank.sqlite3 "$staging/dict-ecdict/"
build_plugin \
  "dict-ecdict" \
  "$staging/dict-ecdict" \
  "Resources/Plugins/dict-ecdict/manifest.json"

mkdir -p "$staging/dict-wiktionary-zh-en"
cp Resources/Plugins/dict-wiktionary-zh-en/manifest.json "$staging/dict-wiktionary-zh-en/"
cp Resources/Plugins/dict-wiktionary-zh-en/dictionary.sqlite3 "$staging/dict-wiktionary-zh-en/"
build_plugin \
  "dict-wiktionary-zh-en" \
  "$staging/dict-wiktionary-zh-en" \
  "Resources/Plugins/dict-wiktionary-zh-en/manifest.json"

model_source="Tools/ModelLab/models/opus-ct2-int8"
binary_source="Vendor/ct2"
if [[ -f "$model_source/model.bin" && -f "$binary_source/libglintct2.dylib" ]]; then
  mkdir -p "$staging/mt-opus-zh-en"
  cp Resources/Plugins/mt-opus-zh-en/manifest.json "$staging/mt-opus-zh-en/"
  cp -R "$model_source" "$staging/mt-opus-zh-en/model"
  cp -R "$binary_source" "$staging/mt-opus-zh-en/bin"
  codesign --force --sign - \
    "$staging/mt-opus-zh-en/bin/libctranslate2.dylib" \
    "$staging/mt-opus-zh-en/bin/libsentencepiece.0.0.0.dylib" \
    "$staging/mt-opus-zh-en/bin/libglintct2.dylib" \
    >/dev/null 2>&1 || true
  build_plugin \
    "mt-opus-zh-en" \
    "$staging/mt-opus-zh-en" \
    "Resources/Plugins/mt-opus-zh-en/manifest.json"
fi

for manifest in \
  Resources/Plugins/llm-qwen3-*/manifest.json \
  Resources/Plugins/mt-hy-*/manifest.json \
  Resources/Plugins/mt-index-*/manifest.json
do
  [[ -f "$manifest" ]] || continue
  id=$(jq -r '.id' "$manifest")
  cp "$manifest" "$staging/$id.json"
done

jq -s '{plugins: .}' "$staging"/*.json > "$output/catalog.json"
rm -rf "$staging"

printf 'catalog: %s/catalog.json\n' "$output"
printf 'serve: python3 -m http.server 8765 --directory %s\n' "$output"
