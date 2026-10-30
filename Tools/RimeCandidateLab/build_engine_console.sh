#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
LIBRIME_SOURCE="${1:-/tmp/glint-librime}"
FRAMEWORKS="/Library/Input Methods/Squirrel.app/Contents/Frameworks"

clang++ \
  -std=c++17 \
  -I"$LIBRIME_SOURCE/src" \
  "$ROOT/engine_console.cc" \
  -L"$FRAMEWORKS" \
  -Wl,-rpath,"$FRAMEWORKS" \
  -lrime.1 \
  -o "$ROOT/.build/engine_console"
