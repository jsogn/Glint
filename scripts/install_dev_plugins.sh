#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

CATALOG_SUPPORT="$HOME/Library/Application Support/Glint"
mkdir -p "$CATALOG_SUPPORT"

cp Resources/catalog.json "$CATALOG_SUPPORT/catalog.json"

echo "prepared dev model catalog in $CATALOG_SUPPORT"
