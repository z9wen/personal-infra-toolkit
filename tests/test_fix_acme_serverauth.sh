#!/usr/bin/env bash
# Offline tests for fix_acme_serverauth.sh. The script is executed as its own
# bash process (so its set -e behaves as in production) against a temporary
# ACME_HOME. Works with bash 3.2 and bash 5.

set -u

SELF="$0"
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="${REPO_ROOT}/fix_acme_serverauth.sh"
TEST_BASH=${BASH:-bash}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    grep -qF -- "$2" "$1" || {
        echo "--- $1 ---" >&2
        cat "$1" >&2
        fail "expected '$2' in $1"
    }
}

setup_env() {
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/test_fix_acme.XXXXXX")
    trap 'rm -rf "$WORK"' EXIT
    export ACME_HOME="$WORK/acme home"
    export ACME_ENV_FILE="$WORK/acme.env"
    mkdir -p "$ACME_HOME"
}

# Creates <domain>/<domain>.csr.conf (+ .csr) requesting EKU $2.
make_csr() {
    local domain=$1 eku=$2
    mkdir -p "$ACME_HOME/$domain"
    printf '[ v3_req ]\nextendedKeyUsage=%s\n' "$eku" >"$ACME_HOME/$domain/$domain.csr.conf"
    echo "CSR" >"$ACME_HOME/$domain/$domain.csr"
}

run_script() {
    local input=$1
    mkdir -p "$WORK/tmp"
    printf '%s\n' "$input" | TMPDIR="$WORK/tmp" "$TEST_BASH" "$SCRIPT" >"$WORK/out" 2>&1
}

test_removes_multiple_polluted_csrs() {
    setup_env
    make_csr a.example "serverAuth,clientAuth"
    make_csr b.example "serverAuth,clientAuth"
    make_csr c_ecc.example "clientAuth"
    make_csr clean.example "serverAuth"
    printf "%s\n" "ACCOUNT_EMAIL='ops@example.com'" "Le_ExtKeyUse='serverAuth,clientAuth'" >"$ACME_HOME/account.conf"

    run_script y || {
        cat "$WORK/out" >&2
        fail "script exited non-zero"
    }
    local d
    for d in a.example b.example c_ecc.example; do
        [[ ! -e "$ACME_HOME/$d/$d.csr.conf" ]] || fail "$d.csr.conf not removed"
        [[ ! -e "$ACME_HOME/$d/$d.csr" ]] || fail "$d.csr not removed"
    done
    [[ -f "$ACME_HOME/clean.example/clean.example.csr.conf" ]] || fail "clean CSR config must be kept"
    assert_contains "$WORK/out" "Removed 3 polluted CSR config(s)."
    assert_contains "$WORK/out" "All CSR configs are free of clientAuth entries."
    assert_contains "$ACME_HOME/account.conf" "Le_ExtKeyUse='serverAuth'"
    assert_contains "$ACME_HOME/account.conf" "ACCOUNT_EMAIL='ops@example.com'"
    if grep -q "clientAuth" "$ACME_HOME/account.conf"; then
        fail "clientAuth left in account.conf"
    fi
}

test_appends_ext_key_use_when_missing() {
    setup_env
    echo "ACCOUNT_EMAIL='ops@example.com'" >"$ACME_HOME/account.conf"
    run_script n || fail "script exited non-zero"
    assert_contains "$ACME_HOME/account.conf" "Le_ExtKeyUse='serverAuth'"
    assert_contains "$WORK/out" "No polluted CSR config files detected."
}

test_declined_cleanup_keeps_files() {
    setup_env
    make_csr a.example "clientAuth"
    echo "Le_ExtKeyUse='serverAuth'" >"$ACME_HOME/account.conf"
    run_script n || fail "script exited non-zero"
    [[ -f "$ACME_HOME/a.example/a.example.csr.conf" ]] || fail "declined cleanup removed files"
    assert_contains "$WORK/out" "Skipping CSR cleanup."
    assert_contains "$WORK/out" "Le_ExtKeyUse already set to serverAuth."
    assert_contains "$WORK/out" "Still detected clientAuth in:"
}

test_no_temp_file_left_when_already_set() {
    setup_env
    echo "Le_ExtKeyUse='serverAuth'" >"$ACME_HOME/account.conf"
    run_script n || fail "script exited non-zero"
    local leftovers
    leftovers=$(find "$WORK/tmp" "$ACME_HOME" -type f ! -name account.conf | wc -l | tr -d ' ')
    [[ "$leftovers" == 0 ]] || fail "temporary files left behind"
}

test_missing_account_conf_fails_after_recheck() {
    setup_env
    make_csr a.example "clientAuth"
    if run_script y; then
        fail "missing account.conf should give a non-zero exit"
    fi
    assert_contains "$WORK/out" "account.conf not found"
    # The re-check still runs after the failure.
    assert_contains "$WORK/out" "All CSR configs are free of clientAuth entries."
}

ALL_TESTS=(
    test_removes_multiple_polluted_csrs
    test_appends_ext_key_use_when_missing
    test_declined_cleanup_keeps_files
    test_no_temp_file_left_when_already_set
    test_missing_account_conf_fails_after_recheck
)

if [[ "${1:-}" == "--run-one" ]]; then
    "$2"
    exit 0
fi

failures=0
for t in "${ALL_TESTS[@]}"; do
    if output=$("$TEST_BASH" "$SELF" --run-one "$t" 2>&1); then
        echo "ok - $t"
    else
        echo "not ok - $t"
        printf '%s\n' "$output" | sed 's/^/    /'
        failures=$((failures + 1))
    fi
done

if ((failures)); then
    echo "test_fix_acme_serverauth: $failures test(s) failed"
    exit 1
fi
echo "test_fix_acme_serverauth tests passed"
