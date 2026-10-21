#!/usr/bin/env bash
set -uo pipefail

# Checks an exported ldap-studio.app before it goes to Apple: everything in
# it signed by the team with a secure timestamp, hardened runtime on, no
# debugging entitlement, nothing loaded from outside the bundle, and the
# version it was asked to be. Notarization would reject most of these
# anyway, but only after a long upload, and it doesn't check the rest.
#
#   scripts/release-verify.sh <app> <team id> <version> <build number>

APP="${1:?usage: release-verify.sh <app> <team id> <version> <build number>}"
TEAM="${2:?}"
VERSION="${3:?}"
BUILD="${4:?}"
STATUS=0
fail() { echo "✗ $1" >&2; STATUS=1; }

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null; }
[[ "$(plist CFBundleShortVersionString)" = "$VERSION" ]] || fail "CFBundleShortVersionString is $(plist CFBundleShortVersionString), not $VERSION"
[[ "$(plist CFBundleVersion)" = "$BUILD" ]] || fail "CFBundleVersion is $(plist CFBundleVersion), not $BUILD"

codesign --verify --deep --strict --verbose=2 "$APP" || fail "the app's signature does not verify"
# Developer ID, issued to this team: what Gatekeeper and the notary service require.
REQUIREMENT="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$TEAM\""

MACHO=()
while IFS= read -r -d '' FILE; do
    if file -b "$FILE" | grep -q 'Mach-O'; then MACHO+=("$FILE"); fi
done < <(find "$APP/Contents" -type f -print0)
[[ ${#MACHO[@]} -gt 1 ]] || fail "found only ${#MACHO[@]} binaries; the Homebrew libraries are missing from Contents/Frameworks"

for BIN in "${MACHO[@]}"; do
    REL="${BIN#"$APP"/}"
    INFO="$(codesign -dvv "$BIN" 2>&1)"
    codesign --verify --strict -R "=$REQUIREMENT" "$BIN" 2>/dev/null || fail "$REL: not signed with this team's Developer ID"
    grep -q '^Timestamp=' <<< "$INFO" || fail "$REL: no secure timestamp"
    [[ "$INFO" =~ flags=0x[0-9a-f]+\([^\)]*runtime ]] || fail "$REL: hardened runtime is off"
    lipo "$BIN" -verify_arch arm64 2>/dev/null || fail "$REL: no arm64 slice"
    # Loads on the build machine and nowhere else.
    while read -r DEP; do
        case "$DEP" in
            /usr/lib/*|/System/*) ;;
            @rpath/*) [[ -f "$APP/Contents/Frameworks/${DEP#@rpath/}" ]] || fail "$REL: links $DEP, which is not bundled" ;;
            *) fail "$REL: links $DEP, outside the app" ;;
        esac
    done < <(otool -L "$BIN" | tail -n +2 | awk '{print $1}')
done

ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)"
grep -q 'com.apple.security.get-task-allow' <<< "$ENTITLEMENTS" && fail "get-task-allow is present"
grep -q 'com.apple.security.app-sandbox' <<< "$ENTITLEMENTS" || fail "the App Sandbox entitlement is missing"
[[ -s "$APP/Contents/Resources/openssl-cacert.pem" ]] || fail "no CA bundle: LDAPS would fail in the sandbox"

if [[ "$STATUS" -eq 0 ]]; then echo "✓ $(basename "$APP") $VERSION ($BUILD) is signed by $TEAM and self-contained"; fi
exit "$STATUS"
