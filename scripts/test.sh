#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/fetch_bundled_assets.sh

xcodegen generate
test_derived_data="${GLINT_TEST_DERIVED_DATA:-$PWD/build-tests}"
test_app="$test_derived_data/Build/Products/Debug/Glint.app"
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
cleanup_test_app() {
  "$lsregister" -u "$test_app" >/dev/null 2>&1 || true
}
trap cleanup_test_app EXIT

xcodebuild \
  -workspace Glint.xcworkspace \
  -scheme Glint \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$test_derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  test

for package in GlintCore GlintMac GlintDictionary GlintInference GlintPlugins GlintUI; do
  swift test --package-path "Packages/$package"
done
