#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/plugin_catalog_manifests.zsh

CATALOG_SUPPORT="$HOME/Library/Application Support/Glint"
mkdir -p "$CATALOG_SUPPORT"

jq -s '{plugins: .}' \
  "${GLINT_CATALOG_MODEL_MANIFESTS[@]}" > "$CATALOG_SUPPORT/catalog.json"

echo "prepared dev model catalog in $CATALOG_SUPPORT"
