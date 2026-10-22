#!/usr/bin/env bash
set -uo pipefail

# Checks an exported ldap-studio.app before it goes to Apple: everything in
# it signed by the team with a secure timestamp, hardened runtime on, no
# debugging entitlement, nothing loaded from outside the bundle, built for
# Apple Silicon and Intel, nothing in it needing a newer macOS than the app
# says it runs on, and the version it was asked to be. Notarization would
# reject some of these anyway, but only after a long upload, and it doesn't
# check the rest.
#
#   scripts/release-verify.sh <app> <team id> <version> <build number> <minimum macOS>

APP="${1:?usage: release-verify.sh <app> <team id> <version> <build number> <minimum macOS>}"
TEAM="${2:?}"
VERSION="${3:?}"
BUILD="${4:?}"
MINIMUM_SYSTEM="${5:?}"
ARCHS="arm64 x86_64"
STATUS=0
fail() { echo "✗ $1" >&2; STATUS=1; }

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null; }
[[ "$(plist CFBundleShortVersionString)" = "$VERSION" ]] || fail "CFBundleShortVersionString is $(plist CFBundleShortVersionString), not $VERSION"
[[ "$(plist CFBundleVersion)" = "$BUILD" ]] || fail "CFBundleVersion is $(plist CFBundleVersion), not $BUILD"
# What the appcast tells installed apps, and Finder tells users: the
# project's deployment target, which the bundled libraries were built for.
[[ "$(plist LSMinimumSystemVersion)" = "$MINIMUM_SYSTEM" ]] || fail "LSMinimumSystemVersion is $(plist LSMinimumSystemVersion), not $MINIMUM_SYSTEM"

codesign --verify --deep --strict --verbose=2 "$APP" || fail "the app's signature does not verify"
# Developer ID, issued to this team: what Gatekeeper and the notary service require.
REQUIREMENT="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$TEAM\""

newer() { # is $1 a newer version than $2?
    [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)" = "$1" ]]
}

MACHO=()
while IFS= read -r -d '' FILE; do
    if file -b "$FILE" | grep -q 'Mach-O'; then MACHO+=("$FILE"); fi
done < <(find "$APP/Contents" -type f -print0)
[[ ${#MACHO[@]} -gt 1 ]] || fail "found only ${#MACHO[@]} binaries; the bundled libraries are missing from Contents/Frameworks"

for BIN in "${MACHO[@]}"; do
    REL="${BIN#"$APP"/}"
    INFO="$(codesign -dvv "$BIN" 2>&1)"
    codesign --verify --strict -R "=$REQUIREMENT" "$BIN" 2>/dev/null || fail "$REL: not signed with this team's Developer ID"
    grep -q '^Timestamp=' <<< "$INFO" || fail "$REL: no secure timestamp"
    [[ "$INFO" =~ flags=0x[0-9a-f]+\([^\)]*runtime ]] || fail "$REL: hardened runtime is off"
    for ARCH in $ARCHS; do
        lipo "$BIN" -verify_arch "$ARCH" 2>/dev/null || { fail "$REL: no $ARCH slice"; continue; }
        # Loads on any Mac and nowhere else.
        while read -r DEP; do
            case "$DEP" in
                /usr/lib/*|/System/*) ;;
                @rpath/*) [[ -e "$APP/Contents/Frameworks/${DEP#@rpath/}" ]] || fail "$REL ($ARCH): links $DEP, which is not bundled" ;;
                *) fail "$REL ($ARCH): links $DEP, outside the app" ;;
            esac
        done < <(otool -arch "$ARCH" -L "$BIN" | tail -n +2 | awk '{print $1}')
        # dyld refuses a binary built for a newer macOS than it's running on,
        # so a library that needs more than the app says would fail at launch.
        MINOS="$(vtool -arch "$ARCH" -show-build "$BIN" 2>/dev/null | awk '$1 == "minos" {print $2}')"
        [[ -n "$MINOS" ]] || fail "$REL ($ARCH): no build version"
        if [[ -n "$MINOS" ]] && newer "$MINOS" "$MINIMUM_SYSTEM"; then fail "$REL ($ARCH): needs macOS $MINOS, but the app supports $MINIMUM_SYSTEM"; fi
    done
done

ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)"
grep -q 'com.apple.security.get-task-allow' <<< "$ENTITLEMENTS" && fail "get-task-allow is present"
grep -q 'com.apple.security.app-sandbox' <<< "$ENTITLEMENTS" || fail "the App Sandbox entitlement is missing"
CACERT="$APP/Contents/Resources/openssl-cacert.pem"
[[ -s "$CACERT" ]] || fail "no CA bundle: LDAPS would fail in the sandbox"
# Homebrew's ca-certificates (Mozilla's bundle, dated by its version), not
# the macOS one the build falls back to without it.
BREW_CACERT="$(brew --prefix ca-certificates 2>/dev/null || true)/share/ca-certificates/cacert.pem"
if [[ -f "$BREW_CACERT" ]] && cmp -s "$CACERT" "$BREW_CACERT"; then
    echo "CA bundle: $(brew list --versions ca-certificates 2>/dev/null || echo "Homebrew's ca-certificates")"
else
    fail "the CA bundle is not Homebrew's ca-certificates (brew install ca-certificates and rebuild)"
fi

if [[ "$STATUS" -eq 0 ]]; then echo "✓ $(basename "$APP") $VERSION ($BUILD) is signed by $TEAM, self-contained, universal, and runs on macOS $MINIMUM_SYSTEM and later"; fi
exit "$STATUS"
