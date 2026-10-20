#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

SUPPORT="$HOME/Library/Application Support/Glint/plugins"
CATALOG_SUPPORT="$HOME/Library/Application Support/Glint"
CATALOG_ASSETS="$CATALOG_SUPPORT/catalog-assets"
mkdir -p "$CATALOG_ASSETS"
mkdir -p "$SUPPORT/dict-cedict" "$SUPPORT/dict-ecdict" "$SUPPORT/dict-wiktionary-zh-en" "$SUPPORT/opus-ct2-int8/model" "$SUPPORT/opus-ct2-int8/bin"

cp Resources/Plugins/dict-cedict/manifest.json "$SUPPORT/dict-cedict/manifest.json"
cp Resources/Dictionary/cedict.sqlite3 "$SUPPORT/dict-cedict/cedict.sqlite3"
cp Resources/Dictionary/overrides.json "$SUPPORT/dict-cedict/overrides.json"

cp Resources/Plugins/dict-ecdict/manifest.json "$SUPPORT/dict-ecdict/manifest.json"
cp Resources/Plugins/dict-ecdict/ecdict_rank.sqlite3 "$SUPPORT/dict-ecdict/ecdict_rank.sqlite3"

cp Resources/Plugins/dict-wiktionary-zh-en/manifest.json "$SUPPORT/dict-wiktionary-zh-en/manifest.json"
cp Resources/Plugins/dict-wiktionary-zh-en/dictionary.sqlite3 "$SUPPORT/dict-wiktionary-zh-en/dictionary.sqlite3"

cp Resources/Plugins/mt-opus-zh-en/manifest.json "$SUPPORT/opus-ct2-int8/manifest.json"
if [[ ! -f "$SUPPORT/opus-ct2-int8/model/model.bin" ]]; then
  cp -R Tools/ModelLab/models/opus-ct2-int8/. "$SUPPORT/opus-ct2-int8/model/"
fi
if [[ ! -f "$SUPPORT/opus-ct2-int8/bin/libglintct2.dylib" ]]; then
  cp -R Vendor/ct2/. "$SUPPORT/opus-ct2-int8/bin/"
fi

codesign --force --sign - "$SUPPORT/opus-ct2-int8/bin/libctranslate2.dylib" "$SUPPORT/opus-ct2-int8/bin/libsentencepiece.0.0.0.dylib" "$SUPPORT/opus-ct2-int8/bin/libglintct2.dylib" >/dev/null 2>&1 || true

ocr_small_manifest="$CATALOG_ASSETS/ocr-ppocrv6-small.json"
ocr_medium_manifest="$CATALOG_ASSETS/ocr-ppocrv6-medium.json"
cp PluginAssets/ocr-ppocrv6-small/manifest.json "$ocr_small_manifest"
cp PluginAssets/ocr-ppocrv6-medium/manifest.json "$ocr_medium_manifest"
rm -f "$CATALOG_ASSETS/ocr-ppocrv6-small.zip"

jq -s '{plugins: .}' \
  Resources/Plugins/llm-qwen3-0.6b/manifest.json \
  Resources/Plugins/llm-qwen3-1.7b/manifest.json \
  Resources/Plugins/llm-qwen3-4b/manifest.json \
  Resources/Plugins/mt-hy-mt2-1.8b/manifest.json \
  Resources/Plugins/mt-index-translate-2b/manifest.json \
  "$ocr_small_manifest" \
  "$ocr_medium_manifest" > "$CATALOG_SUPPORT/catalog.json"

echo "installed dev plugins in $SUPPORT"
