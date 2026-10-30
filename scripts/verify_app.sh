#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app_bundle="${1:-$repo_root/build/Build/Products/Debug/Glint.app}"
info_plist="$app_bundle/Contents/Info.plist"

if [[ ! -d "$app_bundle" ]]; then
  echo "App bundle not found: $app_bundle" >&2
  exit 1
fi

minimum_system="$(plutil -extract LSMinimumSystemVersion raw "$info_plist")"
bundle_id="$(plutil -extract CFBundleIdentifier raw "$info_plist")"
echo "app=$app_bundle"
echo "bundle_id=$bundle_id"
echo "minimum_system=$minimum_system"

if [[ "$minimum_system" != "15.0" ]]; then
  echo "Unexpected minimum system version." >&2
  exit 1
fi

for relative_path in \
  "Contents/Resources/CTranslate2Runtime/bin/libglintct2.dylib" \
  "Contents/Resources/CTranslate2Runtime/runtime-lock.json" \
  "Contents/Helpers/RimeCandidateBridge" \
  "Contents/Resources/RimeCandidateBridge/candidate_bridge.lua" \
  "Contents/Resources/RimeCandidateBridge/json.lua"; do
  if [[ ! -f "$app_bundle/$relative_path" ]]; then
    echo "Missing required app resource: $relative_path" >&2
    exit 1
  fi
done

if [[ -e "$app_bundle/Contents/Resources/mt-opus-zh-en" \
  || -e "$app_bundle/Contents/Resources/OnlineModels" ]]; then
  echo "Bundled OPUS-MT model data must not be present." >&2
  exit 1
fi

if [[ ! -x "$app_bundle/Contents/Helpers/RimeCandidateBridge" ]]; then
  echo "Rime candidate bridge is not executable." >&2
  exit 1
fi

mach_o_files=(
  "$app_bundle/Contents/MacOS/"*(N)
  "$app_bundle/Contents/Helpers/"*(N)
  "$app_bundle/Contents/Frameworks/"**/*.dylib(N)
  "$app_bundle/Contents/Resources/"**/*.dylib(N)
)

for file in "${mach_o_files[@]}"; do
  [[ -f "$file" ]] || continue

  archs="$(lipo -archs "$file" 2>/dev/null || true)"
  if [[ "$archs" != *arm64* ]]; then
    echo "Mach-O is not arm64: $file ($archs)" >&2
    exit 1
  fi

  minos="$(vtool -show-build "$file" 2>/dev/null \
    | awk '/^[[:space:]]*minos / { print $2; exit }')"
  if [[ -z "$minos" ]]; then
    echo "Missing deployment target: $file" >&2
    exit 1
  fi
  if ! awk \
    -v actual="$minos" \
    -v maximum="$minimum_system" \
    'BEGIN {
      split(actual, a, ".")
      split(maximum, b, ".")
      for (i = 1; i <= 3; i++) {
        if ((a[i] + 0) < (b[i] + 0)) exit 0
        if ((a[i] + 0) > (b[i] + 0)) exit 1
      }
      exit 0
    }'; then
    echo "Mach-O requires a newer macOS: $file ($minos)" >&2
    exit 1
  fi
done

codesign --verify --deep --strict "$app_bundle"
echo "App verification passed."
