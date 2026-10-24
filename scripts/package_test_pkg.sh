#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

package_root="$PWD/build-release"
mkdir -p "$package_root"
work_dir="$(mktemp -d "$package_root/package.XXXXXX")"
derived_data="$work_dir/DerivedData"
payload_root="$work_dir/payload"
scripts_dir="$work_dir/scripts"
component_pkg="$work_dir/Glint-component.pkg"
component_plist="$work_dir/components.plist"
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

# Ad-hoc signing has no Team ID, so Hardened Runtime is intentionally omitted.
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

mkdir -p "$payload_root/Applications"
ditto "$app_bundle" "$payload_root/Applications/Glint.app"

mkdir -p "$scripts_dir"
cp Resources/Distribution/PKG-Scripts/preinstall "$scripts_dir/preinstall"
cp Resources/Distribution/PKG-Scripts/postinstall "$scripts_dir/postinstall"
chmod 0755 "$scripts_dir/preinstall" "$scripts_dir/postinstall"

pkgbuild --analyze --root "$payload_root" "$component_plist" >/dev/null
/usr/libexec/PlistBuddy \
  -c "Set :0:BundleIsRelocatable false" \
  -c "Set :0:BundleIsVersionChecked false" \
  "$component_plist"

pkgbuild \
  --root "$payload_root" \
  --scripts "$scripts_dir" \
  --component-plist "$component_plist" \
  --identifier "$bundle_id.installer" \
  --version "$version" \
  --install-location / \
  --ownership recommended \
  "$component_pkg"

pkg_path="$package_root/Glint-$version-Installer-macOS26-arm64.pkg"
cp "$component_pkg" "$pkg_path"
pkgutil --payload-files "$pkg_path" >/dev/null

(
  cd "$package_root"
  pkg_name="$(basename "$pkg_path")"
  shasum -a 256 "$pkg_name" > "$pkg_name.sha256"
  shasum -a 256 -c "$pkg_name.sha256"
)

echo "pkg=$pkg_path"
echo "sha256=$(cut -d ' ' -f 1 "$package_root/$(basename "$pkg_path").sha256")"
echo "signature=ad-hoc app payload (installer not notarized)"
