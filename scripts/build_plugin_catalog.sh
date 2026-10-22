#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/plugin_catalog_manifests.zsh

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

  /usr/bin/ditto -c -k --norsrc --keepParent "$source" "$archive"
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

for manifest in "${GLINT_CATALOG_MODEL_MANIFESTS[@]}"
do
  [[ -f "$manifest" ]] || {
    printf 'missing plugin manifest: %s\n' "$manifest" >&2
    exit 1
  }
  id=$(jq -r '.id' "$manifest")
  cp "$manifest" "$staging/$id.json"
done

jq -s '{plugins: .}' "$staging"/*.json > "$output/catalog.json"
rm -rf "$staging"

printf 'catalog: %s/catalog.json\n' "$output"
printf 'serve: python3 -m http.server 8765 --directory %s\n' "$output"
