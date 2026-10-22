#!/usr/bin/env bash
set -euo pipefail

# Prints the oldest macOS the app runs on: MACOSX_DEPLOYMENT_TARGET in the
# Xcode project, which is the one place it's set. The bundled libraries are
# built for it too (core/deps/build.sh), and a release is checked against it
# (scripts/release-verify.sh).

cd "$(dirname "$0")/.."
TARGETS="$(sed -n 's/.*MACOSX_DEPLOYMENT_TARGET = \([0-9.]*\);/\1/p' ldap-studio.xcodeproj/project.pbxproj | sort -u)"
if [[ -z "$TARGETS" || "$(grep -c . <<< "$TARGETS")" -ne 1 ]]; then
    echo "error: expected exactly one MACOSX_DEPLOYMENT_TARGET in the Xcode project, got: ${TARGETS:-none}" >&2
    exit 1
fi
echo "$TARGETS"
