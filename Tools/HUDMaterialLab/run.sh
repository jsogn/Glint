#!/bin/zsh

set -euo pipefail

tool_root="$(cd "$(dirname "$0")" && pwd)"
bin_path="$(swift build --package-path "$tool_root" --show-bin-path)"
app_path="$tool_root/.build/HUD Material Lab.app"

swift build --package-path "$tool_root" --product HUDMaterialLab
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$bin_path/HUDMaterialLab" "$app_path/Contents/MacOS/HUDMaterialLab"
cp "$tool_root/Resources/Info.plist" "$app_path/Contents/Info.plist"

open "$app_path" --args "$@"
