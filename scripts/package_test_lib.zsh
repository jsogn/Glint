# Shared packaging helpers. Call these from the repository root.

release_app_bundle() {
  printf '%s/DerivedData/Build/Products/Release/Glint.app\n' "${1:?}"
}

prepare_release_app() {
  local work_dir="${1:?}"
  local derived_data="$work_dir/DerivedData"
  local app_bundle
  app_bundle="$(release_app_bundle "$work_dir")"

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

  local bundle_id
  bundle_id="$(plutil -extract CFBundleIdentifier raw \
    "$app_bundle/Contents/Info.plist")"
  local executable
  executable="$(plutil -extract CFBundleExecutable raw \
    "$app_bundle/Contents/Info.plist")"
  local main_executable="$app_bundle/Contents/MacOS/$executable"

  # Ad-hoc signing has no Team ID, so Hardened Runtime is intentionally
  # omitted. Sign every nested Mach-O before sealing the app bundle.
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
}

write_checksum() {
  local package_path="${1:?}"
  local directory
  directory="$(dirname "$package_path")"
  local name
  name="$(basename "$package_path")"

  (
    cd "$directory"
    shasum -a 256 "$name" > "$name.sha256"
    shasum -a 256 -c "$name.sha256"
  )
}

checksum_value() {
  local package_path="${1:?}"
  local name
  name="$(basename "$package_path")"
  cut -d ' ' -f 1 "$(dirname "$package_path")/$name.sha256"
}

package_dmg() {
  local work_dir="${1:?}"
  local package_root="${2:?}"
  local app_bundle="${3:?}"
  local stage_dir="$work_dir/dmg"
  local version
  version="$(plutil -extract CFBundleShortVersionString raw \
    "$app_bundle/Contents/Info.plist")"

  mkdir -p "$stage_dir"
  ditto "$app_bundle" "$stage_dir/Glint.app"
  ln -s /Applications "$stage_dir/Applications"
  cp Resources/Distribution/TEST-INSTALL.txt "$stage_dir/安装说明.txt"
  cp Resources/Distribution/Diagnose.command "$stage_dir/诊断.command"
  cp LICENSE "$stage_dir/LICENSE.txt"
  chmod +x "$stage_dir/诊断.command"

  local dmg_path="$package_root/Glint-$version-macOS26-arm64.dmg"
  hdiutil create \
    -quiet \
    -volname "Glint $version" \
    -srcfolder "$stage_dir" \
    -ov \
    -format UDZO \
    "$dmg_path"
  hdiutil verify -quiet "$dmg_path"
  write_checksum "$dmg_path"

  echo "dmg=$dmg_path"
  echo "sha256=$(checksum_value "$dmg_path")"
  echo "signature=ad-hoc (not notarized)"
}

package_pkg() {
  local work_dir="${1:?}"
  local package_root="${2:?}"
  local app_bundle="${3:?}"
  local payload_root="$work_dir/payload"
  local scripts_dir="$work_dir/scripts"
  local component_pkg="$work_dir/Glint-component.pkg"
  local component_plist="$work_dir/components.plist"
  local bundle_id
  bundle_id="$(plutil -extract CFBundleIdentifier raw \
    "$app_bundle/Contents/Info.plist")"
  local version
  version="$(plutil -extract CFBundleShortVersionString raw \
    "$app_bundle/Contents/Info.plist")"

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

  local pkg_path="$package_root/Glint-$version-Installer-macOS26-arm64.pkg"
  cp "$component_pkg" "$pkg_path"
  pkgutil --payload-files "$pkg_path" >/dev/null
  write_checksum "$pkg_path"

  echo "pkg=$pkg_path"
  echo "sha256=$(checksum_value "$pkg_path")"
  echo "signature=ad-hoc app payload (installer not notarized)"
}
