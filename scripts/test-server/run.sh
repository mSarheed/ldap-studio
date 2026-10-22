#!/usr/bin/env bash
set -euo pipefail

# A local OpenLDAP server for testing ldap-studio against a large
# directory: the slapd built along with the libraries the app bundles
# (core/build/deps, see core/deps/build.sh) — no Docker or Homebrew needed.
#
#   scripts/test-server/run.sh start   generate data (first run), start slapd
#   scripts/test-server/run.sh stop
#   scripts/test-server/run.sh reset   stop, delete all data, start fresh
#
# Listens on ldap://127.0.0.1:3389 (StartTLS available) and
# ldaps://127.0.0.1:3636, with a certificate for localhost from a test
# CA (see write_certificates). Two suffixes:
#
#   dc=example,dc=com  ~151k entries; ou=People has 76,000 direct children
#   dc=small,dc=test   a couple of dozen entries
#
# Like Active Directory's MaxPageSize, a plain search returns at most 500
# entries ("Size limit exceeded"); a paged search (RFC 2696) can read
# everything, 500 per page. The rootdn ignores limits, so bind as one of:
#
#   cn=manager,ou=Service,dc=example,dc=com / manager   read + write
#   cn=reader,ou=Service,dc=example,dc=com  / reader    read only
#   cn=manager,dc=small,dc=test             / manager   small directory
#
# ou=Restricted is listed in the tree but can't be searched under, so
# expanding it fails — for checking per-node errors.

cd "$(dirname "$0")"

DIR="${LDS_TEST_DIR:-/tmp/ldap-studio-test-server}"
OPENLDAP="$(cd ../.. && pwd)/core/build/deps"
SLAPD="$OPENLDAP/libexec/slapd"
SCHEMA="$OPENLDAP/etc/openldap/schema"
PIDFILE="$DIR/slapd.pid"

stop() {
    local pid
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        echo "stopped slapd"
    fi
}

write_config() {
    cat > "$DIR/slapd.conf" <<EOF
include         $SCHEMA/core.schema
include         $SCHEMA/cosine.schema
include         $SCHEMA/inetorgperson.schema
include         $SCHEMA/nis.schema

pidfile         $PIDFILE
argsfile        $DIR/slapd.args

TLSCertificateFile    $DIR/server.crt
TLSCertificateKeyFile $DIR/server.key

database        mdb
maxsize         4294967296
suffix          "dc=example,dc=com"
rootdn          "cn=admin,dc=example,dc=com"
rootpw          secret
directory       $DIR/example
index           objectClass eq
index           cn,uid,ou,mail,sn,givenName eq,sub
# AD-like: plain searches stop at 500, paged searches see everything.
limits          users size.soft=500 size.hard=500 size.pr=500 size.prtotal=unlimited
limits          anonymous size.soft=500 size.hard=500 size.pr=500 size.prtotal=unlimited

# The ou=Restricted entry itself can be read (so it shows up in its
# parent's listing) but not searched, so a search based at it is refused.
access to dn.base="ou=Restricted,dc=example,dc=com" attrs=entry
        by users =rd
access to dn.children="ou=Restricted,dc=example,dc=com"
        by * none
access to attrs=userPassword
        by dn.exact="cn=manager,ou=Service,dc=example,dc=com" write
        by self write
        by anonymous auth
        by * none
access to *
        by dn.exact="cn=manager,ou=Service,dc=example,dc=com" write
        by users read
        by anonymous auth

database        mdb
maxsize         104857600
suffix          "dc=small,dc=test"
rootdn          "cn=admin,dc=small,dc=test"
rootpw          secret
directory       $DIR/small
index           objectClass eq
access to attrs=userPassword
        by dn.exact="cn=manager,dc=small,dc=test" write
        by anonymous auth
        by * none
access to *
        by dn.exact="cn=manager,dc=small,dc=test" write
        by users read
        by anonymous auth
EOF
}

# A root CA, an issuing CA under it, and the server's certificate from the
# issuing CA, the way an Active Directory domain controller's usually is.
# The server sends its own certificate and the issuing CA's, not the
# root's. Issued to localhost only, so 127.0.0.1 is a name mismatch.
write_certificates() {
    local ext="$DIR/cert.ext"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=LDAP Studio Test Root CA" \
        -keyout "$DIR/root-ca.key" -out "$DIR/root-ca.crt" 2>/dev/null
    printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n' > "$ext"
    openssl req -new -newkey rsa:2048 -nodes -subj "/CN=LDAP Studio Test Issuing CA" \
        -keyout "$DIR/issuing-ca.key" -out "$DIR/issuing-ca.csr" 2>/dev/null
    openssl x509 -req -days 3650 -in "$DIR/issuing-ca.csr" -CA "$DIR/root-ca.crt" -CAkey "$DIR/root-ca.key" \
        -set_serial 2 -extfile "$ext" -out "$DIR/issuing-ca.crt" 2>/dev/null
    printf 'basicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost\n' > "$ext"
    openssl req -new -newkey rsa:2048 -nodes -subj "/CN=localhost" \
        -keyout "$DIR/server.key" -out "$DIR/server.csr" 2>/dev/null
    openssl x509 -req -days 3650 -in "$DIR/server.csr" -CA "$DIR/issuing-ca.crt" -CAkey "$DIR/issuing-ca.key" \
        -set_serial 3 -extfile "$ext" -out "$DIR/server-only.crt" 2>/dev/null
    cat "$DIR/server-only.crt" "$DIR/issuing-ca.crt" > "$DIR/server.crt"
    rm -f "$ext" "$DIR"/*.csr
}

seed() {
    mkdir -p "$DIR/example" "$DIR/small"
    if [[ ! -f "$DIR/issuing-ca.crt" ]]; then
        write_certificates
    fi
    write_config
    if [[ ! -f "$DIR/example/data.mdb" ]]; then
        echo "==> generating test data"
        python3 generate.py "$DIR"
        echo "==> loading dc=example,dc=com (takes a minute)"
        "$OPENLDAP/sbin/slapadd" -q -f "$DIR/slapd.conf" -b "dc=example,dc=com" -l "$DIR/example.ldif"
        "$OPENLDAP/sbin/slapadd" -q -f "$DIR/slapd.conf" -b "dc=small,dc=test" -l "$DIR/small.ldif"
    fi
}

start() {
    # The libraries, slapd among them: built the first time (a few
    # minutes), checked after that.
    make -C ../../core deps
    seed
    stop
    "$SLAPD" -f "$DIR/slapd.conf" -h "ldap://127.0.0.1:3389/ ldaps://127.0.0.1:3636/"
    echo "slapd running: ldap://127.0.0.1:3389  ldaps://127.0.0.1:3636  (data in $DIR)"
}

case "${1:-start}" in
    start) start ;;
    stop) stop ;;
    reset) stop; rm -rf "$DIR"; start ;;
    *) echo "usage: $0 start|stop|reset" >&2; exit 1 ;;
esac
