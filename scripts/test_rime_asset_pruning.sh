#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
temp_root="$(mktemp -d "${TMPDIR:-/tmp}/glint-rime-prune.XXXXXX")"
trap 'rm -rf "$temp_root"' EXIT

build_dir="$temp_root/Build/Products"
app_bundle="$build_dir/Glint.app"
helper="$app_bundle/Contents/Helpers/RimeCandidateBridge"
resources="$app_bundle/Contents/Resources/RimeCandidateBridge"

reset_fixture() {
  rm -rf "$app_bundle"
  mkdir -p "$(dirname "$helper")" "$resources"
  touch "$helper" "$resources/candidate_bridge.lua"
}

reset_fixture
CONFIGURATION=Release \
  TARGET_BUILD_DIR="$build_dir" \
  WRAPPER_NAME="Glint.app" \
  UNLOCALIZED_RESOURCES_FOLDER_PATH="Glint.app/Contents/Resources" \
  "$repo_root/scripts/prune_debug_rime_assets.sh"
[[ ! -e "$helper" ]]
[[ ! -e "$resources" ]]

reset_fixture
CONFIGURATION=Debug \
  TARGET_BUILD_DIR="$build_dir" \
  WRAPPER_NAME="Glint.app" \
  UNLOCALIZED_RESOURCES_FOLDER_PATH="Glint.app/Contents/Resources" \
  "$repo_root/scripts/prune_debug_rime_assets.sh"
[[ -e "$helper" ]]
[[ -d "$resources" ]]

echo "rime_asset_pruning_test: ok"
