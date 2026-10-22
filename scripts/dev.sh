#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

force_generate=0
force_plugins=0
build_only=0
for argument in "$@"; do
  case "$argument" in
    --regenerate)
      force_generate=1
      ;;
    --plugins)
      force_plugins=1
      ;;
    --build-only)
      build_only=1
      ;;
    *)
      echo "Unknown option: $argument" >&2
      echo "Usage: ./scripts/dev.sh [--regenerate] [--plugins] [--build-only]" >&2
      exit 2
      ;;
  esac
done

started_at=$SECONDS
project_file="Glint.xcodeproj/project.pbxproj"
skip_xcodegen=1

if [[ "$force_generate" == "1" \
      || ! -f "$project_file" \
      || project.yml -nt "$project_file" \
      || -n "$(find App/Glint -type f -newer "$project_file" -print -quit)" ]]; then
  skip_xcodegen=0
fi

plugin_stamp="$HOME/Library/Application Support/Glint/.dev-plugins-stamp"
needs_plugins=0
if [[ "$force_plugins" == "1" || ! -f "$plugin_stamp" ]]; then
  needs_plugins=1
elif [[ -n "$(find Resources/Plugins PluginAssets \
    -type f -newer "$plugin_stamp" -print -quit 2>/dev/null)" ]]; then
  needs_plugins=1
fi

if [[ "$needs_plugins" == "1" ]]; then
  ./scripts/install_dev_plugins.sh
  touch "$plugin_stamp"
fi

GLINT_SKIP_XCODEGEN="$skip_xcodegen" \
GLINT_BUILD_QUIET=1 \
  ./scripts/build.sh

if [[ "$build_only" == "0" ]]; then
  ./scripts/launch.sh
fi

echo "dev ready in $((SECONDS - started_at))s"
