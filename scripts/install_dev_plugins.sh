#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

SUPPORT="$HOME/Library/Application Support/Glint/plugins"
CATALOG_SUPPORT="$HOME/Library/Application Support/Glint"
CATALOG_ASSETS="$CATALOG_SUPPORT/catalog-assets"
mkdir -p "$CATALOG_ASSETS"
mkdir -p "$SUPPORT/dict-cedict" "$SUPPORT/dict-ecdict" "$SUPPORT/dict-wiktionary-zh-en"

cp Resources/Plugins/dict-cedict/manifest.json "$SUPPORT/dict-cedict/manifest.json"
cp Resources/Dictionary/cedict.sqlite3 "$SUPPORT/dict-cedict/cedict.sqlite3"
cp Resources/Dictionary/overrides.json "$SUPPORT/dict-cedict/overrides.json"

cp Resources/Plugins/dict-ecdict/manifest.json "$SUPPORT/dict-ecdict/manifest.json"
cp Resources/Plugins/dict-ecdict/ecdict_rank.sqlite3 "$SUPPORT/dict-ecdict/ecdict_rank.sqlite3"

cp Resources/Plugins/dict-wiktionary-zh-en/manifest.json "$SUPPORT/dict-wiktionary-zh-en/manifest.json"
cp Resources/Plugins/dict-wiktionary-zh-en/dictionary.sqlite3 "$SUPPORT/dict-wiktionary-zh-en/dictionary.sqlite3"

opus_plugin="$SUPPORT/mt-opus-zh-en"
# Optional models are provisioned only when explicitly requested or already
# installed. Relaunching the app must not resurrect a model the user removed.
if [[ -d "$opus_plugin" || "${GLINT_INSTALL_DEV_OPUS:-0}" == "1" ]]; then
  mkdir -p "$opus_plugin/model" "$opus_plugin/bin"
  cp Resources/Plugins/mt-opus-zh-en/manifest.json "$opus_plugin/manifest.json"
  if [[ ! -f "$opus_plugin/model/model.bin" ]]; then
    cp -R Tools/ModelLab/models/opus-ct2-int8/. "$opus_plugin/model/"
  fi
  if [[ ! -f "$opus_plugin/bin/libglintct2.dylib" ]]; then
    cp -R Vendor/ct2/. "$opus_plugin/bin/"
  fi
  codesign --force --sign - \
    "$opus_plugin/bin/libctranslate2.dylib" \
    "$opus_plugin/bin/libsentencepiece.0.0.0.dylib" \
    "$opus_plugin/bin/libglintct2.dylib" >/dev/null 2>&1 || true
fi

opus_catalog_archive="$CATALOG_ASSETS/mt-opus-zh-en.zip"
opus_catalog_manifest="$CATALOG_ASSETS/mt-opus-zh-en.json"
if [[ ! -f "$opus_catalog_archive" ]]; then
  opus_staging="$CATALOG_ASSETS/.mt-opus-zh-en-staging"
  rm -rf "$opus_staging"
  mkdir -p "$opus_staging/mt-opus-zh-en/model" \
    "$opus_staging/mt-opus-zh-en/bin"
  cp Resources/Plugins/mt-opus-zh-en/manifest.json \
    "$opus_staging/mt-opus-zh-en/manifest.json"
  cp -R Tools/ModelLab/models/opus-ct2-int8/. \
    "$opus_staging/mt-opus-zh-en/model/"
  cp -R Vendor/ct2/. "$opus_staging/mt-opus-zh-en/bin/"
  codesign --force --sign - \
    "$opus_staging/mt-opus-zh-en/bin/libctranslate2.dylib" \
    "$opus_staging/mt-opus-zh-en/bin/libsentencepiece.0.0.0.dylib" \
    "$opus_staging/mt-opus-zh-en/bin/libglintct2.dylib" \
    >/dev/null 2>&1 || true
  /usr/bin/ditto -c -k --keepParent \
    "$opus_staging/mt-opus-zh-en" \
    "$opus_catalog_archive"
  rm -rf "$opus_staging"
fi

opus_archive_sha="$(shasum -a 256 "$opus_catalog_archive" | awk '{print $1}')"
opus_archive_size="$(stat -f%z "$opus_catalog_archive")"
opus_archive_url="file://${opus_catalog_archive// /%20}"
jq \
  --arg sha "$opus_archive_sha" \
  --arg url "$opus_archive_url" \
  --argjson size "$opus_archive_size" \
  '.sha256 = $sha | .url = $url | .sizeBytes = $size' \
  Resources/Plugins/mt-opus-zh-en/manifest.json > "$opus_catalog_manifest"

jq -s '{plugins: .}' \
  Resources/Plugins/llm-qwen3-0.6b/manifest.json \
  Resources/Plugins/llm-qwen3-1.7b/manifest.json \
  Resources/Plugins/llm-qwen3-4b/manifest.json \
  Resources/Plugins/mt-hy-mt2-1.8b/manifest.json \
  Resources/Plugins/mt-index-translate-2b/manifest.json \
  "$opus_catalog_manifest" > "$CATALOG_SUPPORT/catalog.json"

echo "installed dev plugins in $SUPPORT"
