#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

app_bundle="$PWD/build/Build/Products/Debug/Glint.app"
stale_release_app="$PWD/build-release/Build/Products/Release/Glint.app"
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# A Release validation bundle must not compete with the TCC-authorized
# development app for the same Bundle ID.
if [[ -d "$stale_release_app" ]]; then
  "$lsregister" -u "$stale_release_app" >/dev/null 2>&1 || true
fi

wait_for_glint_exit() {
  for _ in {1..50}; do
    if ! pgrep -x Glint >/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

if pgrep -x Glint >/dev/null; then
  osascript -e 'tell application id "com.local.glint" to quit' >/dev/null 2>&1 || true
fi

if ! wait_for_glint_exit; then
  killall Glint >/dev/null 2>&1 || true
fi

if ! wait_for_glint_exit; then
  killall -KILL Glint >/dev/null 2>&1 || true
fi

if ! wait_for_glint_exit; then
  echo "Glint did not terminate cleanly; refusing to launch another instance." >&2
  exit 1
fi

"$lsregister" -f "$app_bundle" >/dev/null 2>&1 || true
launch_token="$(uuidgen)"
readiness_file="$HOME/Library/Application Support/Glint/runtime-ready"
mkdir -p "$(dirname "$readiness_file")"
printf 'pending:%s\n' "$launch_token" > "$readiness_file"
open "$app_bundle" --args --readiness-token "$launch_token"

for _ in {1..450}; do
  instance_count=$(pgrep -x Glint | wc -l | tr -d ' ')
  if [[ "$instance_count" == 1 && -f "$readiness_file" ]]; then
    ready_token=$(<"$readiness_file")
    if [[ "$ready_token" == "$launch_token" ]]; then
      exit 0
    fi
  fi
  if [[ "$instance_count" -gt 1 ]]; then
    echo "Multiple Glint instances started unexpectedly." >&2
    exit 1
  fi
  sleep 0.1
done

echo "Glint did not reach runtime readiness; complete any permission prompt and retry." >&2
exit 1
