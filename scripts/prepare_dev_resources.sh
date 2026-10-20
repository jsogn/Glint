#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

test -d "Vendor/ct2" || {
  echo "missing Vendor/ct2; build the CTranslate2 bridge first" >&2
  exit 1
}
test -d "Tools/ModelLab/models/opus-ct2-int8" || {
  echo "missing OPUS CT2 model; download/convert it first" >&2
  exit 1
}

mkdir -p Resources/CT2 Resources/Models
cp -R Vendor/ct2/. Resources/CT2/
cp -R Tools/ModelLab/models/opus-ct2-int8 Resources/Models/
echo "dev translation resources copied to Resources/CT2 and Resources/Models"
