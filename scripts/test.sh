#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate
xcodebuild \
  -workspace Glint.xcworkspace \
  -scheme Glint \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  test

for package in GlintCore GlintMac GlintDictionary GlintInference GlintPlugins GlintUI; do
  swift test --package-path "Packages/$package"
done
