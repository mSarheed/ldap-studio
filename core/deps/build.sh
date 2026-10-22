#!/usr/bin/env bash
set -euo pipefail

# Builds the libraries the app bundles — OpenSSL, libxcrypt, OpenLDAP and
# libssh2 — from source, for every architecture in ARCHS, with
# MACOSX_DEPLOYMENT_TARGET as their minimum macOS, and merges them into
# core/build/deps:
#
#   lib/                  universal dylibs, install names @rpath/<name>
#   include/              their headers
#   libexec/slapd, sbin/  OpenLDAP's server and tools, for scripts/test-server
#   etc/openldap/schema/  slapd's schema files
#
# (The CA bundle the app ships isn't here: it's copied fresh at every build
# by the Xcode "Bundle libraries" phase, so a cached build can't freeze it.)
#
# Homebrew's bottles can't be used for this: they only run on the macOS
# they were built on (newer than the app's minimum) and there are none
# for Intel any more. The versions, configure options and patches below
# follow Homebrew's formulae, so the app ships what `brew install` would.
#
# Run through the Makefile, which sets ARCHS, MACOSX_DEPLOYMENT_TARGET and
# SDKROOT:
#
#   make -C core deps                     the host architecture
#   make -C core deps ARCHS="arm64 x86_64"
#
# Each architecture is built once and kept in core/build/deps-build/<arch>
# until this script, a patch or the deployment target changes; asking for
# a different set of architectures only redoes the (quick) merge. The
# other architecture is cross-compiled, so Rosetta isn't needed.

# --- Versions: keep in step with Homebrew (`brew info <formula>`) --------------

OPENSSL_VERSION=4.0.3
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"
OPENSSL_SHA256=325b5c806167c13b40b1ffeadfe0248197c00eccc4cf123ec1e28d2d2fd216d9

LIBXCRYPT_VERSION=4.5.2
LIBXCRYPT_URL="https://github.com/besser82/libxcrypt/releases/download/v$LIBXCRYPT_VERSION/libxcrypt-$LIBXCRYPT_VERSION.tar.xz"
LIBXCRYPT_SHA256=71513a31c01a428bccd5367a32fd95f115d6dac50fb5b60c779d5c7942aec071

OPENLDAP_VERSION=2.7.1
OPENLDAP_URL="https://www.openldap.org/software/download/OpenLDAP/openldap-release/openldap-$OPENLDAP_VERSION.tgz"
OPENLDAP_SHA256=253db80f301258ea69cda1184766d57395b836aaabf41157eb0316eb0fac1341

LIBSSH2_VERSION=1.11.1
LIBSSH2_URL="https://libssh2.org/download/libssh2-$LIBSSH2_VERSION.tar.gz"
LIBSSH2_SHA256=d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7

# -----------------------------------------------------------------------------

HERE="$(cd "$(dirname "$0")" && pwd)"
CORE="$(dirname "$HERE")"
OUT="${DEPS_OUT:-$CORE/build/deps}"
BUILDROOT="${DEPS_BUILD:-$CORE/build/deps-build}"
DOWNLOADS="${DEPS_DOWNLOADS:-$CORE/build/downloads}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

: "${ARCHS:?ARCHS is required (run through make -C core deps)}"
: "${MACOSX_DEPLOYMENT_TARGET:?MACOSX_DEPLOYMENT_TARGET is required (run through make -C core deps)}"
MIN="$MACOSX_DEPLOYMENT_TARGET"
SDKROOT="${SDKROOT:-$(xcrun --show-sdk-path)}"
# Sorted and deduplicated, so "x86_64 arm64" and "arm64 x86_64" are the same build.
ARCHS="$(tr ' ' '\n' <<< "$ARCHS" | grep . | sort -u | tr '\n' ' ' | sed 's/ $//')"
for arch in $ARCHS; do
    case "$arch" in arm64|x86_64) ;; *) echo "error: unsupported architecture $arch" >&2; exit 1 ;; esac
done

# autoconf, libtool and OpenSSL's build pass paths around unquoted.
case "$CORE$BUILDROOT$DOWNLOADS" in *[[:space:]]*)
    echo "error: the repository must be at a path without spaces to build the libraries: $CORE" >&2
    exit 1 ;;
esac
# The SDK too ("/Applications/Xcode 27.app/..."), but that one can be
# reached through a symlink kept here. (SDKROOT itself stays as it is:
# the make and perl in /usr/bin look their real selves up through it.)
mkdir -p "$BUILDROOT"
ln -sfn "$SDKROOT" "$BUILDROOT/sdk"
SYSROOT="$BUILDROOT/sdk"

HOST_ARCH="$(uname -m)"
triple() { case "$1" in arm64) echo aarch64-apple-darwin ;; *) echo "$1-apple-darwin" ;; esac; }

# What a build depends on besides the sources: this script (versions and
# options), the patches and the minimum macOS. The SDK isn't in it — a
# newer one doesn't change what the libraries can run on.
CONFIG="deps/1 min=$MIN script=$(shasum -a 256 "$0" | cut -c1-16) patches=$(cat "$HERE"/patches/*/* | shasum -a 256 | cut -c1-16)"
STAMP="$CONFIG archs=$ARCHS"
# Up to date if built the same way with (at least) these architectures: a
# universal build serves a host-only one, as on a CI runner that got it
# from another.
if [[ -f "$OUT/.stamp" ]]; then
    have="$(cat "$OUT/.stamp")"
    if [[ "${have% archs=*}" = "$CONFIG" ]]; then
        missing=""
        for arch in $ARCHS; do
            case " ${have##* archs=} " in *" $arch "*) ;; *) missing="$missing $arch" ;; esac
        done
        [[ -n "$missing" ]] || exit 0
    fi
fi

mkdir -p "$DOWNLOADS"

fetch() { # <url> <sha256> -> path
    local url="$1" sha="$2" file
    file="$DOWNLOADS/$(basename "$url")"
    if [[ ! -f "$file" ]]; then
        echo "==> Downloading $(basename "$url")" >&2
        curl -fsSL --retry 3 -o "$file.part" "$url"
        mv "$file.part" "$file"
    fi
    if ! echo "$sha  $file" | shasum -a 256 -c --status; then
        rm -f "$file"
        echo "error: $(basename "$file") did not have the expected SHA-256 ($sha); deleted" >&2
        exit 1
    fi
    echo "$file"
}

unpack() { # <tarball> <dir> : a fresh copy of the sources in <dir>
    rm -rf "$2"
    mkdir -p "$2"
    tar -xf "$1" -C "$2" --strip-components 1
}

apply_patches() { # <package> <dir>
    local p
    for p in "$HERE/patches/$1"/*; do
        [[ -f "$p" ]] || continue
        patch -d "$2" -p1 --silent < "$p" || { echo "error: $(basename "$p") did not apply to $1" >&2; exit 1; }
    done
}

run() { # <log> <command...> : quiet unless it fails
    local log="$1"
    shift
    if ! "$@" >> "$log" 2>&1; then
        echo "error: '$*' failed; the last lines of $log:" >&2
        tail -n 40 "$log" >&2
        exit 1
    fi
}

build_arch() { # <arch>
    local arch="$1"
    local prefix="$BUILDROOT/$arch"
    local src="$BUILDROOT/src-$arch"
    local stamp="$CONFIG arch=$arch"
    if [[ -f "$prefix/.stamp" && "$(cat "$prefix/.stamp")" = "$stamp" ]]; then
        return
    fi
    rm -rf "$prefix" "$src"
    mkdir -p "$prefix" "$src"

    # (The OpenSSL target names its own -arch, and its Configure takes any
    # argument without a dash for a target name, so the SDK is joined on.)
    local flags="-arch $arch -mmacosx-version-min=$MIN -isysroot $SYSROOT"
    # configure cross-compiles when the host and build triples differ, and
    # then doesn't try to run what it compiles.
    local cross=(--build="$(triple "$HOST_ARCH")" --host="$(triple "$arch")")
    local cenv=(CC=clang CFLAGS="-O2 $flags" LDFLAGS="$flags -L$prefix/lib" CPPFLAGS="-I$prefix/include")
    local log

    echo "==> Building OpenSSL $OPENSSL_VERSION ($arch)"
    log="$BUILDROOT/openssl-$arch.log"; : > "$log"
    unpack "$(fetch "$OPENSSL_URL" "$OPENSSL_SHA256")" "$src/openssl"
    apply_patches openssl "$src/openssl"
    (cd "$src/openssl" &&
        run "$log" perl ./Configure "darwin64-$arch-cc" enable-ec_nistp_64_gcc_128 no-tests no-docs \
            --prefix="$prefix" --openssldir="$prefix/etc/openssl" --libdir=lib \
            "-mmacosx-version-min=$MIN" "-isysroot$SYSROOT" &&
        run "$log" make -j "$JOBS" build_libs &&
        run "$log" make install_dev)

    echo "==> Building libxcrypt $LIBXCRYPT_VERSION ($arch)"
    log="$BUILDROOT/libxcrypt-$arch.log"; : > "$log"
    unpack "$(fetch "$LIBXCRYPT_URL" "$LIBXCRYPT_SHA256")" "$src/libxcrypt"
    apply_patches libxcrypt "$src/libxcrypt"
    (cd "$src/libxcrypt" &&
        run "$log" env "${cenv[@]}" ./configure "${cross[@]}" --prefix="$prefix" \
            --disable-dependency-tracking --disable-static --disable-obsolete-api \
            --disable-xcrypt-compat-files --disable-failure-tokens --disable-valgrind &&
        run "$log" make -j "$JOBS" &&
        run "$log" make install)

    echo "==> Building OpenLDAP $OPENLDAP_VERSION ($arch)"
    log="$BUILDROOT/openldap-$arch.log"; : > "$log"
    unpack "$(fetch "$OPENLDAP_URL" "$OPENLDAP_SHA256")" "$src/openldap"
    apply_patches openldap "$src/openldap"
    # The libraries, and slapd with the mdb backend for the test server; no
    # overlays, clients, tests or manuals. macOS's own Cyrus SASL, as
    # Homebrew uses. What configure can only find out by running a program
    # — so not when cross-compiling, where it assumes the worst — is given,
    # as macOS has it: select() doesn't need help yielding, kqueue works,
    # pthreads are in libSystem, memcmp works (assumed broken, libldap
    # would call a replacement it doesn't link and crash on Intel),
    # toupper() is safe, and /dev/urandom exists.
    local openldap_cppflags="-I$prefix/include"
    # (The quotes have to survive the Makefiles' shell, hence the backslashes.)
    [[ "$arch" = "$HOST_ARCH" ]] || openldap_cppflags="$openldap_cppflags -DURANDOM_DEVICE=\\\"/dev/urandom\\\""
    (cd "$src/openldap" &&
        run "$log" env "${cenv[@]}" CPPFLAGS="$openldap_cppflags" \
            ol_cv_have_kqueue=yes ol_cv_pthread_create=yes \
            ac_cv_func_memcmp_working=yes ol_cv_c_upper_lower=no \
            ./configure "${cross[@]}" --prefix="$prefix" \
            --sysconfdir="$prefix/etc" --localstatedir="$prefix/var" \
            --disable-dependency-tracking --disable-static --enable-shared \
            --with-tls=openssl --with-cyrus-sasl --without-systemd \
            --enable-slapd --enable-mdb --with-yielding_select=no &&
        run "$log" make depend &&
        run "$log" make -j "$JOBS" -C libraries &&
        run "$log" make -j "$JOBS" -C servers &&
        run "$log" make -C include install &&
        run "$log" make -C libraries install &&
        run "$log" make -C servers install)

    echo "==> Building libssh2 $LIBSSH2_VERSION ($arch)"
    log="$BUILDROOT/libssh2-$arch.log"; : > "$log"
    unpack "$(fetch "$LIBSSH2_URL" "$LIBSSH2_SHA256")" "$src/libssh2"
    apply_patches libssh2 "$src/libssh2"
    (cd "$src/libssh2" &&
        run "$log" env "${cenv[@]}" ./configure "${cross[@]}" --prefix="$prefix" \
            --disable-dependency-tracking --disable-static --disable-silent-rules \
            --disable-examples-build --with-openssl --with-libz --with-libssl-prefix="$prefix" &&
        run "$log" make -j "$JOBS" &&
        run "$log" make install)

    rm -rf "$src"
    echo "$stamp" > "$prefix/.stamp"
}

for arch in $ARCHS; do
    build_arch "$arch"
done

# --- Merge the architectures into $OUT ----------------------------------------

echo "==> Merging $ARCHS into $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/libexec" "$OUT/sbin" "$OUT/etc"
FIRST="$BUILDROOT/${ARCHS%% *}"

# A header that configure generated differently per architecture becomes
# one that includes the right copy.
macro() { case "$1" in arm64) echo __arm64__ ;; x86_64) echo __x86_64__ ;; esac; }
cp -R "$FIRST/include" "$OUT/include"
for arch in $ARCHS; do
    [[ "$arch" != "${ARCHS%% *}" ]] || continue
    # (diff exits 1 when it finds a difference, which isn't an error here.)
    { diff -rq "$FIRST/include" "$BUILDROOT/$arch/include" || [[ $? -eq 1 ]]; } |
    sed -n 's/^Files \(.*\) and .* differ$/\1/p' |
    while read -r file; do
        rel="${file#"$FIRST/include/"}"
        name="$(basename "$rel" .h)"
        dir="$(dirname "$OUT/include/$rel")"
        if [[ ! -f "$dir/$name.${ARCHS%% *}.h" ]]; then
            cp "$FIRST/include/$rel" "$dir/$name.${ARCHS%% *}.h"
            {
                echo "/* Generated by core/deps/build.sh: this header differs per architecture. */"
                echo "#if defined($(macro "${ARCHS%% *}"))"
                echo "#include \"$name.${ARCHS%% *}.h\""
            } > "$OUT/include/$rel"
        fi
        cp "$BUILDROOT/$arch/include/$rel" "$dir/$name.$arch.h"
        # Dropped again below, once every architecture has been added.
        echo "#elif defined($(macro "$arch"))" >> "$OUT/include/$rel"
        echo "#include \"$name.$arch.h\"" >> "$OUT/include/$rel"
    done
done
find "$OUT/include" -name '*.h' -print0 | while IFS= read -r -d '' h; do
    if head -n 1 "$h" | grep -q 'differs per architecture'; then
        printf '#else\n#error "no %s for this architecture"\n#endif\n' "$(basename "$h")" >> "$h"
    fi
done

# Every Mach-O, once, from all the architectures' copies.
universal() { # <relative path>
    local inputs=()
    for arch in $ARCHS; do inputs+=("$BUILDROOT/$arch/$1"); done
    if [[ ${#inputs[@]} -eq 1 ]]; then cp "${inputs[0]}" "$OUT/$1"; else lipo -create "${inputs[@]}" -output "$OUT/$1"; fi
}
for lib in "$FIRST"/lib/*.dylib; do
    name="$(basename "$lib")"
    if [[ -L "$lib" ]]; then
        ln -s "$(readlink "$lib")" "$OUT/lib/$name"
    else
        universal "lib/$name"
    fi
done
universal libexec/slapd
for tool in "$FIRST"/sbin/*; do
    ln -s ../libexec/slapd "$OUT/sbin/$(basename "$tool")"
done
cp -R "$FIRST/etc/openldap" "$OUT/etc/openldap"

# The libraries were built to load each other from the per-architecture
# prefixes. Point everything at @rpath instead, so the app bundle (and
# slapd, via its own lib/) can carry them. Changing load commands breaks
# the linker's signature, and arm64 won't run an unsigned binary.
find "$OUT/lib" "$OUT/libexec" -type f -print0 | while IFS= read -r -d '' bin; do
    file -b "$bin" | grep -q 'Mach-O' || continue
    case "$bin" in *.dylib) install_name_tool -id "@rpath/$(basename "$bin")" "$bin" ;; esac
    otool -L "$bin" | grep -E '^\s' | awk '{print $1}' | sort -u | while read -r dep; do
        case "$dep" in
            "$BUILDROOT"/*) install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$bin" ;;
        esac
    done
    case "$bin" in *.dylib) ;; *) install_name_tool -add_rpath "@executable_path/../lib" "$bin" ;; esac
    codesign --force --sign - "$bin" 2>/dev/null || { echo "error: could not sign $bin" >&2; exit 1; }
done

# Nothing may still load from where it was built, every binary must have
# every architecture, and nothing may be left for dyld to look up at run
# time: a symbol a cross-compiled configure wrongly thought missing links
# fine (libtool links with -undefined dynamic_lookup) and crashes when
# first called. Each would only show at launch, or later.
find "$OUT/lib" "$OUT/libexec" -type f -print0 | while IFS= read -r -d '' bin; do
    file -b "$bin" | grep -q 'Mach-O' || continue
    if otool -L "$bin" | grep -E '^\s' | awk '{print $1}' | grep -q "^$BUILDROOT/"; then
        echo "error: $(basename "$bin") still loads a library from $BUILDROOT" >&2
        exit 1
    fi
    for arch in $ARCHS; do
        if nm -arch "$arch" -m "$bin" 2>/dev/null | grep -q 'dynamically looked up'; then
            echo "error: $(basename "$bin") ($arch) calls symbols nothing defines: $(nm -arch "$arch" -m "$bin" | awk '/dynamically looked up/ {print $(NF-3)}' | tr '\n' ' ')" >&2
            exit 1
        fi
    done
    for arch in $ARCHS; do
        lipo "$bin" -verify_arch "$arch" || { echo "error: $(basename "$bin") has no $arch slice" >&2; exit 1; }
    done
done

echo "$STAMP" > "$OUT/.stamp"
echo "==> Libraries for $ARCHS (macOS $MIN and later) in $OUT"
