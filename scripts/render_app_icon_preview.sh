#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

icon_bundle="$PWD/App/Glint/AppIcon.icon"
output="$PWD/Design/AppIcon-preview.png"
icTool="$(dirname "$(xcode-select -p)")/Applications/Icon Composer.app/Contents/Executables/ictool"

if [[ ! -x "$icTool" ]]; then
  echo "ictool is unavailable; install Xcode 26 or newer." >&2
  exit 1
fi

"$icTool" "$icon_bundle" \
  --export-image \
  --output-file "$output" \
  --platform macOS \
  --rendition Default \
  --width 1024 \
  --height 1024 \
  --scale 1
