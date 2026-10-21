#!/usr/bin/env bash
set -euo pipefail

# Archives ldap-studio, exports it signed with Developer ID, notarizes and
# staples it, and writes to dist/:
#
#   ldap-studio-v<version>.dmg   signed, notarized and stapled disk image
#   ldap-studio-v<version>.zip   the same stapled app, zipped
#
#   VERSION=1.4.0-beta.1 APPLE_TEAM_ID=ABCDE12345 scripts/release-build.sh
#
# Signing identity: with SIGNING_P12_BASE64 and SIGNING_P12_PASSWORD set
# (CI), the .p12 is imported into a throwaway keychain; otherwise the
# "Developer ID Application" identity for APPLE_TEAM_ID in your own
# keychain is used.
#
# Notarization: NOTARY_KEY_ID, NOTARY_ISSUER_ID and NOTARY_PRIVATE_KEY (an
# App Store Connect API key, CI), or NOTARY_PROFILE naming a profile saved
# with `xcrun notarytool store-credentials`. Locally, SKIP_NOTARIZATION=1
# stops after signing and checking, and writes nothing to dist/.
#
# BUILD_NUMBER (CFBundleVersion) defaults to 1.

cd "$(dirname "$0")/.."

[[ "${VERSION:-}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-beta\.[1-9][0-9]*)?$ ]] ||
    { echo "error: VERSION must look like 1.4.0 or 1.4.0-beta.1" >&2; exit 1; }
[[ "${APPLE_TEAM_ID:-}" =~ ^[A-Z0-9]{10}$ ]] ||
    { echo "error: APPLE_TEAM_ID must be your 10-character Apple Developer Team ID" >&2; exit 1; }
BUILD_NUMBER="${BUILD_NUMBER:-1}"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || { echo "error: BUILD_NUMBER must be a positive integer" >&2; exit 1; }

SKIP_NOTARIZATION="${SKIP_NOTARIZATION:-0}"
if [[ "$SKIP_NOTARIZATION" = 1 && -n "${CI:-}" ]]; then
    echo "error: SKIP_NOTARIZATION is for local checks only" >&2
    exit 1
fi

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

TAG="v$VERSION"
NAME="ldap-studio"
umask 077
WORK="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/$NAME-release.XXXXXX")"
KEYCHAIN=""
cleanup() {
    if [[ -n "$KEYCHAIN" ]]; then security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true; fi
    rm -rf "$WORK"
}
trap cleanup EXIT

# --- Signing identity --------------------------------------------------------

SIGN_ARGS=(--timestamp)
if [[ -n "${SIGNING_P12_BASE64:-}" ]]; then
    : "${SIGNING_P12_PASSWORD:?SIGNING_P12_PASSWORD is required with SIGNING_P12_BASE64}"
    KEYCHAIN="$WORK/signing.keychain-db"
    KEYCHAIN_PASSWORD="$(openssl rand -base64 32)"
    printf '%s' "$SIGNING_P12_BASE64" | base64 --decode > "$WORK/identity.p12"
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    security set-keychain-settings -lut 21600 "$KEYCHAIN"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$SIGNING_P12_PASSWORD" \
        -T /usr/bin/codesign -T /usr/bin/security
    rm -f "$WORK/identity.p12"
    # Lets codesign use the key without a GUI prompt.
    security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
    # Searched first, so it is the keychain xcodebuild and codesign find the identity in.
    SEARCH=()
    while read -r PATH_IN_LIST; do SEARCH+=("$(tr -d '"' <<< "$PATH_IN_LIST")"); done < <(security list-keychains -d user)
    security list-keychains -d user -s "$KEYCHAIN" "${SEARCH[@]}"
    SIGN_ARGS=(--timestamp --keychain "$KEYCHAIN")
fi
IDENTITY="$(security find-identity -v -p codesigning ${KEYCHAIN:+"$KEYCHAIN"} |
    awk -v team="($APPLE_TEAM_ID)" '/"Developer ID Application: / && index($0, team) { print $2; exit }')"
[[ -n "$IDENTITY" ]] || { echo "error: no Developer ID Application identity for team $APPLE_TEAM_ID" >&2; exit 1; }

# --- Notarization credentials ------------------------------------------------

NOTARY=()
if [[ -n "${NOTARY_KEY_ID:-}" || -n "${NOTARY_ISSUER_ID:-}" || -n "${NOTARY_PRIVATE_KEY:-}" ]]; then
    : "${NOTARY_KEY_ID:?}" "${NOTARY_ISSUER_ID:?}" "${NOTARY_PRIVATE_KEY:?}"
    printf '%s\n' "$NOTARY_PRIVATE_KEY" > "$WORK/AuthKey.p8"
    NOTARY=(--key "$WORK/AuthKey.p8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
elif [[ -n "${NOTARY_PROFILE:-}" ]]; then
    NOTARY=(--keychain-profile "$NOTARY_PROFILE")
elif [[ "$SKIP_NOTARIZATION" != 1 ]]; then
    echo "error: no notarization credentials (NOTARY_KEY_ID/NOTARY_ISSUER_ID/NOTARY_PRIVATE_KEY or NOTARY_PROFILE)" >&2
    exit 1
fi

notarize() {
    echo "==> Notarizing $(basename "$1")"
    xcrun notarytool submit "$1" "${NOTARY[@]}" --wait --timeout 1h --output-format json > "$WORK/notary.json" || true
    if ! plutil -extract status raw -o - "$WORK/notary.json" 2>/dev/null | grep -qx Accepted; then
        cat "$WORK/notary.json" >&2
        local id
        id="$(plutil -extract id raw -o - "$WORK/notary.json" 2>/dev/null || true)"
        if [[ -n "$id" ]]; then xcrun notarytool log "$id" "${NOTARY[@]}" >&2 || true; fi
        echo "error: notarization of $(basename "$1") was not accepted" >&2
        exit 1
    fi
}

# --- Archive and export --------------------------------------------------------

echo "==> Archiving $NAME $VERSION ($BUILD_NUMBER)"
# arm64 only: the Homebrew libraries the app bundles are arm64.
# Hardened runtime is set here rather than in the project, because it also
# turns on library validation, which ad-hoc signed local builds can't pass.
xcodebuild archive \
    -project "$NAME.xcodeproj" -scheme "$NAME" -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$WORK/$NAME.xcarchive" \
    -derivedDataPath "$WORK/DerivedData" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM="$APPLE_TEAM_ID" ENABLE_HARDENED_RUNTIME=YES \
    OTHER_CODE_SIGN_FLAGS="${SIGN_ARGS[*]}" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

cat > "$WORK/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>
    <key>teamID</key><string>$APPLE_TEAM_ID</string>
</dict>
</plist>
EOF
echo "==> Exporting with Developer ID"
xcodebuild -exportArchive -archivePath "$WORK/$NAME.xcarchive" \
    -exportOptionsPlist "$WORK/ExportOptions.plist" -exportPath "$WORK/export"
APP="$WORK/export/$NAME.app"

scripts/release-verify.sh "$APP" "$APPLE_TEAM_ID" "$VERSION" "$BUILD_NUMBER"

if [[ "$SKIP_NOTARIZATION" = 1 ]]; then
    echo "SKIP_NOTARIZATION=1: signed and checked, not notarized; nothing written to dist/"
    exit 0
fi

# --- Notarize, staple and package ---------------------------------------------

ditto -c -k --keepParent --sequesterRsrc "$APP" "$WORK/submission.zip"
notarize "$WORK/submission.zip"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

mkdir -p dist
rm -f "dist/$NAME-$TAG.dmg" "dist/$NAME-$TAG.zip"

echo "==> Building the disk image"
mkdir "$WORK/dmg"
ditto "$APP" "$WORK/dmg/$NAME.app"
ln -s /Applications "$WORK/dmg/Applications"
hdiutil create -volname "LDAP Studio" -srcfolder "$WORK/dmg" -fs APFS -format ULFO \
    "dist/$NAME-$TAG.dmg"
codesign --sign "$IDENTITY" "${SIGN_ARGS[@]}" "dist/$NAME-$TAG.dmg"
notarize "dist/$NAME-$TAG.dmg"
xcrun stapler staple "dist/$NAME-$TAG.dmg"
xcrun stapler validate "dist/$NAME-$TAG.dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "dist/$NAME-$TAG.dmg"

# The same name the releases have always used for the zip.
ditto -c -k --keepParent --sequesterRsrc "$APP" "dist/$NAME-$TAG.zip"

(cd dist && shasum -a 256 "$NAME-$TAG.dmg" "$NAME-$TAG.zip")
echo "Done: dist/$NAME-$TAG.dmg, dist/$NAME-$TAG.zip"
