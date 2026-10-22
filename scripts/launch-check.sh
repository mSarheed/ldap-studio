#!/usr/bin/env bash
set -euo pipefail

# Launches a built ldap-studio.app on this Mac and checks it's still
# running 15 seconds later: a library that's missing from the bundle, built
# for the wrong architecture or for a newer macOS than this one only shows
# at launch, as dyld refusing to load it. Used by CI on every macOS and
# architecture the app supports.
#
#   scripts/launch-check.sh <ldap-studio.app>

APP="${1:?usage: launch-check.sh <ldap-studio.app>}"
EXE="$APP/Contents/MacOS/ldap-studio"
[[ -x "$EXE" ]] || { echo "error: $EXE is not an executable" >&2; exit 1; }
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

echo "==> Launching $(basename "$APP") on macOS $(sw_vers -productVersion) ($(uname -m))"
"$EXE" > "$LOG" 2>&1 &
PID=$!
sleep 15
if ! kill -0 "$PID" 2>/dev/null; then
    cat "$LOG"
    echo "error: ldap-studio exited during launch" >&2
    exit 1
fi
kill "$PID"
wait "$PID" 2>/dev/null || true
echo "✓ still running after 15 seconds"
