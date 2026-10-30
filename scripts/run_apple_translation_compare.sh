#!/usr/bin/env bash

set -euo pipefail

repository_root="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/.."
    pwd
)"
package_path="$repository_root/Tools/GlintEval"
app_path="$repository_root/build/AppleTranslationCompare.app"
output_path="${GLINT_APPLE_TRANSLATION_OUTPUT:-$repository_root/build/apple-translation-benchmark.json}"
rounds="${GLINT_APPLE_TRANSLATION_ROUNDS:-3}"
cases_path="${GLINT_APPLE_TRANSLATION_CASES:-$repository_root/Resources/Evaluation/translation-mode-benchmark.json,$repository_root/Resources/Evaluation/dictionary-benchmark.json}"
ct2_path="$repository_root/Resources/Plugins/mt-opus-zh-en/model"

swift build \
    --package-path "$package_path" \
    --product AppleTranslationCompare
binary_path="$(
    swift build \
        --package-path "$package_path" \
        --show-bin-path
)/AppleTranslationCompare"

rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_path" "$app_path/Contents/MacOS/AppleTranslationCompare"

plist_path="$app_path/Contents/Info.plist"
plutil -create xml1 "$plist_path"
plutil -insert CFBundleExecutable \
    -string AppleTranslationCompare "$plist_path"
plutil -insert CFBundleIdentifier \
    -string com.local.glint.apple-translation-compare "$plist_path"
plutil -insert CFBundleName \
    -string AppleTranslationCompare "$plist_path"
plutil -insert CFBundlePackageType \
    -string APPL "$plist_path"
plutil -insert LSMinimumSystemVersion \
    -string 15.0 "$plist_path"
plutil -insert NSHighResolutionCapable \
    -bool YES "$plist_path"
plutil -insert NSPrincipalClass \
    -string NSApplication "$plist_path"

codesign --force --sign - "$app_path" >/dev/null

rm -f "$output_path"
printf 'Launching Apple Translation comparison\n'
printf 'Cases: %s\n' "$cases_path"
printf 'Rounds: %s\n' "$rounds"
printf 'Report: %s\n' "$output_path"

open -W "$app_path" --args \
    --cases "$cases_path" \
    --ct2 "$ct2_path" \
    --output "$output_path" \
    --rounds "$rounds"

if [[ ! -f "$output_path" ]]; then
    printf 'No report was written.\n' >&2
    exit 1
fi

printf 'Report written: %s\n' "$output_path"
