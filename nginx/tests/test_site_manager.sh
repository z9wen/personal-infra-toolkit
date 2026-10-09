#!/bin/bash
#
# Self-contained tests for nginx/site_manager.sh.
#
# Every external command the script would use against the real system
# (docker, nginx, sudo, systemctl, acme.sh, crontab, acme_manage.sh) is
# replaced by a stub, and all Nginx, acme.sh and certbot directories live in a
# temporary directory. Test certificates are made with the real openssl.
# No root required. Works with bash 3.2 (macOS) and bash 5.

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_SRC="$TEST_DIR/../site_manager.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/site_manager_test.XXXXXX")" || exit 1
# Canonical form (no "//"), as the script computes its own path with cd/pwd
WORK="$(cd "$WORK" && pwd)" || exit 1
trap 'rm -rf "$WORK"' EXIT

if ! command -v openssl >/dev/null 2>&1; then
    echo "openssl is required to create test certificates" >&2
    exit 1
fi

FAILURES=0
STUBS="$WORK/stubs"
mkdir -p "$STUBS" "$WORK/nginx" "$WORK/home"

# Run a copy of the script so no site_manager.conf next to the real one is
# sourced; nginx/ inside WORK makes ../acme_manage.sh resolve to WORK.
SM="$WORK/nginx/site_manager.sh"
cp "$SCRIPT_SRC" "$SM"

# Start from a clean environment for every variable the script reads
unset NGINX_MODE NGINX_ROOT NATIVE_NGINX_DIR NATIVE_WEB_ROOT NATIVE_LOG_DIR NGINX_CONTAINER \
    ACME_HOME ACME_SH_PATH ACME_CONTAINER ACME_DOCKER_DATA ACME_RELOAD_CMD CERTBOT_LIVE_DIR \
    CERTBOT_HOOK_DIR ACME_MANAGE_SH ACME_MODE ACME_SERVER
# The host running the tests may not boot with systemd; the stubbed systemctl
# stands in for it. A later section covers native Nginx without systemd.
export NGINX_SYSTEMD=1

export HOME="$WORK/home"
export TEST_WORK="$WORK"
export STUB_LOG="$WORK/calls.log"
export ALL_LOG="$WORK/all_calls.log"
export STUB_CRONTAB="$WORK/crontab"
export ACME_HOME="$WORK/acme_home"
export ACME_DOCKER_DATA="$WORK/no-acme-docker-data"
export CERTBOT_LIVE_DIR="$WORK/letsencrypt/live"
export CERTBOT_HOOK_DIR="$WORK/letsencrypt/renewal-hooks/deploy"
export STUB_NGINX_FAIL="$WORK/nginx_fail"
: >"$STUB_LOG"
: >"$ALL_LOG"
mkdir -p "$ACME_HOME" "$CERTBOT_LIVE_DIR"

# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------

# Logs a call to the per-test and the cumulative log
cat >"$STUBS/_log" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$STUB_LOG"
echo "$*" >>"$ALL_LOG"
STUB

# acme.sh: only --install-cert is supported. It copies the certificate from the
# acme.sh domain directory like the real one and records the deploy target.
cat >"$STUBS/acme.sh" <<'STUB'
#!/usr/bin/env bash
"$STUB_DIR/_log" "acme.sh $*"
case " $* " in
    *" --issue "* | *" --renew "* | *" --register-account "*)
        echo "acme.sh stub: refusing to issue" >&2
        exit 99
        ;;
esac
[ "${1:-}" = "--install-cert" ] || exit 0
[ "${STUB_INSTALL_FAIL:-0}" = 1 ] && exit 1
main="" ecc="" key="" chain="" home="$ACME_HOME"
while [ $# -gt 0 ]; do
    case "$1" in
        -d) main=$2; shift ;;
        --ecc) ecc=_ecc ;;
        --key-file) key=$2; shift ;;
        --fullchain-file) chain=$2; shift ;;
        --home) home=$2; shift ;;
    esac
    shift
done
host_key=$key host_chain=$chain
if [ "${STUB_ACME_DOCKER:-0}" = 1 ]; then
    home="$STUB_ACME_DATA_MOUNT"
    host_key="$STUB_ACME_CERTS_MOUNT/${key#/certs/}"
    host_chain="$STUB_ACME_CERTS_MOUNT/${chain#/certs/}"
fi
dir="$home/$main$ecc"
cat "$dir/fullchain.cer" >"$host_chain" || exit 1
cat "$dir/$main.key" >"$host_key" || exit 1
conf="$dir/$main.conf"
touch "$conf"
grep -v '^Le_Real' "$conf" >"$conf.tmp"
printf "Le_RealKeyPath='%s'\nLe_RealFullChainPath='%s'\n" "$key" "$chain" >>"$conf.tmp"
mv "$conf.tmp" "$conf"
exit 0
STUB

# docker: "ps" lists STUB_DOCKER_NAMES as running containers, "inspect" knows
# those plus STUB_DOCKER_STOPPED, and "exec" emulates nginx and acme.sh.
cat >"$STUBS/docker" <<'STUB'
#!/usr/bin/env bash
"$STUB_DIR/_log" "docker $*"
case "$1" in
    ps)
        if [ "${2:-}" = "--format" ]; then
            for name in ${STUB_DOCKER_NAMES:-}; do echo "$name"; done
        fi
        ;;
    inspect)
        for last; do :; done
        case " ${STUB_DOCKER_NAMES:-} ${STUB_DOCKER_STOPPED:-} " in
            *" $last "*) ;;
            *) exit 1 ;;
        esac
        case "$*" in
            *'"/acme.sh"'*) echo "${STUB_ACME_DATA_MOUNT:-}" ;;
            *'"/certs"'*) echo "${STUB_ACME_CERTS_MOUNT:-}" ;;
        esac
        ;;
    exec)
        shift
        container=$1
        shift
        case "$container" in
            nginx)
                if [ "$*" = "nginx -v" ]; then
                    [ -n "${STUB_NGINX_VERSION:-}" ] && echo "nginx version: nginx/$STUB_NGINX_VERSION" >&2
                    exit 0
                fi
                if [ "$*" = "nginx -t" ]; then
                    if [ -e "$STUB_NGINX_FAIL" ] || cat "$NGINX_ROOT"/conf.d/*.conf 2>/dev/null | grep -q BROKEN; then
                        echo "nginx: [emerg] stub test failure" >&2
                        exit 1
                    fi
                    echo "nginx: configuration file test is successful"
                fi
                ;;
            acme)
                [ "$1" = "acme.sh" ] || exit 1
                shift
                STUB_ACME_DOCKER=1 exec "$STUB_DIR/acme.sh" "$@"
                ;;
        esac
        ;;
esac
exit 0
STUB

cat >"$STUBS/nginx" <<'STUB'
#!/usr/bin/env bash
"$STUB_DIR/_log" "nginx $*"
if [ "${1:-}" = "-v" ]; then
    [ -n "${STUB_NGINX_VERSION:-}" ] && echo "nginx version: nginx/$STUB_NGINX_VERSION" >&2
    exit 0
fi
if [ "${1:-}" = "-t" ]; then
    if [ -e "$STUB_NGINX_FAIL" ] || cat "$NATIVE_NGINX_DIR"/sites-enabled/*.conf 2>/dev/null | grep -q BROKEN; then
        echo "nginx: [emerg] stub test failure" >&2
        exit 1
    fi
    echo "nginx: configuration file test is successful"
fi
exit 0
STUB

# Refuses absolute paths outside the test directory, as a safety net
cat >"$STUBS/sudo" <<'STUB'
#!/usr/bin/env bash
"$STUB_DIR/_log" "sudo $*"
[ "${1:-}" = "-n" ] && shift
for arg in "$@"; do
    case $arg in
        "$TEST_WORK"/*) ;;
        /*)
            echo "sudo stub: refusing path outside test directory: $arg" >&2
            exit 1
            ;;
    esac
done
exec "$@"
STUB

cat >"$STUBS/systemctl" <<'STUB'
#!/usr/bin/env bash
"$STUB_DIR/_log" "systemctl $*"
exit 0
STUB

cat >"$STUBS/crontab" <<'STUB'
#!/usr/bin/env bash
"$STUB_DIR/_log" "crontab $*"
case "${1:-}" in
    -l)
        [ -f "$STUB_CRONTAB" ] || { echo "no crontab for user" >&2; exit 1; }
        cat "$STUB_CRONTAB"
        ;;
    -) cat >"$STUB_CRONTAB" ;;
esac
STUB

chmod +x "$STUBS"/*
export STUB_DIR="$STUBS"
export PATH="$STUBS:$PATH"

# ---------------------------------------------------------------------------
# Test certificates
# ---------------------------------------------------------------------------

CA_DIR="$WORK/ca"
mkdir -p "$CA_DIR"
: >"$CA_DIR/index.txt"
echo 01 >"$CA_DIR/serial"
cat >"$CA_DIR/openssl.cnf" <<EOF
[ ca ]
default_ca = test_ca
[ test_ca ]
dir = $CA_DIR
database = $CA_DIR/index.txt
new_certs_dir = $CA_DIR
serial = $CA_DIR/serial
default_md = sha256
policy = test_policy
unique_subject = no
copy_extensions = copy
[ test_policy ]
commonName = supplied
[ req ]
distinguished_name = test_dn
[ test_dn ]
EOF

# make_cert <cert file> <key file> <CN> <comma separated DNS names> [expired]
make_cert() {
    local cert=$1 key=$2 cn=$3 san="" name
    local IFS=,
    for name in $4; do san="${san:+$san,}DNS:$name"; done
    unset IFS
    mkdir -p "$(dirname "$cert")" "$(dirname "$key")"
    if [ "${5:-}" = "expired" ]; then
        openssl req -new -newkey rsa:2048 -nodes -keyout "$key" -out "$CA_DIR/req.csr" \
            -subj "/CN=$cn" -addext "subjectAltName=$san" -config "$CA_DIR/openssl.cnf" >/dev/null 2>&1 \
            && openssl ca -batch -selfsign -config "$CA_DIR/openssl.cnf" -keyfile "$key" \
                -in "$CA_DIR/req.csr" -out "$cert" -notext \
                -startdate 20200101000000Z -enddate 20200201000000Z >/dev/null 2>&1
    else
        openssl req -x509 -newkey rsa:2048 -nodes -keyout "$key" -out "$cert" -days 60 \
            -subj "/CN=$cn" -addext "subjectAltName=$san" -config "$CA_DIR/openssl.cnf" >/dev/null 2>&1
    fi || {
        echo "could not create test certificate $cert" >&2
        exit 1
    }
}

# make_acme_cert <acme home> <main domain> <ecc|rsa> <DNS names> [expired]
make_acme_cert() {
    local dir="$1/$2"
    [ "$3" = "ecc" ] && dir="${dir}_ecc"
    make_cert "$dir/fullchain.cer" "$dir/$2.key" "$2" "$4" "${5:-}"
    cp "$dir/fullchain.cer" "$dir/$2.cer"
    echo "Le_Domain='$2'" >"$dir/$2.conf"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

OUT=""
RC=0

# run_sm <stdin> <args...>: run the script, capture output in OUT and status in RC
run_sm() {
    local input=$1
    shift
    OUT="$(cd "$WORK" && printf '%s' "$input" | "$BASH" "$SM" "$@" 2>&1)"
    RC=$?
}

pass() { echo "ok - $1"; }
fail() {
    echo "FAIL - $1" >&2
    [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/    | /' >&2
    FAILURES=$((FAILURES + 1))
}

check() { # check <description> <command...>
    local desc=$1
    shift
    if "$@"; then pass "$desc"; else fail "$desc" "$OUT"; fi
}

rc_is() { [ "$RC" -eq "$1" ]; }
rc_nonzero() { [ "$RC" -ne 0 ]; }
out_has() {
    case $OUT in *"$1"*) return 0 ;; esac
    return 1
}
file_has() { grep -qF -- "$2" "$1" 2>/dev/null; }
log_has() { grep -qF -- "$1" "$STUB_LOG"; }
not() { ! "$@"; }
same_file() { cmp -s "$1" "$2"; }
count_lines() { grep -cF -- "$2" "$1" 2>/dev/null || true; }

# Lines of the port-80 server block of a generated HTTPS config
http_block() { awk '/^# HTTPS/ { exit } { print }' "$1"; }
http_block_has_challenge() {
    http_block "$1" | grep -q 'location ^~ /.well-known/acme-challenge/' \
        && http_block "$1" | grep -q 'return 301'
}

reset_log() { : >"$STUB_LOG"; }

# site_num <all|enabled> <domain>: the number the menu shows for a site
site_num() {
    local filter=$1 domain=$2 names n=0 name
    if [ "${NGINX_MODE:-}" = "native" ]; then
        names="$(cd "$NATIVE_NGINX_DIR/sites-available" && for f in *.conf; do
            [ -f "$f" ] || continue
            if [ "$filter" = "enabled" ] && [ ! -e "$NATIVE_NGINX_DIR/sites-enabled/$f" ]; then continue; fi
            echo "${f%.conf}"
        done | sort -u)"
    else
        names="$(cd "$NGINX_ROOT/conf.d" && for f in *.conf *.conf.disabled; do
            [ -f "$f" ] || continue
            [ "$filter" = "enabled" ] && [ "${f%.disabled}" != "$f" ] && continue
            f=${f%.disabled}
            echo "${f%.conf}"
        done | sort -u)"
    fi
    while IFS= read -r name; do
        n=$((n + 1))
        if [ "$name" = "$domain" ]; then
            echo "$n"
            return 0
        fi
    done <<<"$names"
    echo "site_num: $domain not found" >&2
    echo 999
}

# ---------------------------------------------------------------------------
# Certificates on the "machine"
# ---------------------------------------------------------------------------

echo "# Creating test certificates"
export NGINX_ROOT="$WORK/docker"
CERTS="$NGINX_ROOT/certs"
CONFD="$NGINX_ROOT/conf.d"

make_acme_cert "$ACME_HOME" example.com ecc "example.com,www.example.com"
make_acme_cert "$ACME_HOME" rsa.example.com rsa "rsa.example.com"
make_acme_cert "$ACME_HOME" "*.wild.test" ecc "*.wild.test"
make_acme_cert "$ACME_HOME" apex.test ecc "apex.test,*.apex.test"
make_acme_cert "$ACME_HOME" old.example.com ecc "old.example.com" expired
make_acme_cert "$ACME_HOME" mismatch.example.com ecc "other.test"
make_cert "$CERTBOT_LIVE_DIR/lineage-x/fullchain.pem" "$CERTBOT_LIVE_DIR/lineage-x/privkey.pem" \
    cb.example.com "cb.example.com"
make_cert "$CERTS/inst.example.com/fullchain.cer" "$CERTS/inst.example.com/inst.example.com.key" \
    inst.example.com "inst.example.com"
make_cert "$WORK/manual/cert.pem" "$WORK/manual/key.pem" man.example.com "man.example.com"
make_cert "$WORK/manual/other.pem" "$WORK/manual/other.key" man.example.com "man.example.com"
make_cert "$WORK/manual/expired.pem" "$WORK/manual/expired.key" man.example.com "man.example.com" expired

# ---------------------------------------------------------------------------
# Docker Nginx: menu-driven site management
# ---------------------------------------------------------------------------

echo "# Docker Nginx: menu"
export STUB_DOCKER_NAMES="nginx"

run_sm "" help
check "help: menu-first usage" out_has "Open the interactive menu"
check "help: points to acme_manage.sh" out_has "acme_manage.sh"

run_sm $'2\nplain.test\n0\n'
check "menu add static: succeeds" rc_is 0
check "menu add static: menu shown" out_has "Add a static site"
check "menu add static: detects Docker Nginx" out_has "Using Nginx (Docker mode)"
check "menu add static: writes config" file_has "$CONFD/plain.test.conf" "server_name plain.test;"
check "menu add static: writes index page" test -f "$NGINX_ROOT/html/plain.test/index.html"
check "menu add static: no certificate offered" out_has "No existing certificate covers plain.test"
check "menu add static: reloads container" log_has "docker exec nginx nginx -s reload"
check "menu add static: exits cleanly" out_has "Bye."

run_sm "" add plain2.test
check "cli add: succeeds" rc_is 0

# Reverse proxy for a new domain typed at the site prompt; WebSocket default yes
run_sm $'3\nproxy.test\n3000\n\n0\n'
check "menu proxy new domain: succeeds" rc_is 0
check "menu proxy: port becomes local URL" file_has "$CONFD/proxy.test.conf" "proxy_pass http://127.0.0.1:3000;"
check "menu proxy: WebSocket headers by default" file_has "$CONFD/proxy.test.conf" "proxy_set_header Upgrade"
check "menu proxy: keeps ACME challenge" file_has "$CONFD/proxy.test.conf" "location ^~ /.well-known/acme-challenge/"

# Turn an existing static site, picked by number, into a proxy without WebSocket
num="$(site_num enabled plain2.test)"
run_sm "3"$'\n'"$num"$'\n'"127.0.0.1:5000"$'\n'"n"$'\n'"0"$'\n'
check "menu proxy pick by number: succeeds" rc_is 0
check "menu proxy pick by number: host:port backend" file_has "$CONFD/plain2.test.conf" "proxy_pass http://127.0.0.1:5000;"
check "menu proxy: WebSocket can be disabled" not file_has "$CONFD/plain2.test.conf" "proxy_set_header Upgrade"

# Backend normalisation and validation
run_sm "" proxy url.test https://backend.internal:8443
check "backend: full URL kept" file_has "$CONFD/url.test.conf" "proxy_pass https://backend.internal:8443;"
run_sm "" proxy localhost.test localhost:8080 --no-websocket
check "backend: host:port" file_has "$CONFD/localhost.test.conf" "proxy_pass http://localhost:8080;"
check "backend: --no-websocket" not file_has "$CONFD/localhost.test.conf" "proxy_set_header Upgrade"
run_sm "" proxy bad.test 70000
check "backend: port out of range rejected" rc_nonzero
run_sm "" proxy bad.test "not a backend"
check "backend: garbage rejected" rc_nonzero
run_sm "" proxy bad.test "ftp://x:21"
check "backend: other schemes rejected" rc_nonzero
check "backend: nothing written for rejected backends" not test -e "$CONFD/bad.test.conf"

# Menu re-asks on an invalid backend instead of failing
run_sm $'3\nretry.test\nnope\n3001\n\n0\n'
check "menu proxy: invalid backend asked again" file_has "$CONFD/retry.test.conf" "proxy_pass http://127.0.0.1:3001;"

# A failing action returns to the menu, which keeps working
cp "$CONFD/proxy.test.conf" "$WORK/proxy.before"
num="$(site_num enabled proxy.test)"
run_sm "3"$'\n'"$num"$'\n'"http://BROKEN:1"$'\n\n'"1"$'\n'"0"$'\n'
check "menu error: script keeps running" rc_is 0
check "menu error: action reported as failed" out_has "Action not completed"
check "menu error: nginx -t failure rolled back" same_file "$CONFD/proxy.test.conf" "$WORK/proxy.before"
check "menu error: next action (list) still runs" out_has "proxy -> http://127.0.0.1:3000"
check "menu error: exits cleanly" out_has "Bye."

run_sm "" proxy new-broken.test http://BROKEN:1
check "rollback: broken new site fails" rc_nonzero
check "rollback: broken new config removed" not test -e "$CONFD/new-broken.test.conf"

# End of input in the menu or at a prompt ends cleanly instead of looping
run_sm ""
check "menu: EOF exits" rc_is 0
run_sm $'2\n'
check "menu: EOF inside an action exits" rc_is 0
check "menu: EOF inside an action is reported" out_has "No input"

run_sm "" add "../etc"
check "rejects path-like domain" rc_nonzero

# ---------------------------------------------------------------------------
# Docker Nginx: certificate discovery
# ---------------------------------------------------------------------------

echo "# Certificate discovery"
run_sm "" add discovery.example.com
run_sm "" add www.apex.test
run_sm "" add sub.wild.test
run_sm "" add old.example.com
run_sm "" add mismatch.example.com
run_sm "" add cb.example.com
run_sm "" add inst.example.com

num="$(site_num enabled www.apex.test)"
run_sm "4"$'\n'"$num"$'\n'"0"$'\n'"0"$'\n'
check "discovery: wildcard SAN in apex dir found" out_has "apex.test (ECC)"
check "discovery: wildcard marked" out_has "[wildcard]"
check "discovery: menu cancel changes nothing" not file_has "$CONFD/www.apex.test.conf" "listen 443"

num="$(site_num enabled sub.wild.test)"
run_sm "4"$'\n'"$num"$'\n'"0"$'\n'"0"$'\n'
check "discovery: *.parent acme dir found" out_has "*.wild.test (ECC)"

num="$(site_num enabled cb.example.com)"
run_sm "4"$'\n'"$num"$'\n'"0"$'\n'"0"$'\n'
check "discovery: certbot lineage matched by SAN" out_has "lineage-x"
check "discovery: certbot source shown" out_has "certbot"

num="$(site_num enabled inst.example.com)"
run_sm "4"$'\n'"$num"$'\n'"0"$'\n'"0"$'\n'
check "discovery: installed certificate found" out_has "installed"

run_sm "" ssl old.example.com
check "discovery: expired certificate rejected" rc_nonzero
check "discovery: expired certificate reported" out_has "Ignored 1 expired"
run_sm "" ssl mismatch.example.com
check "discovery: non-matching certificate rejected" rc_nonzero
check "discovery: no config change for rejected certificate" not file_has "$CONFD/mismatch.example.com.conf" "listen 443"
run_sm "" ssl discovery.example.com
check "discovery: sibling of an exact certificate is not covered" rc_nonzero

# ---------------------------------------------------------------------------
# Docker Nginx: attaching certificates
# ---------------------------------------------------------------------------

echo "# Attach: native acme.sh"
export ACME_SH_PATH="$STUBS/acme.sh"

run_sm "" add example.com
reset_log
run_sm "" ssl example.com
check "acme ecc: attach succeeds" rc_is 0
check "acme ecc: --install-cert with --ecc and reloadcmd" \
    log_has "acme.sh --install-cert -d example.com --ecc --key-file $CERTS/example.com/example.com.key --fullchain-file $CERTS/example.com/fullchain.cer --reloadcmd docker exec nginx nginx -s reload"
check "acme ecc: custom ACME_HOME passed" log_has "--home $ACME_HOME"
check "acme ecc: config uses container cert path" file_has "$CONFD/example.com.conf" "ssl_certificate /etc/nginx/certs/example.com/fullchain.cer;"
check "acme ecc: config uses container key path" file_has "$CONFD/example.com.conf" "ssl_certificate_key /etc/nginx/certs/example.com/example.com.key;"
check "acme ecc: certificate deployed" same_file "$CERTS/example.com/fullchain.cer" "$ACME_HOME/example.com_ecc/fullchain.cer"
check "acme ecc: port 80 keeps ACME challenge" http_block_has_challenge "$CONFD/example.com.conf"
check "acme ecc: no certificate issued" not log_has "--issue"

run_sm "" list
check "list: shows HTTPS" out_has "HTTPS"
check "list: shows certificate expiry" out_has "expires 20"
check "list: shows proxy backend" out_has "proxy -> http://127.0.0.1:3000"
check "list: shows static" out_has "static"

# The RSA directory has an existing deploy target inside the cert dir: reused
printf "Le_RealKeyPath='%s'\nLe_RealFullChainPath='%s'\n" \
    "$CERTS/legacy-rsa/rsa.key" "$CERTS/legacy-rsa/fullchain.cer" >>"$ACME_HOME/rsa.example.com/rsa.example.com.conf"
reset_log
# Menu: add a site, and accept the HTTPS offer with the default (first) certificate
run_sm $'2\nrsa.example.com\n\n0\n'
check "acme rsa: offered after add and attached" file_has "$CONFD/rsa.example.com.conf" "listen 443 ssl"
check "acme rsa: no --ecc for RSA directory" log_has "acme.sh --install-cert -d rsa.example.com --key-file"
check "acme rsa: existing deploy target reused" log_has "--fullchain-file $CERTS/legacy-rsa/fullchain.cer"
check "acme rsa: config follows reused target" file_has "$CONFD/rsa.example.com.conf" "ssl_certificate /etc/nginx/certs/legacy-rsa/fullchain.cer;"

reset_log
run_sm "" ssl sub.wild.test
check "acme wildcard dir: attach succeeds" rc_is 0
check "acme wildcard dir: installs *.parent certificate" log_has "--install-cert -d *.wild.test --ecc"
check "acme wildcard dir: stored without '*' in path" file_has "$CONFD/sub.wild.test.conf" "ssl_certificate /etc/nginx/certs/wildcard.wild.test/fullchain.cer;"

# HTTPS keeps the proxy backend; updating the backend keeps HTTPS
run_sm "" proxy api.apex.test 4000
reset_log
run_sm "" ssl api.apex.test
check "proxy https: attach succeeds" rc_is 0
check "proxy https: wildcard from apex certificate" log_has "--install-cert -d apex.test --ecc"
check "proxy https: backend kept" file_has "$CONFD/api.apex.test.conf" "proxy_pass http://127.0.0.1:4000;"
check "proxy https: HTTPS enabled" file_has "$CONFD/api.apex.test.conf" "listen 443 ssl"
check "proxy https: WebSocket kept" file_has "$CONFD/api.apex.test.conf" "proxy_set_header Upgrade"
check "proxy https: no static root" not file_has "$CONFD/api.apex.test.conf" "try_files \$uri \$uri/"
check "proxy https: port 80 keeps ACME challenge" http_block_has_challenge "$CONFD/api.apex.test.conf"
run_sm "" proxy api.apex.test 4001
check "proxy update: keeps HTTPS" file_has "$CONFD/api.apex.test.conf" "ssl_certificate /etc/nginx/certs/apex.test/fullchain.cer;"
check "proxy update: new backend" file_has "$CONFD/api.apex.test.conf" "proxy_pass http://127.0.0.1:4001;"
check "proxy update: certificate note kept" file_has "$CONFD/api.apex.test.conf" "# SSL Certificate (source: acme.sh, certificate: apex.test)"

# A failing nginx -t during attach restores the previous configuration
cp "$CONFD/www.apex.test.conf" "$WORK/www.before"
touch "$STUB_NGINX_FAIL"
run_sm "" ssl www.apex.test
rm -f "$STUB_NGINX_FAIL"
check "attach rollback: fails" rc_nonzero
check "attach rollback: previous config restored" same_file "$CONFD/www.apex.test.conf" "$WORK/www.before"

export STUB_INSTALL_FAIL=1
run_sm "" ssl www.apex.test
unset STUB_INSTALL_FAIL
check "install-cert failure: reported" rc_nonzero
check "install-cert failure: config untouched" same_file "$CONFD/www.apex.test.conf" "$WORK/www.before"

run_sm "" ssl example.com --wildcard
check "old issuing options rejected" rc_nonzero
check "old issuing options point to acme_manage.sh" out_has "acme_manage.sh"

echo "# Attach: installed certificate"
reset_log
num="$(site_num enabled inst.example.com)"
run_sm "4"$'\n'"$num"$'\n'"1"$'\n'"0"$'\n'
check "installed: attach via menu succeeds" file_has "$CONFD/inst.example.com.conf" "ssl_certificate /etc/nginx/certs/inst.example.com/fullchain.cer;"
check "installed: no acme.sh call" not log_has "--install-cert"

echo "# Attach: certbot (Docker Nginx)"
reset_log
run_sm "" ssl cb.example.com
HOOK="$CERTBOT_HOOK_DIR/site-manager-lineage-x.sh"
check "certbot docker: attach succeeds" rc_is 0
check "certbot docker: copied into nginx cert dir" same_file "$CERTS/certbot-lineage-x/fullchain.cer" "$CERTBOT_LIVE_DIR/lineage-x/fullchain.pem"
check "certbot docker: key copied" same_file "$CERTS/certbot-lineage-x/certbot-lineage-x.key" "$CERTBOT_LIVE_DIR/lineage-x/privkey.pem"
check "certbot docker: config uses copy" file_has "$CONFD/cb.example.com.conf" "ssl_certificate /etc/nginx/certs/certbot-lineage-x/fullchain.cer;"
check "certbot docker: deploy hook written" test -x "$HOOK"
check "certbot docker: hook re-copies" file_has "$HOOK" "$CERTS/certbot-lineage-x/fullchain.cer"
check "certbot docker: hook reloads Nginx" file_has "$HOOK" "docker exec nginx nginx -s reload"
# Simulate a renewal and run the hook as certbot would
make_cert "$CERTBOT_LIVE_DIR/lineage-x/fullchain.pem" "$CERTBOT_LIVE_DIR/lineage-x/privkey.pem" \
    cb.example.com "cb.example.com"
reset_log
RENEWED_LINEAGE="$CERTBOT_LIVE_DIR/lineage-x" sh "$HOOK"
check "certbot hook: renewed certificate copied" same_file "$CERTS/certbot-lineage-x/fullchain.cer" "$CERTBOT_LIVE_DIR/lineage-x/fullchain.pem"
check "certbot hook: reloads" log_has "docker exec nginx nginx -s reload"
reset_log
RENEWED_LINEAGE="$CERTBOT_LIVE_DIR/other" sh "$HOOK"
check "certbot hook: ignores other lineages" not log_has "nginx -s reload"

echo "# Attach: manual paths"
run_sm "" add man.example.com
num="$(site_num enabled man.example.com)"
run_sm "4"$'\n'"$num"$'\n'"y"$'\n'"$WORK/manual/cert.pem"$'\n'"$WORK/manual/key.pem"$'\n'"0"$'\n'
check "manual: attach via menu succeeds" file_has "$CONFD/man.example.com.conf" "ssl_certificate /etc/nginx/certs/manual-man.example.com/fullchain.cer;"
check "manual: certificate copied" same_file "$CERTS/manual-man.example.com/fullchain.cer" "$WORK/manual/cert.pem"
check "manual: renewal warning" out_has "renewal is NOT automatic"
run_sm "" ssl man.example.com --cert "$WORK/manual/cert.pem" --key "$WORK/manual/other.key"
check "manual: mismatched key rejected" rc_nonzero
check "manual: mismatched key reported" out_has "does not match"
run_sm "" ssl man.example.com --cert "$WORK/manual/expired.pem" --key "$WORK/manual/expired.key"
check "manual: expired certificate rejected" rc_nonzero
run_sm "" ssl plain.test --cert "$WORK/manual/cert.pem" --key "$WORK/manual/key.pem"
check "manual cli: certificate for another name rejected" rc_nonzero

# ---------------------------------------------------------------------------
# Docker Nginx + Docker acme container
# ---------------------------------------------------------------------------

echo "# Attach: Docker acme container"
export STUB_DOCKER_NAMES="nginx acme"
export STUB_ACME_DATA_MOUNT="$WORK/acme_docker_data"
export STUB_ACME_CERTS_MOUNT="$CERTS"
make_acme_cert "$STUB_ACME_DATA_MOUNT" dock.example.com ecc "dock.example.com"

reset_log
# Add the site, accept the certificate offer and the cron job (both default yes)
run_sm $'2\ndock.example.com\n\n\n0\n'
check "docker acme: attach succeeds" file_has "$CONFD/dock.example.com.conf" "listen 443 ssl"
check "docker acme: install-cert inside the container" \
    log_has "docker exec acme acme.sh --install-cert -d dock.example.com --ecc --key-file /certs/dock.example.com/dock.example.com.key --fullchain-file /certs/dock.example.com/fullchain.cer"
check "docker acme: reloadcmd touches marker" log_has "--reloadcmd touch /certs/.reload-nginx"
check "docker acme: config uses container cert path" file_has "$CONFD/dock.example.com.conf" "ssl_certificate /etc/nginx/certs/dock.example.com/fullchain.cer;"
check "docker acme: cron job added" file_has "$STUB_CRONTAB" "$SM reload-if-renewed"
check "docker acme: marker cleared after attach" not test -e "$CERTS/.reload-nginx"

num="$(site_num enabled dock.example.com)"
run_sm "4"$'\n'"$num"$'\n'"1"$'\n'"0"$'\n'
check "docker acme: re-attach succeeds" rc_is 0
check "docker acme: cron entry is idempotent" test "$(count_lines "$STUB_CRONTAB" "reload-if-renewed")" -eq 1

# Docker acme data found at the configured default when the container is gone
export STUB_DOCKER_NAMES="nginx"
export ACME_DOCKER_DATA="$STUB_ACME_DATA_MOUNT"
num="$(site_num enabled dock.example.com)"
run_sm "4"$'\n'"$num"$'\n'"0"$'\n'"0"$'\n'
check "docker acme default dir: certificate listed" out_has "acme.sh (docker)"
run_sm "" ssl dock.example.com
check "docker acme stopped: attach refused" rc_nonzero
check "docker acme stopped: explains" out_has "is not running"
export ACME_DOCKER_DATA="$WORK/no-acme-docker-data"
export STUB_DOCKER_NAMES="nginx acme"

reset_log
run_sm "" reload-if-renewed
check "reload-if-renewed: no-op without marker" rc_is 0
check "reload-if-renewed: no reload without marker" not log_has "nginx -s reload"
touch "$CERTS/.reload-nginx"
run_sm "" reload-if-renewed
check "reload-if-renewed: succeeds with marker" rc_is 0
check "reload-if-renewed: reloads Nginx" log_has "docker exec nginx nginx -s reload"
check "reload-if-renewed: clears marker" not test -e "$CERTS/.reload-nginx"

# ---------------------------------------------------------------------------
# Docker Nginx: enable / disable / delete / logs / acme_manage.sh
# ---------------------------------------------------------------------------

echo "# Docker Nginx: other menu actions"
num="$(site_num all proxy.test)"
run_sm "5"$'\n'"$num"$'\n\n'"0"$'\n'
check "menu disable: renames config" test -f "$CONFD/proxy.test.conf.disabled"
run_sm "" list
check "list: shows disabled" out_has "disabled"
run_sm "" ssl proxy.test
check "ssl on disabled site refused" rc_nonzero
num="$(site_num all proxy.test)"
run_sm "5"$'\n'"$num"$'\n\n'"0"$'\n'
check "menu enable: restores config" test -f "$CONFD/proxy.test.conf"

mkdir -p "$NGINX_ROOT/logs/proxy.test"
echo "docker-access-line" >"$NGINX_ROOT/logs/proxy.test/access.log"
num="$(site_num all proxy.test)"
run_sm "7"$'\n'"$num"$'\n'"5"$'\n'"0"$'\n'
check "menu logs: shows access log" out_has "docker-access-line"

num="$(site_num all example.com)"
run_sm "6"$'\n'"$num"$'\n'"no"$'\n'"0"$'\n'
check "menu delete: cancelled without 'yes'" test -f "$CONFD/example.com.conf"
run_sm "6"$'\n'"$num"$'\n'"yes"$'\n'"0"$'\n'
check "menu delete: config removed" not test -e "$CONFD/example.com.conf"
check "menu delete: web root removed" not test -e "$NGINX_ROOT/html/example.com"
check "menu delete: certificate kept" test -f "$CERTS/example.com/fullchain.cer"
check "menu delete: backup created" test -n "$(ls -d "$NGINX_ROOT"/backups/example.com-* 2>/dev/null)"

# Option 9 runs acme_manage.sh found next to the nginx/ directory, then offers to attach
cat >"$WORK/acme_manage.sh" <<STUB
"$STUBS/_log" "acme_manage.sh ran"
mkdir -p "$ACME_HOME/fresh.example.com_ecc"
cp "$WORK/fresh/fullchain.cer" "$ACME_HOME/fresh.example.com_ecc/fullchain.cer"
cp "$WORK/fresh/fresh.example.com.key" "$ACME_HOME/fresh.example.com_ecc/fresh.example.com.key"
STUB
make_cert "$WORK/fresh/fullchain.cer" "$WORK/fresh/fresh.example.com.key" fresh.example.com "fresh.example.com"
run_sm "" add fresh.example.com
reset_log
num="$(site_num enabled fresh.example.com)"
run_sm "9"$'\n\n'"$num"$'\n\n'"0"$'\n'
check "issue: acme_manage.sh started" log_has "acme_manage.sh ran"
check "issue: new certificate attached afterwards" file_has "$CONFD/fresh.example.com.conf" "ssl_certificate /etc/nginx/certs/fresh.example.com/fullchain.cer;"
rm -f "$WORK/acme_manage.sh"
export ACME_MANAGE_SH="$WORK/missing/acme_manage.sh"
run_sm $'9\n0\n'
check "issue: missing acme_manage.sh explained" out_has "raw.githubusercontent.com"
unset ACME_MANAGE_SH

# ---------------------------------------------------------------------------
# Container detection matches exact names only
# ---------------------------------------------------------------------------

echo "# Container detection"
export STUB_DOCKER_NAMES="nginx-proxy-manager"
export NATIVE_NGINX_DIR="$WORK/native/etc/nginx"
export NATIVE_WEB_ROOT="$WORK/native/www"
export NATIVE_LOG_DIR="$WORK/native/log"
run_sm "" list
check "nginx-proxy-manager is not the nginx container" out_has "Using Nginx (Native mode)"

# ---------------------------------------------------------------------------
# Native Nginx
# ---------------------------------------------------------------------------

echo "# Native Nginx"
export NGINX_MODE="native"
export STUB_DOCKER_NAMES=""
AVAIL="$NATIVE_NGINX_DIR/sites-available"
ENABLED="$NATIVE_NGINX_DIR/sites-enabled"
NCERTS="$NATIVE_NGINX_DIR/certs"

reset_log
run_sm $'2\nsite.test\n0\n'
check "native menu add: succeeds" rc_is 0
check "native add: config in sites-available" test -f "$AVAIL/site.test.conf"
check "native add: enabled via symlink" test -L "$ENABLED/site.test.conf"
check "native add: webroot created" test -f "$NATIVE_WEB_ROOT/site.test/index.html"
check "native add: log dir created" test -d "$NATIVE_LOG_DIR/site.test"
check "native add: config uses native web root" file_has "$AVAIL/site.test.conf" "root $NATIVE_WEB_ROOT/site.test;"
check "native add: config uses native log dir" file_has "$AVAIL/site.test.conf" "access_log $NATIVE_LOG_DIR/site.test/access.log;"
check "native add: reloads systemd service" log_has "systemctl reload nginx"

if [ "$(id -u)" -eq 0 ]; then
    expected_reload="--reloadcmd systemctl reload nginx"
else
    expected_reload="--reloadcmd sudo -n systemctl reload nginx"
fi
run_sm "" add example.com
reset_log
run_sm "" ssl example.com
check "native acme: attach succeeds" rc_is 0
check "native acme: installs into native cert dir" log_has "--key-file $NCERTS/example.com/example.com.key"
check "native acme: reloadcmd uses systemctl" log_has "$expected_reload"
check "native acme: config references native certs" file_has "$AVAIL/example.com.conf" "ssl_certificate $NCERTS/example.com/fullchain.cer;"
check "native acme: port 80 keeps ACME challenge" http_block_has_challenge "$AVAIL/example.com.conf"

# Menu proxy on a native site picked by number keeps HTTPS
num="$(site_num enabled example.com)"
run_sm "3"$'\n'"$num"$'\n'"8080"$'\n\n'"0"$'\n'
check "native proxy on HTTPS site: backend set" file_has "$AVAIL/example.com.conf" "proxy_pass http://127.0.0.1:8080;"
check "native proxy on HTTPS site: HTTPS kept" file_has "$AVAIL/example.com.conf" "ssl_certificate $NCERTS/example.com/fullchain.cer;"

run_sm "" add cb.example.com
reset_log
run_sm "" ssl cb.example.com
check "certbot native: attach succeeds" rc_is 0
check "certbot native: live files used in place" file_has "$AVAIL/cb.example.com.conf" "ssl_certificate $CERTBOT_LIVE_DIR/lineage-x/fullchain.pem;"
check "certbot native: hook reloads systemd" file_has "$HOOK" "systemctl reload nginx"
check "certbot native: hook does not copy" not file_has "$HOOK" "install -m"

# Docker acme container with native Nginx: the config references its host mount
export STUB_DOCKER_NAMES="acme"
export STUB_ACME_CERTS_MOUNT="$WORK/acme_certs_host"
mkdir -p "$STUB_ACME_CERTS_MOUNT"
run_sm "" add dock.example.com
reset_log
run_sm "" ssl dock.example.com
check "native + docker acme: attach succeeds" rc_is 0
check "native + docker acme: config uses host mount" file_has "$AVAIL/dock.example.com.conf" "ssl_certificate $STUB_ACME_CERTS_MOUNT/dock.example.com/fullchain.cer;"
check "native + docker acme: cron hint printed" out_has "reload-if-renewed"
touch "$STUB_ACME_CERTS_MOUNT/.reload-nginx"
reset_log
run_sm "" reload-if-renewed
check "native reload-if-renewed: reloads" log_has "systemctl reload nginx"
check "native reload-if-renewed: clears marker in acme mount" not test -e "$STUB_ACME_CERTS_MOUNT/.reload-nginx"
export STUB_DOCKER_NAMES=""

run_sm "" proxy bad.test http://BROKEN:1
check "native broken proxy: fails" rc_nonzero
check "native broken proxy: config removed" not test -e "$AVAIL/bad.test.conf"
check "native broken proxy: symlink removed" not test -e "$ENABLED/bad.test.conf"

num="$(site_num all site.test)"
run_sm "5"$'\n'"$num"$'\n\n'"0"$'\n'
check "native disable: symlink removed" not test -e "$ENABLED/site.test.conf"
check "native disable: config kept" test -f "$AVAIL/site.test.conf"
run_sm "" list
check "native list: shows disabled" out_has "disabled"
run_sm "" enable site.test
check "native cli enable: symlink restored" test -L "$ENABLED/site.test.conf"
run_sm "" disable site.test
check "native cli disable: symlink removed" not test -e "$ENABLED/site.test.conf"
run_sm "" enable site.test

echo "hello-access-line" >"$NATIVE_LOG_DIR/site.test/access.log"
echo "hello-error-line" >"$NATIVE_LOG_DIR/site.test/error.log"
run_sm "" logs site.test 5
check "native logs: reads native log dir" out_has "hello-error-line"

run_sm "yes" delete site.test
check "native cli delete: succeeds" rc_is 0
check "native delete: config removed" not test -e "$AVAIL/site.test.conf"
check "native delete: symlink removed" not test -e "$ENABLED/site.test.conf"
check "native delete: webroot removed" not test -e "$NATIVE_WEB_ROOT/site.test"
check "native delete: backup created" test -f "$(ls -d "$NATIVE_NGINX_DIR"/backups/site.test-*/ 2>/dev/null | head -n 1)site.test.conf"

# ---------------------------------------------------------------------------
# site_manager.conf can override defaults
# ---------------------------------------------------------------------------

echo "# site_manager.conf"
export NGINX_MODE="docker"
export STUB_DOCKER_NAMES="nginx"
echo "NGINX_ROOT=\"$WORK/fromconf\"" >"$WORK/nginx/site_manager.conf"
(
    unset NGINX_ROOT
    run_sm "" add conf.test
    [ -f "$WORK/fromconf/conf.d/conf.test.conf" ]
) && pass "conf: NGINX_ROOT override honoured" || fail "conf: NGINX_ROOT override honoured"
rm -f "$WORK/nginx/site_manager.conf"

# ---------------------------------------------------------------------------
# HTTP/2 syntax follows the Nginx version
# ---------------------------------------------------------------------------

echo "# HTTP/2 listen syntax"
for case in "1.22.1:old" "1.24.0:old" "1.25.1:new" "1.30.0:new" ":old"; do
    export STUB_NGINX_VERSION=${case%%:*}
    expected=${case##*:}
    cert_dir="$WORK/http2-${STUB_NGINX_VERSION:-unknown}"
    mkdir -p "$cert_dir"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 -subj "/CN=h2.test" \
        -keyout "$cert_dir/key.pem" -out "$cert_dir/cert.pem" >/dev/null 2>&1
    run_sm "" delete h2.test <<<"yes" >/dev/null 2>&1 || true
    run_sm "" add h2.test
    run_sm "" ssl h2.test --cert "$cert_dir/cert.pem" --key "$cert_dir/key.pem"
    conf=$(find "$WORK" -path '*h2.test.conf' -not -path '*backup*' | head -n 1)
    if [ "$expected" = new ]; then
        check "nginx ${STUB_NGINX_VERSION}: uses 'http2 on;'" file_has "$conf" "http2 on;"
    else
        check "nginx ${STUB_NGINX_VERSION:-unknown}: uses 'listen 443 ssl http2'" file_has "$conf" "listen 443 ssl http2;"
    fi
    run_sm $'yes\n' delete h2.test
done
unset STUB_NGINX_VERSION

# ---------------------------------------------------------------------------
# Native Nginx without systemd (containers, minimal hosts)
# ---------------------------------------------------------------------------

echo "# Native Nginx without systemd"
cat >"$STUBS/pgrep" <<'STUB'
#!/usr/bin/env bash
echo "pgrep $*" >>"$STUB_LOG"
[ "$*" = "-x nginx" ]
STUB
chmod +x "$STUBS/pgrep"
export NGINX_MODE="native" NGINX_SYSTEMD=0
reset_log
run_sm "" add nosystemd.test
check "no systemd: add succeeds when the nginx process runs" rc_is 0
check "no systemd: running state comes from pgrep" log_has "pgrep -x nginx"
check "no systemd: reloads with nginx -s reload" log_has "nginx -s reload"
check "no systemd: systemctl is never used" not log_has "systemctl"
rm -f "$STUBS/pgrep"
export NGINX_SYSTEMD=1

# ---------------------------------------------------------------------------
# Never issue certificates
# ---------------------------------------------------------------------------

if grep -q -- "--issue" "$ALL_LOG"; then
    fail "no acme.sh --issue was ever run" "$(grep -- "--issue" "$ALL_LOG")"
else
    pass "no acme.sh --issue was ever run"
fi

echo ""
if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES test(s) failed" >&2
    exit 1
fi
echo "site_manager tests passed"
