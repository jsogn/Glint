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
project_state="$PWD/build/dev-project-inputs.sha256"
skip_xcodegen=1

project_inputs_hash="$(
  {
    shasum -a 256 project.yml
    find App/Glint -type f -print
  } | LC_ALL=C sort | shasum -a 256 | awk '{print $1}'
)"
cached_project_inputs_hash=""
if [[ -f "$project_state" ]]; then
  cached_project_inputs_hash="$(<"$project_state")"
fi

if [[ "$force_generate" == "1" \
      || ! -f "$project_file" \
      || project.yml -nt "$project_file" \
      || "$project_inputs_hash" != "$cached_project_inputs_hash" ]]; then
  skip_xcodegen=0
fi

plugin_state="$HOME/Library/Application Support/Glint/.dev-plugin-inputs.sha256"
plugin_inputs_hash="$(
  {
    shasum -a 256 scripts/install_dev_plugins.sh
    shasum -a 256 scripts/plugin_catalog_manifests.zsh
    for manifest in Resources/Plugins/*/manifest.json(N); do
      shasum -a 256 "$manifest"
    done
  } | shasum -a 256 | awk '{print $1}'
)"
cached_plugin_inputs_hash=""
if [[ -f "$plugin_state" ]]; then
  cached_plugin_inputs_hash="$(<"$plugin_state")"
fi

needs_plugins=0
if [[ "$force_plugins" == "1" \
      || "$plugin_inputs_hash" != "$cached_plugin_inputs_hash" ]]; then
  needs_plugins=1
fi

if [[ "$needs_plugins" == "1" ]]; then
  ./scripts/install_dev_plugins.sh
  mkdir -p "$(dirname "$plugin_state")"
  printf '%s\n' "$plugin_inputs_hash" > "$plugin_state"
fi

GLINT_SKIP_XCODEGEN="$skip_xcodegen" \
GLINT_BUILD_QUIET=1 \
  ./scripts/build.sh

if [[ "$skip_xcodegen" == "0" ]]; then
  mkdir -p "$(dirname "$project_state")"
  printf '%s\n' "$project_inputs_hash" > "$project_state"
fi

if [[ "$build_only" == "0" ]]; then
  ./scripts/launch.sh
fi

echo "dev ready in $((SECONDS - started_at))s"
