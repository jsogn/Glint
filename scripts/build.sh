#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${GLINT_SKIP_XCODEGEN:-0}" != "1" ]]; then
  xcodegen generate
fi

quiet_args=()
if [[ "${GLINT_BUILD_QUIET:-0}" == "1" ]]; then
  quiet_args=(-quiet)
fi

xcodebuild \
  -workspace Glint.xcworkspace \
  -scheme Glint \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  "${quiet_args[@]}" \
  build

app_bundle="$PWD/build/Build/Products/Debug/Glint.app"
bundle_id=$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleIdentifier' \
  "$app_bundle/Contents/Info.plist")

# Xcode leaves a linker-only signature when code signing is disabled. Its
# designated requirement is tied to a CDHash that changes on every build, so
# TCC treats each rebuild as a different app. Use a stable identifier-based
# requirement for the local development bundle.
codesign \
  --force \
  --sign - \
  --identifier "$bundle_id" \
  --entitlements "$PWD/App/Glint/Glint.entitlements" \
  --requirements "=designated => identifier \"$bundle_id\"" \
  "$app_bundle"

codesign --verify --deep --strict "$app_bundle"
