#!/usr/bin/env bash
set -euo pipefail

# Builds and runs checks/ against the test server started by run.sh:
# opening the tree, lazy and paged child loads, per-node errors, Go to DN,
# refresh, quick and advanced search, cancellation, connection reuse,
# LDAPS/StartTLS pinning and trusted certificate authorities,
# copy/move/export/delete of a branch, a network that stops answering, a
# server restart, the SSH tunnel (through a throwaway sshd on port 2222)
# and the MCP server (on port 47999).
# Restarts the test server once.
#
#   scripts/test-server/run.sh start
#   scripts/test-server/check.sh

cd "$(dirname "$0")/../.."
if [[ -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

make -C core >/dev/null
OUT="$(mktemp -d)"

B="$(brew --prefix)/opt"
# The app's non-UI sources, compiled with its Swift settings.
build() {
    local out="$1"
    shift
    xcrun -sdk macosx swiftc -O -swift-version 5 -default-isolation MainActor \
        -enable-upcoming-feature NonisolatedNonsendingByDefault \
        -enable-upcoming-feature InferIsolatedConformances \
        -enable-upcoming-feature InferSendableFromCaptures \
        -import-objc-header ldap-studio/ldap-studio-Bridging-Header.h -Icore/include \
        ldap-studio/Core/LdapStudioCore.swift ldap-studio/Core/LdapConnectionPool.swift \
        ldap-studio/Core/DN.swift ldap-studio/Core/OperationLog.swift \
        ldap-studio/Core/SSHHostKeyFingerprint.swift ldap-studio/Core/CertificateTrust.swift ldap-studio/SavedConnection.swift \
        ldap-studio/Browser/DirectoryEntry.swift ldap-studio/Browser/DirectoryTree.swift \
        ldap-studio/Browser/EntryActions.swift ldap-studio/Browser/LDIFParser.swift \
        ldap-studio/Browser/Search/SearchQuery.swift ldap-studio/Browser/Search/LDAPFilterParser.swift \
        scripts/test-server/checks/KeychainStub.swift "$@" \
        core/build/libldapstudio.a \
        -L"$B/openldap/lib" -L"$B/openssl@4/lib" -L"$B/libxcrypt/lib" -L"$B/libssh2/lib" \
        -lldap -llber -lssl -lcrypto -lcrypt -lssh2 -framework ImageIO -framework CoreGraphics \
        -o "$out"
}
build "$OUT/checks" scripts/test-server/checks/main.swift
# The MCP server: everything in ldap-studio/MCP but its Settings UI and the
# app-only controller.
build "$OUT/mcp-checks" ldap-studio/Schema/LdapSchema+Autocomplete.swift \
    ldap-studio/MCP/JSONValue.swift ldap-studio/MCP/ReadOnlyDirectory.swift \
    ldap-studio/MCP/MCPAttributePolicy.swift ldap-studio/MCP/MCPTools.swift \
    ldap-studio/MCP/MCPEndpoint.swift ldap-studio/MCP/MCPHTTPServer.swift \
    scripts/test-server/mcp-checks/main.swift

# A proxy to freeze, imitating a network that stops answering.
python3 scripts/test-server/checks/proxy.py 4389 3389 &
PROXY_PID=$!
SSHD_PID=""
cleanup() {
    kill -CONT "$PROXY_PID" 2>/dev/null || true
    kill "$PROXY_PID" 2>/dev/null || true
    if [[ -n "$SSHD_PID" ]]; then
        kill "$SSHD_PID" 2>/dev/null || true
        wait "$SSHD_PID" 2>/dev/null || true
    fi
    rm -rf "$OUT"
}
trap cleanup EXIT
sleep 0.5

DIR="${LDS_TEST_DIR:-/tmp/ldap-studio-test-server}"
# A certificate authority that has nothing to do with the server's.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=Unrelated CA" \
    -keyout "$OUT/other-ca.key" -out "$OUT/other-ca.crt" 2>/dev/null
PIN="$(openssl x509 -in "$DIR/server.crt" -outform der | shasum -a 256 | cut -d' ' -f1)" \
TEST_DIR="$DIR" OTHER_CA="$OUT/other-ca.crt" PROXY_PORT=4389 PROXY_PID="$PROXY_PID" RUN_SCRIPT="$PWD/scripts/test-server/run.sh" \
    "$OUT/checks"

"$OUT/mcp-checks"

# The SSH tunnel, through a throwaway sshd on port 2222 that only
# accepts a key generated here.
if [[ -x /usr/sbin/sshd ]]; then
    ssh-keygen -q -t ed25519 -N "" -f "$OUT/hostkey"
    ssh-keygen -q -t ed25519 -N "" -f "$OUT/clientkey"
    cp "$OUT/clientkey.pub" "$OUT/authorized_keys"
    cat > "$OUT/sshd_config" <<CONF
Port 2222
ListenAddress 127.0.0.1
HostKey $OUT/hostkey
PidFile $OUT/sshd.pid
AuthorizedKeysFile $OUT/authorized_keys
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowTcpForwarding yes
ClientAliveInterval 1
CONF
    /usr/sbin/sshd -D -f "$OUT/sshd_config" -E "$OUT/sshd.log" &
    SSHD_PID=$!
    for _ in $(seq 50); do nc -z 127.0.0.1 2222 2>/dev/null && break; sleep 0.1; done
    clang -std=c11 -Icore/include -I"$B/openldap/include" scripts/test-server/checks/ssh_check.c core/build/libldapstudio.a \
        -L"$B/openldap/lib" -L"$B/openssl@4/lib" -L"$B/libxcrypt/lib" -L"$B/libssh2/lib" \
        -lldap -llber -lssl -lcrypto -lcrypt -lssh2 -framework ImageIO -framework CoreGraphics \
        -o "$OUT/ssh_check"
    TEST_DIR="$DIR" "$OUT/ssh_check" "$OUT/clientkey"
fi
