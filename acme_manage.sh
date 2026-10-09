#!/usr/bin/env bash
#
# Interactive helper for managing acme.sh on Debian/Ubuntu hosts.
# Features:
#   - Install via the official upstream script with dependency checks.
#   - Reinstall/upgrade in place (certificates, keys and accounts are kept).
#   - Uninstall and remove the acme.sh home directory (typed confirmation).
#   - Switch the default ACME CA (Let's Encrypt, Google Trust Services, ZeroSSL, etc.).

set -euo pipefail

ACME_HOME="${ACME_HOME:-$HOME/.acme.sh}"
INSTALLER_URL="https://get.acme.sh"
DEFAULT_PROVIDER="letsencrypt"
ACME_ENV_FILE="${ACME_ENV_FILE:-/etc/acme-manager/credentials}"
APT_UPDATED=0

# Keep these lowercase: gts_server_kind compares them against lowercased input.
GTS_DIRECTORY_DEFAULT="https://dv.acme-v02.api.pki.goog/directory"
GTS_CLIENTAUTH_DIRECTORY="${GTS_DIRECTORY_DEFAULT}?client_auth=true"
GTS_MTLS_DIRECTORY="https://mtls.acme-v02.api.pki.goog/directory"
GTS_MTLS_CLIENTAUTH_DIRECTORY="${GTS_MTLS_DIRECTORY}?client_auth=true"

# Typed confirmation required before the acme.sh home directory is deleted.
UNINSTALL_CONFIRM_WORD="DELETE"

# Filled by prompt_certificate_targets.
SELECTED_DOMAINS=()
SELECTED_VARIANTS=()
SELECTED_VARIANT_LABEL=""

err() {
    echo "[ERROR] $*" >&2
}

info() {
    echo "[INFO] $*"
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        err "Please run this script as root."
        exit 1
    fi
}

# Portable lowercase (avoids the bash 4-only ${var,,} expansion).
to_lower() {
    printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

normalize_provider() {
    local raw="${1:-}"
    local lower
    lower="$(to_lower "$raw")"
    case "$lower" in
        "") echo "$DEFAULT_PROVIDER" ;;
        lets | letsencrypt) echo "letsencrypt" ;;
        gts | google | googletrust | googletrustservices) echo "google" ;;
        gts-clientauth | gts_clientauth | gtsclientauth | gts-client-auth | google-clientauth | google_clientauth | googleclientauth | google-client-auth) echo "google-clientauth" ;;
        zerossl | zero-ssl | zero) echo "zerossl" ;;
        buypass | bp) echo "buypass" ;;
        sslcom | sslcom-ca) echo "sslcom" ;;
        http*://*) echo "$raw" ;;
        *)
            # allow upstream supported keywords even if they are not listed above
            echo "$raw"
            ;;
    esac
}

provider_to_server_arg() {
    local provider="$1"
    case "$(to_lower "$provider")" in
        google)
            echo "google"
            ;;
        google-clientauth)
            echo "$GTS_CLIENTAUTH_DIRECTORY"
            ;;
        *)
            echo "$provider"
            ;;
    esac
}

# Prints the Google Trust Services directory kind (default, clientauth, mtls,
# mtls-clientauth) for a server keyword/URL, or returns 1 for non-Google values.
gts_server_kind() {
    local lower
    lower="$(to_lower "${1:-}")"
    case "$lower" in
        google | "$GTS_DIRECTORY_DEFAULT") echo "default" ;;
        "$GTS_CLIENTAUTH_DIRECTORY") echo "clientauth" ;;
        "$GTS_MTLS_DIRECTORY") echo "mtls" ;;
        "$GTS_MTLS_CLIENTAUTH_DIRECTORY") echo "mtls-clientauth" ;;
        *) return 1 ;;
    esac
}

is_google_server_value() {
    gts_server_kind "${1:-}" >/dev/null
}

format_ca_display() {
    local raw="${1:-}"
    if [[ -z "$raw" ]]; then
        echo ""
        return 0
    fi
    local kind=""
    kind="$(gts_server_kind "$raw")" || kind=""
    case "$kind" in
        default) echo "Google Trust Services" ;;
        clientauth) echo "Google Trust Services (clientAuth)" ;;
        mtls) echo "Google Trust Services (mTLS)" ;;
        mtls-clientauth) echo "Google Trust Services (mTLS clientAuth)" ;;
        *) echo "$raw" ;;
    esac
}

ensure_packages() {
    local missing=()
    local pkg
    for pkg in "$@"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            missing+=("$pkg")
        fi
    done

    if ((${#missing[@]})); then
        if [[ $APT_UPDATED -eq 0 ]]; then
            info "Updating apt package index..."
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq || return 1
            APT_UPDATED=1
        fi
        info "Installing dependencies: ${missing[*]}"
        apt-get install -y --no-install-recommends "${missing[@]}" || return 1
    fi
}

run_official_installer() {
    local email="$1"
    local install_cmd=(curl -fsSL "$INSTALLER_URL")

    if [[ -n "$email" ]]; then
        info "Running official installer (email: $email)"
        "${install_cmd[@]}" | sh -s email="$email"
    else
        info "Running official installer"
        "${install_cmd[@]}" | sh
    fi
}

set_default_ca() {
    local provider="$1"
    local server
    server="$(provider_to_server_arg "$provider")"
    if [[ -z "$server" ]]; then
        err "No ACME server specified."
        return 1
    fi
    ensure_acme_installed || return 1

    info "Setting default CA: $server"
    if ! "$ACME_HOME/acme.sh" --set-default-ca --server "$server"; then
        err "Failed to set the default CA to $server."
        return 1
    fi
}

# Refuse to rm -rf an empty, root or home-directory ACME_HOME.
is_safe_acme_home() {
    local home="${ACME_HOME%/}"
    local user_home="${HOME:-}"
    user_home="${user_home%/}"
    [[ -n "$home" && "$home" != "/" && "$home" != "$user_home" && "$home" != "/root" ]]
}

# Destructive: deletes ACME_HOME and everything in it. Only called from the
# explicit uninstall flow after a typed confirmation.
uninstall_acme() {
    if [[ ! -d "$ACME_HOME" ]]; then
        info "acme.sh is not installed; nothing to remove."
        return 0
    fi
    if ! is_safe_acme_home; then
        err "Refusing to delete suspicious ACME_HOME: '$ACME_HOME'"
        return 1
    fi

    if [[ -x "$ACME_HOME/acme.sh" ]]; then
        info "Running acme.sh --uninstall"
        "$ACME_HOME/acme.sh" --uninstall || true
    fi

    info "Removing $ACME_HOME"
    rm -rf "$ACME_HOME"
}

# Installs acme.sh, or with force=1 re-runs the official installer over the
# existing home. The installer upgrades the program files in place and leaves
# certificates, keys, account.conf and the ca/ directory untouched.
install_acme() {
    local email="$1"
    local provider="$2"
    local force="$3"

    if [[ -x "$ACME_HOME/acme.sh" ]]; then
        if [[ "$force" == "0" ]]; then
            info "acme.sh is already installed. Re-run installation only if you choose reinstall."
            return 0
        fi
        info "Reinstall requested; re-running the official installer in place over $ACME_HOME."
        info "Existing certificates, private keys, ACME accounts and saved credentials are kept."
    fi

    if ! ensure_packages curl socat cron; then
        err "Failed to install required packages (curl, socat, cron)."
        return 1
    fi
    if ! run_official_installer "$email"; then
        err "The official acme.sh installer failed."
        return 1
    fi
    set_default_ca "$provider" || return 1
    local server_arg server_label
    server_arg="$(provider_to_server_arg "$provider")"
    server_label="$(format_ca_display "$server_arg")"
    info "acme.sh installation finished. Default CA: ${server_label:-$server_arg}"
}

show_status() {
    if [[ -x "$ACME_HOME/acme.sh" ]]; then
        echo "acme.sh binary: $ACME_HOME/acme.sh"
        "$ACME_HOME/acme.sh" --version || err "Unable to query the acme.sh version."
        local current_ca
        current_ca="$(current_default_ca)"
        if [[ -n "$current_ca" ]]; then
            local ca_label
            ca_label="$(format_ca_display "$current_ca")"
            echo "Default CA: ${ca_label:-$current_ca}"
        else
            echo "Default CA: Unknown (use Set default ACME CA to fix it)"
        fi
    else
        echo "acme.sh is not installed."
    fi
    pause_for_menu
}

list_certificates() {
    if ! ensure_acme_installed; then
        pause_for_menu
        return 0
    fi

    echo "Existing certificates managed by acme.sh:"
    if ! "$ACME_HOME/acme.sh" --list; then
        err "Unable to list certificates via acme.sh."
    fi
    pause_for_menu
}

current_default_ca() {
    local account_ca
    account_ca="$(read_account_conf_var "DEFAULT_ACME_SERVER" || true)"
    if [[ -n "$account_ca" ]]; then
        echo "$account_ca"
        return 0
    fi

    if [[ -x "$ACME_HOME/acme.sh" ]]; then
        local output
        output="$("$ACME_HOME/acme.sh" --list-ca 2>/dev/null || true)"
        local ca
        ca="$(awk '/\*/ {print $2; exit}' <<<"$output")"
        if [[ -n "$ca" ]]; then
            echo "$ca"
            return 0
        fi
    fi
    return 0
}

pause_for_menu() {
    echo
    read -n1 -s -r -p "Press any key to return to the menu..." || true
    echo
}

ensure_acme_installed() {
    if [[ ! -x "$ACME_HOME/acme.sh" ]]; then
        err "acme.sh is not installed. Please install it first."
        return 1
    fi
}

load_env_file() {
    if [[ -f "$ACME_ENV_FILE" ]]; then
        unset CF_Email CF_Key CF_Token CF_Zone_ID CF_Account_ID CF_MODE
        set -a
        # shellcheck disable=SC1090
        source "$ACME_ENV_FILE"
        set +a
        info "Loaded environment variables from $ACME_ENV_FILE"
    fi
}

write_env_file() {
    local env_dir tmp
    env_dir="$(dirname "$ACME_ENV_FILE")"
    mkdir -p "$env_dir"
    # Create the temp file next to the target so the final mv is an atomic rename.
    tmp="$(mktemp "$env_dir/.credentials.XXXXXX")"
    {
        echo "# Generated by acme_manage.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        while [[ $# -gt 0 ]]; do
            local key="$1"
            local value="${2-}"
            shift 2
            printf "%s=%q\n" "$key" "$value"
        done
    } >"$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$ACME_ENV_FILE"
}

# Prints the value of KEY from account.conf with surrounding quotes removed.
# Everything after the first '=' is the value, so URLs containing '=' (such as
# the GTS ?client_auth=true directory) are preserved.
read_account_conf_var() {
    local key="$1"
    local file="$ACME_HOME/account.conf"
    [[ -f "$file" ]] || return 0
    awk -v key="$key" '
    index($0, key "=") == 1 {
      val = $0
      sub(/^[^=]*=/, "", val)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      if (val ~ /^'\''.*'\''$/) {
        sub(/^'\''/, "", val); sub(/'\''$/, "", val)
      } else if (val ~ /^".*"$/) {
        sub(/^"/, "", val); sub(/"$/, "", val)
      }
      print val
      exit
    }
  ' "$file"
}

ensure_cloudflare_ready() {
    if [[ -n "${CF_Key:-}" && -n "${CF_Email:-}" ]]; then
        return 0
    fi
    if [[ -n "${CF_Token:-}" && -n "${CF_Zone_ID:-}" && -n "${CF_Account_ID:-}" ]]; then
        return 0
    fi
    err "Cloudflare credentials are not configured. Use the Cloudflare setup option first."
    return 1
}

is_account_registered() {
    local server="$1"
    ensure_acme_installed || return 1

    local ca_dir="$ACME_HOME/ca"
    if [[ ! -d "$ca_dir" ]]; then
        return 1
    fi

    # For Google servers, match by hostname fragment
    if is_google_server_value "$server"; then
        if find "$ca_dir" -type d -name "*acme-v02.api.pki.goog*" 2>/dev/null | grep -q .; then
            return 0
        fi
        return 1
    fi

    # Map known short names to their CA hostnames (matching acme.sh's directory layout)
    local ca_host=""
    case "$(to_lower "$server")" in
        letsencrypt | lets)
            ca_host="acme-v02.api.letsencrypt.org"
            ;;
        zerossl | zero-ssl | zero)
            ca_host="acme.zerossl.com"
            ;;
        buypass | bp)
            ca_host="api.buypass.com"
            ;;
        sslcom | sslcom-ca)
            ca_host="acme.ssl.com"
            ;;
        http*://*)
            # Strip scheme, strip query string, keep host+path
            ca_host="${server#*://}"
            ca_host="${ca_host%%\?*}"
            ;;
        *)
            ca_host="$server"
            ;;
    esac

    if [[ -n "$ca_host" ]] && find "$ca_dir" -type d -path "*${ca_host}*" 2>/dev/null | grep -q .; then
        return 0
    fi

    return 1
}

register_google_account() {
    ensure_acme_installed || return 1
    local server_arg="${1:-google}"
    local server_label
    server_label="$(format_ca_display "$server_arg")"
    [[ -n "$server_label" ]] || server_label="$server_arg"
    local g_email g_kid g_hmac
    info "Registering Google ACME account against $server_label"
    read -rp "Google ACME email: " g_email
    read -rp "Google ACME key ID (kid): " g_kid
    read -rp "Google ACME HMAC key: " g_hmac
    if [[ -z "$g_email" || -z "$g_kid" || -z "$g_hmac" ]]; then
        err "Email, key ID, and HMAC key are all required."
        return 1
    fi
    if "$ACME_HOME/acme.sh" --register-account -m "$g_email" --server "$server_arg" --eab-kid "$g_kid" --eab-hmac-key "$g_hmac"; then
        info "Google ACME account registered successfully."
        return 0
    else
        err "Failed to register Google ACME account with the provided credentials."
        return 1
    fi
}

prompt_provider() {
    cat <<'EOF' >&2
Choose the default ACME CA:
  1) Let's Encrypt (letsencrypt)
  2) Google Trust Services (serverAuth)
  3) Google Trust Services (clientAuth)
  4) ZeroSSL (zerossl)
  5) Buypass (buypass)
  6) Custom (enter any acme.sh supported server keyword or URL)
EOF
    local choice server
    read -rp "Provider selection [1]: " choice
    case "${choice:-1}" in
        1) server="letsencrypt" ;;
        2) server="google" ;;
        3) server="google-clientauth" ;;
        4) server="zerossl" ;;
        5) server="buypass" ;;
        6)
            read -rp "Enter custom server keyword or URL: " server
            ;;
        *)
            echo "Unknown selection; defaulting to Let's Encrypt." >&2
            server="letsencrypt"
            ;;
    esac
    normalize_provider "$server"
}

# Usage: prompt_certificate_key_type [rsa|ecc|both]
# The argument is the default used for an empty or unknown answer.
prompt_certificate_key_type() {
    local default_type="${1:-ecc}"
    local default_choice
    case "$default_type" in
        rsa) default_choice=1 ;;
        both) default_choice=3 ;;
        *)
            default_type="ecc"
            default_choice=2
            ;;
    esac
    cat <<'EOF' >&2
Select certificate key type(s):
  1) RSA
  2) ECC
  3) Both RSA and ECC
EOF
    local choice
    read -rp "Key type selection [$default_choice]: " choice
    case "${choice:-$default_choice}" in
        1) echo "rsa" ;;
        2) echo "ecc" ;;
        3) echo "both" ;;
        *)
            echo "Unknown selection; using the default ($default_type)." >&2
            echo "$default_type"
            ;;
    esac
}

certificate_conf_path() {
    local domain="$1"
    local variant="$2"
    local base_dir
    base_dir="$(certificate_storage_dir "$domain" "$variant")"
    echo "$base_dir/$domain.conf"
}

# acme.sh stores RSA certificates in $ACME_HOME/<domain> and ECC certificates
# (the acme.sh default since v3) in $ACME_HOME/<domain>_ecc.
certificate_storage_dir() {
    local domain="$1"
    local variant="$2"
    if [[ "$variant" == "ecc" ]]; then
        echo "$ACME_HOME/${domain}_ecc"
    else
        echo "$ACME_HOME/$domain"
    fi
}

variant_label() {
    if [[ "$1" == "ecc" ]]; then
        echo "ECC"
    else
        echo "RSA"
    fi
}

# Directory holding the most recently written certificate for DOMAIN.
latest_certificate_dir() {
    local domain="$1"
    local ecc_conf rsa_conf
    ecc_conf="$(certificate_conf_path "$domain" ecc)"
    rsa_conf="$(certificate_conf_path "$domain" rsa)"
    if [[ -f "$ecc_conf" && (! -f "$rsa_conf" || "$ecc_conf" -nt "$rsa_conf") ]]; then
        certificate_storage_dir "$domain" ecc
    elif [[ -f "$rsa_conf" ]]; then
        certificate_storage_dir "$domain" rsa
    else
        echo "$ACME_HOME"
    fi
}

# Usage: certificate_variant_exists DOMAIN rsa|ecc [ACME_LIST_OUTPUT]
# Checks the on-disk conf first, then the `acme.sh --list` output whose
# KeyLength column is e.g. "ec-256" for ECC and "2048" (or empty) for RSA.
certificate_variant_exists() {
    local domain="$1"
    local variant="$2"
    local cached_list="${3:-}"
    local conf_file
    conf_file="$(certificate_conf_path "$domain" "$variant")"
    if [[ -f "$conf_file" ]]; then
        return 0
    fi
    if [[ -z "$cached_list" ]]; then
        return 1
    fi
    awk -v dom="$domain" -v want="$variant" '
    BEGIN {found=0}
    NR == 1 {next}
    $1 == dom {
      key = $2
      gsub(/"/, "", key)
      kind = (key ~ /^ec-/ || key == "ECC") ? "ecc" : "rsa"
      if (kind == want) {found=1; exit}
    }
    END {exit (found ? 0 : 1)}
  ' <<<"$cached_list"
}

# Prints rsa, ecc or both depending on which variants exist for the domains.
# Falls back to ecc, the acme.sh default key type.
default_key_type_for_domains() {
    local list_output="$1"
    shift
    local has_rsa=0 has_ecc=0 domain
    for domain in "$@"; do
        if certificate_variant_exists "$domain" rsa "$list_output"; then
            has_rsa=1
        fi
        if certificate_variant_exists "$domain" ecc "$list_output"; then
            has_ecc=1
        fi
    done
    if ((has_rsa && has_ecc)); then
        echo "both"
    elif ((has_rsa)); then
        echo "rsa"
    else
        echo "ecc"
    fi
}

# Prints the `acme.sh --list` output (errors are reported, not fatal).
fetch_certificate_list() {
    local output=""
    if ! output="$("$ACME_HOME/acme.sh" --list 2>&1)"; then
        err "Unable to list certificates via acme.sh (continuing anyway)."
    fi
    printf '%s' "$output"
}

# Usage: prompt_certificate_targets ACTION ACME_LIST_OUTPUT
# Asks for domains and key type(s); sets SELECTED_DOMAINS, SELECTED_VARIANTS
# and SELECTED_VARIANT_LABEL. Returns 1 when no usable domain was entered.
prompt_certificate_targets() {
    local action="$1"
    local list_output="${2:-}"
    local domain_input domain
    local -a domain_array=()
    SELECTED_DOMAINS=()
    SELECTED_VARIANTS=()
    SELECTED_VARIANT_LABEL=""

    read -rp "Enter the primary domain(s) to $action (space-separated): " domain_input
    read -ra domain_array <<<"$domain_input" || true
    if ((${#domain_array[@]})); then
        for domain in "${domain_array[@]}"; do
            domain="$(to_lower "$domain")"
            # Domains become path components under ACME_HOME; reject anything else.
            if [[ ! "$domain" =~ ^[a-z0-9*_-][a-z0-9*._-]*$ ]]; then
                err "Ignoring invalid domain: $domain"
                continue
            fi
            SELECTED_DOMAINS+=("$domain")
        done
    fi

    if ((${#SELECTED_DOMAINS[@]} == 0)); then
        err "At least one domain must be provided."
        return 1
    fi

    local default_type key_choice
    default_type="$(default_key_type_for_domains "$list_output" "${SELECTED_DOMAINS[@]}")"
    key_choice="$(prompt_certificate_key_type "$default_type")"
    case "$key_choice" in
        ecc)
            SELECTED_VARIANTS=(ecc)
            SELECTED_VARIANT_LABEL="ECC"
            ;;
        both)
            SELECTED_VARIANTS=(rsa ecc)
            SELECTED_VARIANT_LABEL="RSA and ECC"
            ;;
        *)
            SELECTED_VARIANTS=(rsa)
            SELECTED_VARIANT_LABEL="RSA"
            ;;
    esac
}

confirm() {
    local prompt="${1:-Are you sure?}"
    local answer=""
    read -rp "$prompt [y/N]: " answer || return 1
    case "$answer" in
        [Yy] | [Yy][Ee][Ss]) return 0 ;;
        *) return 1 ;;
    esac
}

run_acme_issue_command() {
    local label="${1:-The domain}"
    shift
    local tmp
    tmp="$(mktemp)"
    local base_cmd=("$@")

    if "${base_cmd[@]}" 2>&1 | tee "$tmp"; then
        rm -f "$tmp"
        return 0
    fi

    if grep -qi "domain key exists" "$tmp"; then
        if confirm "$label already has an existing domain key. Force reissue"; then
            local force_cmd=("${base_cmd[@]}" --force)
            if "${force_cmd[@]}" 2>&1 | tee "$tmp"; then
                rm -f "$tmp"
                return 0
            fi
        else
            info "Force reissue skipped by user."
            rm -f "$tmp"
            return 2
        fi
    fi

    rm -f "$tmp"
    return 1
}

install_flow() {
    local email provider force=0
    read -rp "Registration email (optional, leave blank to skip): " email
    provider="$(prompt_provider)"
    local server_arg
    server_arg="$(provider_to_server_arg "$provider")"

    if [[ -x "$ACME_HOME/acme.sh" ]]; then
        if confirm "acme.sh is already installed. Reinstall/upgrade in place (certificates and accounts are kept)"; then
            force=1
        else
            echo "Skipping installation."
            return 0
        fi
    fi

    install_acme "$email" "$provider" "$force" || return 0
    if is_google_server_value "$server_arg"; then
        if ! is_account_registered "$server_arg"; then
            register_google_account "$server_arg" || true
        else
            info "Google ACME account is already registered."
        fi
    fi
}

uninstall_flow() {
    if [[ ! -d "$ACME_HOME" ]]; then
        info "acme.sh is not installed; nothing to remove."
        return 0
    fi

    cat >&2 <<EOF
WARNING: Uninstalling permanently deletes $ACME_HOME, including:
  - every issued certificate and its private key
  - ACME account keys and CA registrations
  - saved DNS API credentials and renewal configuration
This cannot be undone. Back it up first if you may need it, for example:
  tar -czf /root/acme.sh-backup.tar.gz -C "$(dirname "$ACME_HOME")" "$(basename "$ACME_HOME")"
To upgrade or repair acme.sh instead, use "Install or reinstall acme.sh"; it keeps all data.
EOF
    local answer=""
    read -rp "Type $UNINSTALL_CONFIRM_WORD to permanently remove $ACME_HOME: " answer || true
    if [[ "$answer" != "$UNINSTALL_CONFIRM_WORD" ]]; then
        echo "Uninstall canceled."
        return 0
    fi
    uninstall_acme || true
}

set_ca_flow() {
    local provider
    provider="$(prompt_provider)"
    local server_arg
    server_arg="$(provider_to_server_arg "$provider")"
    set_default_ca "$provider" || return 0
    if is_google_server_value "$server_arg"; then
        if ! is_account_registered "$server_arg"; then
            register_google_account "$server_arg" || true
        else
            info "Google ACME account is already registered."
            if confirm "Re-register Google ACME account with new credentials"; then
                register_google_account "$server_arg" || true
            fi
        fi
    fi
}

configure_cloudflare_env() {
    cat <<'EOF' >&2
Configure Cloudflare DNS API credentials.
  1) Global API key (email + API key)
  2) Scoped API token (token + zone/account IDs)
EOF
    local choice
    read -rp "Cloudflare credential selection [1]: " choice
    case "${choice:-1}" in
        1)
            local cf_email cf_key
            read -rp "Cloudflare email: " cf_email
            read -rsp "Global API key: " cf_key
            echo
            write_env_file \
                "CF_MODE" "global" \
                "CF_Email" "$cf_email" \
                "CF_Key" "$cf_key" \
                "CF_Token" "" \
                "CF_Zone_ID" "" \
                "CF_Account_ID" ""
            ;;
        2)
            local cf_token cf_zone cf_account
            read -rp "Scoped API token: " cf_token
            read -rp "Zone ID: " cf_zone
            read -rp "Account (user) ID: " cf_account
            write_env_file \
                "CF_MODE" "token" \
                "CF_Email" "" \
                "CF_Key" "" \
                "CF_Token" "$cf_token" \
                "CF_Zone_ID" "$cf_zone" \
                "CF_Account_ID" "$cf_account"
            ;;
        *)
            echo "Unknown selection. Canceling."
            return 0
            ;;
    esac

    info "Cloudflare credentials saved to $ACME_ENV_FILE"
    load_env_file
}

issue_single_domain_certificate() {
    ensure_acme_installed || return 0
    local domain method mode
    read -rp "Enter the domain (example.com): " domain
    if [[ -z "$domain" ]]; then
        err "Domain is required."
        return 0
    fi

    cat <<'EOF' >&2
Validation method:
  1) Standalone (requires this host to listen on TCP 80 temporarily)
  2) Cloudflare DNS (requires configured API credentials)
EOF
    read -rp "Validation selection [1]: " method
    case "${method:-1}" in
        1)
            mode="standalone"
            ;;
        2)
            if ! ensure_cloudflare_ready; then
                return 0
            fi
            mode="dns_cf"
            ;;
        *)
            echo "Unknown selection. Canceling."
            return 0
            ;;
    esac

    local cmd=("$ACME_HOME/acme.sh" --issue -d "$domain")
    if [[ "$mode" == "standalone" ]]; then
        cmd+=(--standalone)
    else
        cmd+=(--dns dns_cf)
    fi

    local issue_rc=0
    run_acme_issue_command "$domain" "${cmd[@]}" || issue_rc=$?
    if [[ $issue_rc -eq 1 ]]; then
        err "Certificate issuance failed."
        return 0
    elif [[ $issue_rc -ne 0 ]]; then
        return 0
    fi

    info "Certificate issued. Files are available under $(latest_certificate_dir "$domain")"
}

issue_wildcard_certificate() {
    ensure_acme_installed || return 0
    if ! ensure_cloudflare_ready; then
        return 0
    fi

    local domain
    read -rp "Enter the base domain (example.com): " domain
    if [[ -z "$domain" ]]; then
        err "Domain is required."
        return 0
    fi

    local ca
    ca="$(current_default_ca)"
    if is_google_server_value "$ca"; then
        if ! is_account_registered "$ca"; then
            local ca_label
            ca_label="$(format_ca_display "$ca")"
            echo "${ca_label:-Google Trust Services} requires Google ACME External Account Binding for wildcard orders."
            if ! register_google_account "$ca"; then
                return 0
            fi
        else
            info "Using existing Google ACME account registration."
        fi
    fi

    local cmd=("$ACME_HOME/acme.sh" --issue -d "$domain" -d "*.$domain" --dns dns_cf)
    local issue_rc=0
    run_acme_issue_command "$domain" "${cmd[@]}" || issue_rc=$?
    if [[ $issue_rc -eq 1 ]]; then
        err "Wildcard certificate issuance failed."
        return 0
    elif [[ $issue_rc -ne 0 ]]; then
        return 0
    fi

    info "Wildcard certificate issued. Files are available under $(latest_certificate_dir "$domain")"
}

remove_certificates_flow() {
    ensure_acme_installed || return 0

    echo "Existing certificates managed by acme.sh:"
    local list_output
    list_output="$(fetch_certificate_list)"
    [[ -z "$list_output" ]] || echo "$list_output"

    prompt_certificate_targets "remove" "$list_output" || return 0

    echo "Selected domain(s): ${SELECTED_DOMAINS[*]}"
    if ! confirm "Remove $SELECTED_VARIANT_LABEL certificate(s) for the selected domain(s)"; then
        echo "Deletion canceled."
        return 0
    fi

    local failures=0
    local cleanup_targets=()
    local domain variant human_label
    for domain in "${SELECTED_DOMAINS[@]}"; do
        for variant in "${SELECTED_VARIANTS[@]}"; do
            human_label="$(variant_label "$variant")"
            if ! certificate_variant_exists "$domain" "$variant" "$list_output"; then
                info "No $human_label certificate found for $domain; skipping."
                continue
            fi
            cleanup_targets+=("$domain:$variant")
            local cmd=("$ACME_HOME/acme.sh" --remove -d "$domain")
            if [[ "$variant" == "ecc" ]]; then
                cmd+=(--ecc)
            fi
            info "Removing $human_label certificate for $domain"
            local cmd_output=""
            if ! cmd_output="$("${cmd[@]}" 2>&1)"; then
                echo "$cmd_output"
                if grep -qi "already been removed" <<<"$cmd_output"; then
                    info "$human_label certificate for $domain was already removed."
                else
                    err "Failed to remove $human_label certificate for $domain"
                    failures=$((failures + 1))
                fi
            else
                echo "$cmd_output"
                info "$human_label certificate for $domain removed."
            fi
        done
    done

    if ((${#cleanup_targets[@]})); then
        if confirm "Also delete the local acme.sh directory (removes CSR/key) for these domain(s)"; then
            local target target_domain target_variant dir
            for target in "${cleanup_targets[@]}"; do
                IFS=":" read -r target_domain target_variant <<<"$target"
                dir="$(certificate_storage_dir "$target_domain" "$target_variant")"
                if [[ -d "$dir" ]]; then
                    rm -rf "$dir"
                    info "Removed local directory: $dir"
                else
                    info "Directory already absent: $dir"
                fi
            done
        fi
    fi

    if ((failures > 0)); then
        err "$failures removal operation(s) failed. Review the log above for details."
    else
        info "Requested certificate(s) removed successfully."
    fi
}

renew_certificates_flow() {
    ensure_acme_installed || return 0

    echo "Existing certificates managed by acme.sh:"
    local list_output
    list_output="$(fetch_certificate_list)"
    [[ -z "$list_output" ]] || echo "$list_output"

    cat <<'EOF' >&2

Renewal options:
  1) Renew all certificates
  2) Renew specific certificate(s)
EOF
    local choice
    read -rp "Renewal selection [1]: " choice
    case "${choice:-1}" in
        1)
            if confirm "Renew all certificates"; then
                info "Renewing all certificates..."
                if "$ACME_HOME/acme.sh" --renew-all; then
                    info "All certificates renewed successfully."
                else
                    err "Some certificates may have failed to renew. Check the output above."
                fi
            else
                echo "Renewal canceled."
            fi
            ;;
        2)
            prompt_certificate_targets "renew" "$list_output" || return 0

            echo "Selected domain(s): ${SELECTED_DOMAINS[*]}"
            if ! confirm "Renew the selected certificate(s)"; then
                echo "Renewal canceled."
                return 0
            fi

            local failures=0
            local domain variant human_label
            for domain in "${SELECTED_DOMAINS[@]}"; do
                for variant in "${SELECTED_VARIANTS[@]}"; do
                    human_label="$(variant_label "$variant")"
                    if ! certificate_variant_exists "$domain" "$variant" "$list_output"; then
                        info "No $human_label certificate found for $domain; skipping."
                        continue
                    fi
                    local cmd=("$ACME_HOME/acme.sh" --renew -d "$domain")
                    if [[ "$variant" == "ecc" ]]; then
                        cmd+=(--ecc)
                    fi
                    info "Renewing $human_label certificate for $domain"
                    if ! "${cmd[@]}"; then
                        err "Failed to renew $human_label certificate for $domain"
                        failures=$((failures + 1))
                    else
                        info "$human_label certificate for $domain renewed successfully."
                    fi
                done
            done

            if ((failures > 0)); then
                err "$failures renewal operation(s) failed. Review the log above for details."
            else
                info "Requested certificate(s) renewed successfully."
            fi
            ;;
        *)
            echo "Unknown selection. Canceling."
            ;;
    esac
}

main_menu() {
    cat <<'EOF'
-------------------------------
 ACME.sh Management Assistant
-------------------------------
 1) Issue single-domain certificate
 2) Issue wildcard certificate
 3) Set default ACME CA
 4) Configure Cloudflare DNS credentials
 5) Show status
 6) List existing certificates
 7) Install or reinstall acme.sh
 8) Uninstall acme.sh
 9) Remove certificate(s)
10) Renew certificate(s)
11) Exit
EOF
}

# Menu actions report their own errors and return 0 so that, under set -e,
# a failed action returns to the menu instead of terminating the script.
main() {
    while true; do
        main_menu
        local choice
        read -rp "Choose an option [1-11]: " choice
        case "$choice" in
            1)
                issue_single_domain_certificate
                ;;
            "")
                echo "Please enter a valid option [1-11]."
                ;;
            2)
                issue_wildcard_certificate
                ;;
            3)
                set_ca_flow
                ;;
            4)
                configure_cloudflare_env
                ;;
            5)
                show_status
                ;;
            6)
                list_certificates
                ;;
            7)
                install_flow
                ;;
            8)
                uninstall_flow
                ;;
            9)
                remove_certificates_flow
                ;;
            10)
                renew_certificates_flow
                ;;
            11)
                echo "Bye."
                return
                ;;
            *)
                echo "Unknown option."
                ;;
        esac
        echo
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    require_root
    load_env_file
    main
fi
