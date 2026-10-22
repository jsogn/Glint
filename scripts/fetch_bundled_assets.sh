#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
asset_version="0.1.0"
asset_name="mt-opus-zh-en-v${asset_version}.tar.gz"
asset_sha256="0b363ad4e269172342f848958b1754d7ca9edb39eaadac2045a854f315a7c760"
official_url="https://github.com/jsogn/Glint/releases/download/bundled-assets-v1/${asset_name}"
mirror_url="${GLINT_BUNDLED_ASSETS_MIRROR_URL:-https://gh-proxy.com/${official_url}}"

asset_directory="$repo_root/Resources/Plugins/mt-opus-zh-en"
stamp_path="$asset_directory/.asset-sha256"
model_path="$asset_directory/model/model.bin"
bridge_path="$asset_directory/bin/libglintct2.dylib"

if [[ -f "$stamp_path" && -f "$model_path" && -f "$bridge_path" ]]; then
  installed_sha="$(<"$stamp_path")"
  if [[ "$installed_sha" == "$asset_sha256" ]]; then
    exit 0
  fi
fi

temporary_root="$(mktemp -d /tmp/glint-bundled-assets.XXXXXX)"
trap 'rm -rf "$temporary_root"' EXIT

archive_path="$temporary_root/$asset_name"

download_asset() {
  local url="$1"
  curl \
    --connect-timeout 15 \
    --fail \
    --location \
    --max-time 180 \
    --retry 3 \
    --retry-delay 1 \
    --silent \
    --show-error \
    --output "$archive_path" \
    "$url"
}

download_and_verify_asset() {
  local url="$1"
  local actual_sha
  download_asset "$url"
  actual_sha="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
  [[ "$actual_sha" == "$asset_sha256" ]]
}

download_with_github_cli() {
  command -v gh >/dev/null 2>&1 || return 1
  rm -f "$archive_path"
  gh release download bundled-assets-v1 \
    --repo jsogn/Glint \
    --pattern "$asset_name" \
    --dir "$temporary_root" \
    --clobber \
    >/dev/null
  [[ -f "$archive_path" ]]
}

installed=0
if [[ -n "$mirror_url" ]]; then
  echo "Fetching bundled Glint assets from mirror..."
  if download_and_verify_asset "$mirror_url"; then
    installed=1
  else
    echo "Mirror download failed verification; trying the official release." >&2
  fi
fi

if [[ "$installed" == "0" ]]; then
  echo "Trying authenticated GitHub CLI download..."
  if download_with_github_cli; then
    actual_sha="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
    if [[ "$actual_sha" == "$asset_sha256" ]]; then
      installed=1
    fi
  fi
fi

if [[ "$installed" == "0" ]]; then
  echo "Fetching bundled Glint assets..."
  if ! download_and_verify_asset "$official_url"; then
    echo "Bundled asset checksum mismatch." >&2
    echo "Expected SHA256: $asset_sha256" >&2
    exit 1
  fi
fi

staging_directory="$temporary_root/staging"
mkdir -p "$staging_directory"
tar -xzf "$archive_path" -C "$staging_directory"

for relative_path in \
  "bin/libctranslate2.dylib" \
  "bin/libglintct2.dylib" \
  "bin/libsentencepiece.0.0.0.dylib" \
  "model/model.bin" \
  "model/config.json" \
  "model/shared_vocabulary.json" \
  "model/source.spm" \
  "model/target.spm"; do
  if [[ ! -f "$staging_directory/$relative_path" ]]; then
    echo "Bundled asset archive is missing $relative_path." >&2
    exit 1
  fi
done

if [[ ! -L "$staging_directory/bin/libsentencepiece.0.dylib" ]]; then
  echo "Bundled asset archive is missing the SentencePiece link." >&2
  exit 1
fi

mkdir -p "$asset_directory"
rm -rf "$asset_directory/bin" "$asset_directory/model"
mv "$staging_directory/bin" "$asset_directory/bin"
mv "$staging_directory/model" "$asset_directory/model"

printf '%s\n' "$asset_sha256" > "$stamp_path.tmp"
mv "$stamp_path.tmp" "$stamp_path"

echo "Bundled Glint assets are ready."
