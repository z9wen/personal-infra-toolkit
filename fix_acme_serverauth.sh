#!/usr/bin/env bash
#
# Diagnose and fix acme.sh CSR configs that request the clientAuth extended key
# usage, then pin Le_ExtKeyUse=serverAuth in account.conf.

set -euo pipefail

ACME_HOME="${ACME_HOME:-$HOME/.acme.sh}"
ACME_ENV_FILE="${ACME_ENV_FILE:-/etc/acme.sh.env}"
ACCOUNT_CONF="$ACME_HOME/account.conf"

# Filled by scan_polluted_confs.
polluted_confs=()

print_section() {
    echo
    echo "==============================="
    echo "$1"
    echo "==============================="
}

print_var() {
    local name="$1"
    local value="${!name-}"
    if [[ -n "$value" ]]; then
        printf '%s=%s\n' "$name" "$value"
    else
        printf '%s=<not set>\n' "$name"
    fi
}

print_file_vars() {
    local file="$1"
    shift
    if [[ ! -f "$file" ]]; then
        echo "$file not found."
        return 0
    fi
    local name line
    for name in "$@"; do
        line="$(grep -nE "^${name}=" "$file" || true)"
        if [[ -n "$line" ]]; then
            echo "$line"
        else
            echo "$name not set in $file"
        fi
    done
}

# Lists *.csr.conf files under ACME_HOME that mention clientAuth. Uses plain
# find + grep (not ripgrep, which honours .gitignore/.ignore files and could
# silently skip configs; not grep --include, which BusyBox lacks).
search_clientauth_csr_confs() {
    if [[ ! -d "$ACME_HOME" ]]; then
        return 0
    fi
    find "$ACME_HOME" -type f -name "*.csr.conf" -exec grep -l "clientAuth" {} + 2>/dev/null || true
}

# Refreshes the polluted_confs array from the current state of ACME_HOME.
scan_polluted_confs() {
    local line
    polluted_confs=()
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        polluted_confs+=("$line")
    done < <(search_clientauth_csr_confs)
}

remove_polluted_csrs() {
    if ((${#polluted_confs[@]} == 0)); then
        echo "No polluted CSR config files detected."
        return 0
    fi
    echo "The following CSR config files include clientAuth:"
    printf ' - %s\n' "${polluted_confs[@]}"
    local answer=""
    read -r -p "Remove these CSR configs and their CSR files now? [y/N]: " answer || true
    case "$answer" in
        [Yy] | [Yy][Ee][Ss]) ;;
        *)
            echo "Skipping CSR cleanup."
            return 0
            ;;
    esac
    local removed=0
    local conf csr
    for conf in "${polluted_confs[@]}"; do
        csr="${conf%.conf}"
        rm -f "$conf" "$csr"
        echo "Removed $conf and ${csr##*/}"
        # Not ((removed++)): that returns status 1 when removed is 0 and aborts
        # the script under set -e on bash >= 4.1.
        removed=$((removed + 1))
    done
    echo "Removed $removed polluted CSR config(s)."
}

ensure_serverauth_profile() {
    if [[ ! -f "$ACCOUNT_CONF" ]]; then
        echo "$ACCOUNT_CONF not found; cannot update Le_ExtKeyUse." >&2
        return 1
    fi
    if grep -q "^Le_ExtKeyUse='serverAuth'$" "$ACCOUNT_CONF"; then
        echo "Le_ExtKeyUse already set to serverAuth."
        return 0
    fi
    local tmp
    # Same directory as account.conf so the final mv is an atomic rename.
    tmp="$(mktemp "$ACCOUNT_CONF.XXXXXX")"
    if grep -q "^Le_ExtKeyUse=" "$ACCOUNT_CONF"; then
        sed "s|^Le_ExtKeyUse=.*|Le_ExtKeyUse='serverAuth'|" "$ACCOUNT_CONF" >"$tmp"
    else
        cat "$ACCOUNT_CONF" >"$tmp"
        echo "Le_ExtKeyUse='serverAuth'" >>"$tmp"
    fi
    if ! mv "$tmp" "$ACCOUNT_CONF"; then
        rm -f "$tmp"
        echo "Failed to update $ACCOUNT_CONF" >&2
        return 1
    fi
    echo "Le_ExtKeyUse set to serverAuth in $ACCOUNT_CONF"
}

main() {
    local status=0

    print_section "Environment variables"
    print_var OPENSSL_CONF
    print_var ACME_OPENSSL_CONF
    print_var LE_OPENSSL_CONF

    print_section "ACME env file ($ACME_ENV_FILE)"
    if [[ -f "$ACME_ENV_FILE" ]]; then
        grep -n -i 'openssl' "$ACME_ENV_FILE" || echo "No OPENSSL vars found."
    else
        echo "Env file not found."
    fi

    print_section "Account configuration ($ACCOUNT_CONF)"
    print_file_vars "$ACCOUNT_CONF" DEFAULT_ACME_SERVER Le_Profile Le_OpenSSLConf Le_CSR_Conf Le_ExtKeyUse

    print_section "Scanning for CSR configs containing clientAuth"
    scan_polluted_confs
    if ((${#polluted_confs[@]})); then
        printf '%s\n' "${polluted_confs[@]}"
    else
        echo "No clientAuth entries found in CSR configs."
    fi

    remove_polluted_csrs

    print_section "Ensuring Le_ExtKeyUse=serverAuth"
    ensure_serverauth_profile || status=1

    print_section "Re-checking CSR configs"
    scan_polluted_confs
    if ((${#polluted_confs[@]})); then
        echo "Still detected clientAuth in:"
        printf ' - %s\n' "${polluted_confs[@]}"
        echo "Please investigate remaining files manually."
    else
        echo "All CSR configs are free of clientAuth entries."
    fi

    return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
