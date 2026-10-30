#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

source_directory="$repo_root/Resources/OnlineModels/mt-opus-zh-en"
output_directory="${GLINT_OPUS_MODEL_OUTPUT_DIR:-$repo_root/build/dist}"
archive_name="mt-opus-zh-en-0.1.0.zip"
archive_path="$output_directory/$archive_name"

./scripts/prepare_opus_model.sh

stage_root="$(mktemp -d "$repo_root/build/opus-package.XXXXXX")"
cleanup() {
  rm -rf "$stage_root"
}
trap cleanup EXIT

staged_model="$stage_root/mt-opus-zh-en"
ditto \
  --norsrc \
  --noextattr \
  --noacl \
  --noqtn \
  "$source_directory" \
  "$staged_model"

# The published model asset stores its manifest with owner-only permissions.
# Normalize checked-out mode differences so ZIP hashes remain reproducible.
chmod 0600 "$staged_model/manifest.json"

mkdir -p "$output_directory"
rm -f "$archive_path"
find "$staged_model" -exec touch -t 202610300000 {} +
(
  cd "$stage_root"
  find mt-opus-zh-en -type f -print \
    | LC_ALL=C sort \
    | zip -X -q "$archive_path" -@
)

size_bytes="$(stat -f '%z' "$archive_path")"
sha256="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
checksum_path="$archive_path.sha256"
printf '%s  %s\n' "$sha256" "$archive_name" > "$checksum_path"

archive_entries="$(unzip -Z1 "$archive_path")"
if print -r -- "$archive_entries" | grep -Eq '(^|/)\._|/bin/'; then
  echo "Model archive contains metadata or runtime files." >&2
  exit 1
fi
for required in \
  "manifest.json" \
  "model/model.bin" \
  "model/config.json" \
  "model/shared_vocabulary.json" \
  "model/source.spm" \
  "model/target.spm"; do
  if ! print -r -- "$archive_entries" | grep -Fq "/$required"; then
    echo "Model archive is missing: $required" >&2
    exit 1
  fi
done

python3 - "$repo_root/Resources/catalog.json" "$size_bytes" "$sha256" <<'PY'
import json
import pathlib
import sys

catalog_path = pathlib.Path(sys.argv[1])
size_bytes = int(sys.argv[2])
sha256 = sys.argv[3]
plugins = json.loads(catalog_path.read_text(encoding="utf-8"))["plugins"]
entry = next(
    (plugin for plugin in plugins if plugin["id"] == "mt-opus-zh-en"),
    None,
)
if entry is None:
    raise SystemExit("Catalog is missing mt-opus-zh-en.")
if entry["sizeBytes"] != size_bytes or entry["sha256"] != sha256:
    raise SystemExit("Catalog size or SHA256 does not match the model archive.")
PY

printf 'archive=%s\n' "$archive_path"
printf 'checksum=%s\n' "$checksum_path"
printf 'size_bytes=%s\n' "$size_bytes"
printf 'sha256=%s\n' "$sha256"
printf 'url=%s\n' \
  "https://github.com/jsogn/Glint/releases/download/model-opus-v0.1.0/$archive_name"
