#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

package_root="$PWD/build-release"
mkdir -p "$package_root"
work_dir="$(mktemp -d "$package_root/package.XXXXXX")"
derived_data="$work_dir/DerivedData"
stage_dir="$work_dir/dmg"
app_bundle="$derived_data/Build/Products/Release/Glint.app"

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

./scripts/prepare_opus_model.sh
xcodegen generate

xcodebuild \
  -workspace Glint.xcworkspace \
  -scheme Glint \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  -quiet \
  build

bundle_id="$(plutil -extract CFBundleIdentifier raw \
  "$app_bundle/Contents/Info.plist")"
version="$(plutil -extract CFBundleShortVersionString raw \
  "$app_bundle/Contents/Info.plist")"
executable="$(plutil -extract CFBundleExecutable raw \
  "$app_bundle/Contents/Info.plist")"
main_executable="$app_bundle/Contents/MacOS/$executable"

# Sign every nested Mach-O before sealing the app bundle. Ad-hoc signing
# intentionally omits Hardened Runtime: without a Team ID, library validation
# rejects the nested OPUS-MT and Swift runtime libraries.
while IFS= read -r file; do
  [[ "$file" == "$main_executable" ]] && continue
  if file "$file" | grep -q 'Mach-O'; then
    codesign --force --sign - --timestamp=none "$file"
  fi
done < <(find "$app_bundle/Contents" -type f -print)

codesign \
  --force \
  --sign - \
  --timestamp=none \
  --identifier "$bundle_id" \
  --entitlements "$PWD/App/Glint/Glint.entitlements" \
  --requirements "=designated => identifier \"$bundle_id\"" \
  "$app_bundle"

./scripts/verify_app.sh "$app_bundle"

mkdir -p "$stage_dir"
ditto "$app_bundle" "$stage_dir/Glint.app"
ln -s /Applications "$stage_dir/Applications"
cp Resources/Distribution/TEST-INSTALL.txt "$stage_dir/安装说明.txt"
cp Resources/Distribution/Diagnose.command "$stage_dir/诊断.command"
chmod +x "$stage_dir/诊断.command"

dmg_path="$package_root/Glint-$version-macOS26-arm64.dmg"
hdiutil create \
  -quiet \
  -volname "Glint $version" \
  -srcfolder "$stage_dir" \
  -ov \
  -format UDZO \
  "$dmg_path"
hdiutil verify -quiet "$dmg_path"
shasum -a 256 "$dmg_path" > "$dmg_path.sha256"

echo "dmg=$dmg_path"
echo "sha256=$(cut -d ' ' -f 1 "$dmg_path.sha256")"
echo "signature=ad-hoc (not notarized)"
