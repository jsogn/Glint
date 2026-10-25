#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

package_root="${GLINT_PACKAGE_ROOT:-$repo_root/build-release}"
mkdir -p "$package_root"
work_dir="$(mktemp -d "$package_root/package.XXXXXX")"

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

source "$repo_root/scripts/package_test_lib.zsh"

prepare_release_app "$work_dir"
app_bundle="$(release_app_bundle "$work_dir")"
package_pkg "$work_dir" "$package_root" "$app_bundle"
