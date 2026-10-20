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

cp PluginAssets/ocr-ppocrv6-small/manifest.json \
  "$staging/ocr-ppocrv6-small.json"
cp PluginAssets/ocr-ppocrv6-medium/manifest.json \
  "$staging/ocr-ppocrv6-medium.json"

installed_model="$HOME/Library/Application Support/Glint/plugins/opus-ct2-int8"
if [[ -f "$installed_model/model/model.bin" ]]; then
  mkdir -p "$staging/mt-opus-zh-en"
  cp Resources/Plugins/mt-opus-zh-en/manifest.json "$staging/mt-opus-zh-en/"
  cp -R "$installed_model/model" "$staging/mt-opus-zh-en/"
  cp -R "$installed_model/bin" "$staging/mt-opus-zh-en/"
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
