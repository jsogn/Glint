#!/bin/sh
set -eu

case "${CONFIGURATION:-}" in
  *Debug*)
    exit 0
    ;;
esac

product_dir="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}"
helper="${product_dir}/Contents/Helpers/RimeCandidateBridge"
resources="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/RimeCandidateBridge"

if [ -e "$helper" ]; then
  /bin/rm -f "$helper"
fi
if [ -d "$product_dir/Contents/Helpers" ]; then
  /usr/bin/rmdir "$product_dir/Contents/Helpers" 2>/dev/null || true
fi
if [ -d "$resources" ]; then
  /bin/rm -rf "$resources"
fi
