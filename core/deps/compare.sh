#!/usr/bin/env bash
set -uo pipefail

# Checks that two builds of the libraries — build.sh run on two different
# Macs, say — came out the same: the same files, each with the same
# architectures, the same minimum macOS for each, and, for each
# architecture, the same symbols exported and the same ones imported. CI
# builds them on Apple Silicon, where the x86_64 slices are cross-compiled,
# and on Intel, where the arm64 ones are, and this is what shows that
# cross-compiling in either direction gives the same result: a configure
# answer that differs between a native and a cross build shows up as a
# different import (a replacement function, say) in one of them.
#
#   core/deps/compare.sh <deps> <reference deps>

A="${1:?usage: compare.sh <deps> <reference deps>}"
B="${2:?usage: compare.sh <deps> <reference deps>}"
STATUS=0
fail() { echo "✗ $1" >&2; STATUS=1; }

for DIR in "$A" "$B"; do
    [[ -d "$DIR/lib" && -d "$DIR/libexec" ]] || { echo "error: $DIR is not a build of the libraries (no lib/ and libexec/)" >&2; exit 2; }
done
binaries() { (cd "$1" && find lib libexec -type f -print | sort); }
if ! diff <(binaries "$A") <(binaries "$B") >&2; then fail "the two builds don't have the same files"; fi

while IFS= read -r REL; do
    [[ -f "$B/$REL" ]] || continue
    file -b "$A/$REL" | grep -q 'Mach-O' || continue
    ARCHS_A="$(lipo -archs "$A/$REL")"
    ARCHS_B="$(lipo -archs "$B/$REL")"
    if [[ "$ARCHS_A" != "$ARCHS_B" ]]; then fail "$REL: architectures $ARCHS_A, reference has $ARCHS_B"; continue; fi
    for ARCH in $ARCHS_A; do
        MINOS_A="$(vtool -arch "$ARCH" -show-build "$A/$REL" | awk '$1 == "minos" {print $2}')"
        MINOS_B="$(vtool -arch "$ARCH" -show-build "$B/$REL" | awk '$1 == "minos" {print $2}')"
        [[ "$MINOS_A" = "$MINOS_B" ]] || fail "$REL ($ARCH): minimum macOS $MINOS_A, reference has $MINOS_B"
        for WHICH in "exported:-gU" "imported:-u"; do
            if ! diff <(nm -arch "$ARCH" "${WHICH#*:}" "$A/$REL" | awk '{print $NF}' | sort) \
                      <(nm -arch "$ARCH" "${WHICH#*:}" "$B/$REL" | awk '{print $NF}' | sort) > "${TMPDIR:-/tmp}/compare.$$"; then
                fail "$REL ($ARCH): ${WHICH%%:*} symbols differ:"
                head -n 20 "${TMPDIR:-/tmp}/compare.$$" >&2
            fi
            rm -f "${TMPDIR:-/tmp}/compare.$$"
        done
        for DIR in "$A" "$B"; do
            if nm -arch "$ARCH" -m "$DIR/$REL" | grep -q 'dynamically looked up'; then
                fail "$DIR/$REL ($ARCH): calls symbols nothing defines (a cross-compile gone wrong)"
            fi
        done
    done
done < <(binaries "$A")

if [[ "$STATUS" -eq 0 ]]; then echo "✓ $A matches $B: same files, architectures, minimum macOS and exports"; fi
exit "$STATUS"
