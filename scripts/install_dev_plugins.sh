#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/plugin_catalog_manifests.zsh

CATALOG_SUPPORT="$HOME/Library/Application Support/Glint"
CATALOG_ASSETS="$CATALOG_SUPPORT/catalog-assets"
mkdir -p "$CATALOG_ASSETS"

jq -s '{plugins: .}' \
  "${GLINT_CATALOG_MODEL_MANIFESTS[@]}" > "$CATALOG_SUPPORT/catalog.json"

echo "prepared dev model catalog in $CATALOG_SUPPORT"
