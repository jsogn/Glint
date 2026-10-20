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
  build
