#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/install_dev_plugins.sh
./scripts/build.sh
exec ./scripts/launch.sh
