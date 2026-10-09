#!/usr/bin/env bash
# Offline tests for acme_manage.sh. Uses stub commands and temp directories
# only; never runs the real acme.sh, apt-get or curl.
#
# Each test runs in a fresh bash process (so the script's set -e is live) via
# "$0 --run-one <test>". Works with bash 3.2 and bash 5.

set -u

SELF="$0"
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="${REPO_ROOT}/acme_manage.sh"
TEST_BASH=${BASH:-bash}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    [[ "$1" == "$2" ]] || fail "${3:-values differ}: expected '$2', got '$1'"
}

assert_file() {
    [[ -f "$1" ]] || fail "expected file to exist: $1"
}

assert_contains() {
    grep -qF -- "$2" "$1" || {
        echo "--- $1 ---" >&2
        cat "$1" >&2
        fail "expected '$2' in $1"
    }
}

# Builds a fake ACME_HOME with certificates, keys, accounts and a stub acme.sh,
# plus stub curl/dpkg/apt-get on PATH.
setup_env() {
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/test_acme_manage.XXXXXX")
    trap 'rm -rf "$WORK"' EXIT
    export STUB_LOG="$WORK/calls.log"
    : >"$STUB_LOG"
    mkdir -p "$WORK/bin"

    cat >"$WORK/bin/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >>"$STUB_LOG"
# Emit a fake installer; the caller pipes it into sh.
echo 'echo "installer-ran $*" >>"$STUB_LOG"'
EOF
    cat >"$WORK/bin/dpkg" <<'EOF'
#!/bin/sh
exit 0
EOF
    cat >"$WORK/bin/apt-get" <<'EOF'
#!/bin/sh
echo "apt-get $*" >>"$STUB_LOG"
exit 1
EOF
    chmod +x "$WORK/bin/"*
    export PATH="$WORK/bin:$PATH"

    export ACME_HOME="$WORK/acme home"
    export ACME_ENV_FILE="$WORK/env/credentials"
    mkdir -p "$ACME_HOME/example.com_ecc" "$ACME_HOME/ca/acme-v02.api.letsencrypt.org/directory"
    echo "CERT" >"$ACME_HOME/example.com_ecc/example.com.cer"
    echo "KEY" >"$ACME_HOME/example.com_ecc/example.com.key"
    echo "Le_Domain='example.com'" >"$ACME_HOME/example.com_ecc/example.com.conf"
    echo "ACCOUNT" >"$ACME_HOME/ca/acme-v02.api.letsencrypt.org/directory/account.key"
    printf "%s\n" "SAVED_CF_Token='secret'" "DEFAULT_ACME_SERVER='https://acme-v02.api.letsencrypt.org/directory'" >"$ACME_HOME/account.conf"
    cat >"$ACME_HOME/acme.sh" <<'EOF'
#!/bin/sh
echo "acme.sh $*" >>"$STUB_LOG"
exit 0
EOF
    chmod +x "$ACME_HOME/acme.sh"

    # shellcheck source=../acme_manage.sh
    source "$SCRIPT"
}

test_reinstall_keeps_acme_home() {
    setup_env
    # email: blank, provider: 1 (Let's Encrypt), reinstall: y
    install_flow >"$WORK/out" 2>&1 <<'EOF'

1
y
EOF
    assert_file "$ACME_HOME/example.com_ecc/example.com.cer"
    assert_file "$ACME_HOME/example.com_ecc/example.com.key"
    assert_file "$ACME_HOME/ca/acme-v02.api.letsencrypt.org/directory/account.key"
    assert_contains "$ACME_HOME/account.conf" "SAVED_CF_Token='secret'"
    assert_contains "$STUB_LOG" "installer-ran"
    assert_contains "$STUB_LOG" "acme.sh --set-default-ca --server letsencrypt"
    if grep -q -- "--uninstall" "$STUB_LOG"; then
        fail "reinstall must not run acme.sh --uninstall"
    fi
    assert_contains "$WORK/out" "acme.sh installation finished"
}

test_reinstall_passes_email_to_installer() {
    setup_env
    install_acme "ops@example.com" letsencrypt 1 >"$WORK/out" 2>&1
    assert_contains "$STUB_LOG" "installer-ran email=ops@example.com"
    assert_file "$ACME_HOME/example.com_ecc/example.com.key"
}

test_installer_failure_is_reported() {
    setup_env
    printf '#!/bin/sh\nexit 22\n' >"$WORK/bin/curl"
    if install_acme "" letsencrypt 1 >"$WORK/out" 2>&1; then
        fail "install_acme should fail when the installer fails"
    fi
    assert_contains "$WORK/out" "official acme.sh installer failed"
    if grep -q "installation finished" "$WORK/out"; then
        fail "success must not be printed after a failed install"
    fi
}

test_uninstall_requires_typed_confirmation() {
    setup_env
    printf 'y\n' | uninstall_flow >"$WORK/out" 2>&1
    [[ -d "$ACME_HOME" ]] || fail "'y' must not be accepted as uninstall confirmation"
    assert_contains "$WORK/out" "Uninstall canceled."
    assert_contains "$WORK/out" "permanently deletes"

    printf 'DELETE\n' | uninstall_flow >"$WORK/out" 2>&1
    [[ ! -e "$ACME_HOME" ]] || fail "ACME_HOME should be removed after typing DELETE"
    assert_contains "$STUB_LOG" "acme.sh --uninstall"
}

test_safe_acme_home_guard() {
    setup_env
    local ACME_HOME
    for ACME_HOME in "" "/" "$HOME" "$HOME/" "/root"; do
        if is_safe_acme_home; then
            fail "ACME_HOME='$ACME_HOME' must be refused"
        fi
    done
    ACME_HOME="$WORK/acme home"
    is_safe_acme_home || fail "a normal ACME_HOME must be accepted"
}

test_ca_value_with_equals_is_preserved() {
    setup_env
    local gts_client="https://dv.acme-v02.api.pki.goog/directory?client_auth=true"
    printf "%s\n" "Le_Other=1" "DEFAULT_ACME_SERVER='${gts_client}'" >"$ACME_HOME/account.conf"
    assert_eq "$(read_account_conf_var DEFAULT_ACME_SERVER)" "$gts_client" "single-quoted value"
    assert_eq "$(current_default_ca)" "$gts_client" "current_default_ca"
    assert_eq "$(format_ca_display "$(current_default_ca)")" "Google Trust Services (clientAuth)" "display label"

    printf "%s\n" "DEFAULT_ACME_SERVER=\"https://ca.example/dir?a=1&b=2\"" >"$ACME_HOME/account.conf"
    assert_eq "$(read_account_conf_var DEFAULT_ACME_SERVER)" "https://ca.example/dir?a=1&b=2" "double-quoted value"

    printf "%s\n" "DEFAULT_ACME_SERVER=https://ca.example/dir?x=y" >"$ACME_HOME/account.conf"
    assert_eq "$(read_account_conf_var DEFAULT_ACME_SERVER)" "https://ca.example/dir?x=y" "unquoted value"
    assert_eq "$(read_account_conf_var MISSING_KEY)" "" "missing key"
}

test_gts_classification() {
    setup_env
    is_google_server_value google || fail "google keyword"
    is_google_server_value "HTTPS://DV.ACME-V02.API.PKI.GOOG/DIRECTORY" || fail "uppercase GTS URL"
    if is_google_server_value letsencrypt; then fail "letsencrypt is not GTS"; fi
    if is_google_server_value ""; then fail "empty is not GTS"; fi
    assert_eq "$(format_ca_display "$GTS_MTLS_CLIENTAUTH_DIRECTORY")" "Google Trust Services (mTLS clientAuth)" "mtls clientauth"
    assert_eq "$(format_ca_display "$GTS_MTLS_DIRECTORY")" "Google Trust Services (mTLS)" "mtls"
    assert_eq "$(format_ca_display letsencrypt)" "letsencrypt" "non-GTS passthrough"
    assert_eq "$(normalize_provider GTS)" "google" "normalize GTS"
    assert_eq "$(provider_to_server_arg google-clientauth)" "$GTS_CLIENTAUTH_DIRECTORY" "clientauth server arg"
}

test_variant_detection_prefers_existing() {
    setup_env
    assert_eq "$(latest_certificate_dir example.com)" "$ACME_HOME/example.com_ecc" "ecc-only dir"
    assert_eq "$(default_key_type_for_domains "" example.com)" "ecc" "ecc-only default"

    mkdir -p "$ACME_HOME/rsa.example"
    echo "Le_Domain='rsa.example'" >"$ACME_HOME/rsa.example/rsa.example.conf"
    assert_eq "$(latest_certificate_dir rsa.example)" "$ACME_HOME/rsa.example" "rsa-only dir"
    assert_eq "$(default_key_type_for_domains "" rsa.example)" "rsa" "rsa-only default"
    assert_eq "$(default_key_type_for_domains "" rsa.example example.com)" "both" "mixed default"

    local list
    list=$(printf '%s\n' 'Main_Domain KeyLength SAN_Domains CA Created Renew' \
        'listed.example "ec-256" no LetsEncrypt.org 2026 2026' \
        'listed-rsa.example "2048" no LetsEncrypt.org 2026 2026')
    certificate_variant_exists listed.example ecc "$list" || fail "ec-256 list entry should be ECC"
    if certificate_variant_exists listed.example rsa "$list"; then fail "ec-256 entry is not RSA"; fi
    certificate_variant_exists listed-rsa.example rsa "$list" || fail "2048 list entry should be RSA"

    # Empty answer takes the detected default instead of RSA.
    assert_eq "$(prompt_certificate_key_type ecc 2>/dev/null </dev/null)" "ecc" "empty answer uses default"
    assert_eq "$(echo 1 | prompt_certificate_key_type ecc 2>/dev/null)" "rsa" "explicit RSA"
}

test_prompt_certificate_targets() {
    setup_env
    printf 'Example.COM ../evil\n\n' >"$WORK/in"
    prompt_certificate_targets remove "" <"$WORK/in" >"$WORK/out" 2>&1 || fail "targets prompt failed"
    assert_eq "${SELECTED_DOMAINS[*]}" "example.com" "domains"
    assert_eq "${SELECTED_VARIANTS[*]}" "ecc" "variants default to existing ECC"
    assert_eq "$SELECTED_VARIANT_LABEL" "ECC" "variant label"
    assert_contains "$WORK/out" "Ignoring invalid domain: ../evil"

    if prompt_certificate_targets renew "" </dev/null >/dev/null 2>&1; then
        fail "empty domain input must be rejected"
    fi
}

test_menu_survives_missing_acme() {
    setup_env
    rm -f "$ACME_HOME/acme.sh"
    # 1 = issue certificate (fails: not installed), 11 = exit
    # Run main outside any conditional so set -e is live: an action returning
    # non-zero would terminate the script before "Bye.".
    printf '1\n9\n10\n11\n' >"$WORK/in"
    main <"$WORK/in" >"$WORK/out" 2>&1
    assert_contains "$WORK/out" "acme.sh is not installed"
    assert_contains "$WORK/out" "Bye."
}

ALL_TESTS=(
    test_reinstall_keeps_acme_home
    test_reinstall_passes_email_to_installer
    test_installer_failure_is_reported
    test_uninstall_requires_typed_confirmation
    test_safe_acme_home_guard
    test_ca_value_with_equals_is_preserved
    test_gts_classification
    test_variant_detection_prefers_existing
    test_prompt_certificate_targets
    test_menu_survives_missing_acme
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
    echo "test_acme_manage: $failures test(s) failed"
    exit 1
fi
echo "test_acme_manage tests passed"
