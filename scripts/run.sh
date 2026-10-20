#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

if pgrep -x Glint >/dev/null; then
  osascript -e 'tell application id "com.local.glint" to quit' >/dev/null 2>&1 || true
  for _ in {1..20}; do
    pgrep -x Glint >/dev/null || break
    sleep 0.1
  done
fi

if pgrep -x Glint >/dev/null; then
  killall Glint
fi

./scripts/install_dev_plugins.sh
./scripts/build.sh
open "build/Build/Products/Debug/Glint.app"
