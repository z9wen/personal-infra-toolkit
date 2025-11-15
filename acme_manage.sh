#!/usr/bin/env bash
#
# Interactive helper for managing acme.sh on Debian/Ubuntu hosts.
# Features:
#   - Install via the official upstream script with dependency checks.
#   - Uninstall and remove the acme.sh home directory.
#   - Switch the default ACME CA (Let's Encrypt, Google Trust Services, ZeroSSL, etc.).

set -euo pipefail

ACME_HOME="${ACME_HOME:-$HOME/.acme.sh}"
INSTALLER_URL="https://get.acme.sh"
DEFAULT_PROVIDER="letsencrypt"
ACME_ENV_FILE="${ACME_ENV_FILE:-/etc/acme.sh.env}"
APT_UPDATED=0

GTS_DIRECTORY_DEFAULT="https://dv.acme-v02.api.pki.goog/directory"
GTS_CLIENTAUTH_DIRECTORY="${GTS_DIRECTORY_DEFAULT}?client_auth=true"
GTS_MTLS_DIRECTORY="https://mtls.acme-v02.api.pki.goog/directory"
GTS_MTLS_CLIENTAUTH_DIRECTORY="${GTS_MTLS_DIRECTORY}?client_auth=true"

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

normalize_provider() {
  local raw="${1:-}"
  local lower="${raw,,}"
  case "$lower" in
    "" ) echo "$DEFAULT_PROVIDER" ;;
    lets|letsencrypt ) echo "letsencrypt" ;;
    gts|google|googletrust|googletrustservices ) echo "google" ;;
    gts-clientauth|gts_clientauth|gtsclientauth|gts-client-auth|google-clientauth|google_clientauth|googleclientauth|google-client-auth ) echo "google-clientauth" ;;
    zerossl|zero-ssl|zero ) echo "zerossl" ;;
    buypass|bp ) echo "buypass" ;;
    sslcom|sslcom-ca ) echo "sslcom" ;;
    http*://* ) echo "$raw" ;;
    * )
      # allow upstream supported keywords even if they are not listed above
      echo "$raw"
      ;;
  esac
}

provider_to_server_arg() {
  local provider="$1"
  local lower="${provider,,}"
  case "$lower" in
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

is_google_server_value() {
  local server="${1:-}"
  local lower="${server,,}"
  local gts_default_lower="${GTS_DIRECTORY_DEFAULT,,}"
  local gts_client_lower="${GTS_CLIENTAUTH_DIRECTORY,,}"
  local gts_mtls_lower="${GTS_MTLS_DIRECTORY,,}"
  local gts_mtls_client_lower="${GTS_MTLS_CLIENTAUTH_DIRECTORY,,}"
  [[ -n "$lower" && ( "$lower" == "google" || "$lower" == "$gts_default_lower" || "$lower" == "$gts_client_lower" || "$lower" == "$gts_mtls_lower" || "$lower" == "$gts_mtls_client_lower" ) ]]
}

format_ca_display() {
  local raw="${1:-}"
  if [[ -z "$raw" ]]; then
    echo ""
    return
  fi
  local lower="${raw,,}"
  local gts_default_lower="${GTS_DIRECTORY_DEFAULT,,}"
  local gts_client_lower="${GTS_CLIENTAUTH_DIRECTORY,,}"
  local gts_mtls_lower="${GTS_MTLS_DIRECTORY,,}"
  local gts_mtls_client_lower="${GTS_MTLS_CLIENTAUTH_DIRECTORY,,}"
  if [[ "$lower" == "google" || "$lower" == "$gts_default_lower" ]]; then
    echo "Google Trust Services"
    return
  fi
  if [[ "$lower" == "$gts_client_lower" ]]; then
    echo "Google Trust Services (clientAuth)"
    return
  fi
  if [[ "$lower" == "$gts_mtls_lower" ]]; then
    echo "Google Trust Services (mTLS)"
    return
  fi
  if [[ "$lower" == "$gts_mtls_client_lower" ]]; then
    echo "Google Trust Services (mTLS clientAuth)"
    return
  fi
  echo "$raw"
}

ensure_packages() {
  local missing=()
  for pkg in "$@"; do
    if ! dpkg -s "$pkg" &>/dev/null; then
      missing+=("$pkg")
    fi
  done

  if ((${#missing[@]})); then
    if [[ $APT_UPDATED -eq 0 ]]; then
      info "Updating apt package index..."
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      APT_UPDATED=1
    fi
    info "Installing dependencies: ${missing[*]}"
    apt-get install -y --no-install-recommends "${missing[@]}"
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
    exit 1
  fi
  if [[ ! -x "$ACME_HOME/acme.sh" ]]; then
    err "acme.sh is not installed. Please install it first."
    exit 1
  fi

  info "Setting default CA: $server"
  "$ACME_HOME/acme.sh" --set-default-ca --server "$server"
}

uninstall_acme() {
  if [[ ! -d "$ACME_HOME" ]]; then
    info "acme.sh is not installed; nothing to remove."
    return
  fi

  if [[ -x "$ACME_HOME/acme.sh" ]]; then
    info "Running acme.sh --uninstall"
    "$ACME_HOME/acme.sh" --uninstall || true
  fi

  info "Removing $ACME_HOME"
  rm -rf "$ACME_HOME"
}

install_acme() {
  local email="$1"
  local provider="$2"
  local force="$3"

  if [[ -x "$ACME_HOME/acme.sh" ]]; then
    if [[ "$force" == "0" ]]; then
      info "acme.sh is already installed. Re-run installation only if you choose reinstall."
      return
    fi
    info "Reinstall requested; uninstalling current copy first."
    uninstall_acme
  fi

  ensure_packages curl socat cron
  run_official_installer "$email"
  set_default_ca "$provider"
  local server_arg server_label
  server_arg="$(provider_to_server_arg "$provider")"
  server_label="$(format_ca_display "$server_arg")"
  info "acme.sh installation finished. Default CA: ${server_label:-$server_arg}"
}

show_status() {
  if [[ -x "$ACME_HOME/acme.sh" ]]; then
    echo "acme.sh binary: $ACME_HOME/acme.sh"
    "$ACME_HOME/acme.sh" --version
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
    return
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
  local tmp
  tmp="$(mktemp)"
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

read_account_conf_var() {
  local key="$1"
  local file="$ACME_HOME/account.conf"
  [[ -f "$file" ]] || return
  awk -v key="$key" -F'=' '
    $1 == key {
      val=$2
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

prompt_certificate_key_type() {
  cat <<'EOF' >&2
Select certificate key type(s):
  1) RSA
  2) ECC
  3) Both RSA and ECC
EOF
  local choice
  read -rp "Key type selection [1]: " choice
  case "${choice:-1}" in
    1) echo "rsa" ;;
    2) echo "ecc" ;;
    3) echo "both" ;;
    *) echo "rsa" ;;
  esac
}

certificate_conf_path() {
  local domain="$1"
  local variant="$2"
  local base_dir
  base_dir="$(certificate_storage_dir "$domain" "$variant")"
  echo "$base_dir/$domain.conf"
}

certificate_storage_dir() {
  local domain="$1"
  local variant="$2"
  local base_dir
  if [[ "$variant" == "ecc" ]]; then
    base_dir="$ACME_HOME/${domain}_ecc"
  else
    base_dir="$ACME_HOME/$domain"
  fi
  echo "$base_dir"
}

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
  local key_label="RSA"
  if [[ "$variant" == "ecc" ]]; then
    key_label="ECC"
  fi
  awk -v dom="$domain" -v key="$key_label" '
    BEGIN {found=0}
    NR == 1 {next}
    $1 == dom && $2 == key {found=1; exit}
    END {exit (found ? 0 : 1)}
  ' <<<"$cached_list"
}

confirm() {
  local prompt="${1:-Are you sure?}"
  local answer
  read -rp "$prompt [y/N]: " answer
  [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
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
      info "Force reissue skipped."
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
    if confirm "acme.sh is already installed. Reinstall"; then
      force=1
    else
      echo "Skipping installation."
      return
    fi
  fi

  install_acme "$email" "$provider" "$force"
  if is_google_server_value "$server_arg"; then
    register_google_account "$server_arg"
  fi
}

uninstall_flow() {
  if confirm "This will remove acme.sh and its directory. Continue"; then
    uninstall_acme
  else
    echo "Uninstall canceled."
  fi
}

set_ca_flow() {
  local provider
  provider="$(prompt_provider)"
  local server_arg
  server_arg="$(provider_to_server_arg "$provider")"
  set_default_ca "$provider"
  if is_google_server_value "$server_arg"; then
    register_google_account "$server_arg"
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
      return
      ;;
  esac

  info "Cloudflare credentials saved to $ACME_ENV_FILE"
  load_env_file
}

issue_single_domain_certificate() {
  ensure_acme_installed || return
  local domain method mode
  read -rp "Enter the domain (example.com): " domain
  if [[ -z "$domain" ]]; then
    err "Domain is required."
    return
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
        return
      fi
      mode="dns_cf"
      ;;
    *)
      echo "Unknown selection. Canceling."
      return
      ;;
  esac

  local cmd=( "$ACME_HOME/acme.sh" --issue -d "$domain" )
  if [[ "$mode" == "standalone" ]]; then
    cmd+=(--standalone)
  else
    cmd+=(--dns dns_cf)
  fi

  if ! run_acme_issue_command "$domain" "${cmd[@]}"; then
    err "Certificate issuance failed."
    return
  fi

  info "Certificate issued. Files are available under $ACME_HOME/$domain"
}

issue_wildcard_certificate() {
  ensure_acme_installed || return
  if ! ensure_cloudflare_ready; then
    return
  fi

  local domain
  read -rp "Enter the base domain (example.com): " domain
  if [[ -z "$domain" ]]; then
    err "Domain is required."
    return
  fi

  local ca
  ca="$(current_default_ca)"
  if is_google_server_value "$ca"; then
    local ca_label
    ca_label="$(format_ca_display "$ca")"
    echo "${ca_label:-Google Trust Services} requires Google ACME External Account Binding for wildcard orders."
    if ! register_google_account "$ca"; then
      return
    fi
  fi

  local cmd=( "$ACME_HOME/acme.sh" --issue -d "$domain" -d "*.$domain" --dns dns_cf )
  if ! run_acme_issue_command "$domain" "${cmd[@]}"; then
    err "Wildcard certificate issuance failed."
    return
  fi

  info "Wildcard certificate issued. Files are available under $ACME_HOME/$domain"
}

remove_certificates_flow() {
  ensure_acme_installed || return

  echo "Existing certificates managed by acme.sh:"
  local list_output=""
  if ! list_output="$("$ACME_HOME/acme.sh" --list 2>&1)"; then
    err "Unable to list certificates via acme.sh (continuing anyway)."
  fi
  if [[ -n "$list_output" ]]; then
    echo "$list_output"
  fi

  local domain_input
  read -rp "Enter the primary domain(s) to remove (space-separated): " domain_input
  read -ra domain_array <<<"$domain_input"
  local domains=()
  local domain
  for domain in "${domain_array[@]}"; do
    if [[ -n "$domain" ]]; then
      domains+=("${domain,,}")
    fi
  done

  if ((${#domains[@]} == 0)); then
    err "At least one domain must be provided."
    return
  fi

  local key_choice
  key_choice="$(prompt_certificate_key_type)"
  local variants=()
  local variant_label="RSA"
  case "$key_choice" in
    ecc)
      variants=(ecc)
      variant_label="ECC"
      ;;
    both)
      variants=(rsa ecc)
      variant_label="RSA and ECC"
      ;;
    *)
      variants=(rsa)
      variant_label="RSA"
      ;;
  esac

  echo "Selected domain(s): ${domains[*]}"
  if ! confirm "Remove $variant_label certificate(s) for the selected domain(s)"; then
    echo "Deletion canceled."
    return
  fi

  local failures=0
  local cleanup_targets=()
  for domain in "${domains[@]}"; do
    for variant in "${variants[@]}"; do
      local human_label="RSA"
      if [[ "$variant" == "ecc" ]]; then
        human_label="ECC"
      fi
      if ! certificate_variant_exists "$domain" "$variant" "$list_output"; then
        info "No $human_label certificate found for $domain; skipping."
        continue
      fi
      cleanup_targets+=("$domain:$variant")
      local cmd=( "$ACME_HOME/acme.sh" --remove -d "$domain" )
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
          ((failures++))
        fi
      else
        echo "$cmd_output"
        info "$human_label certificate for $domain removed."
      fi
    done
  done

  if ((${#cleanup_targets[@]})); then
    if confirm "Also delete the local acme.sh directory (removes CSR/key) for these domain(s)"; then
      for target in "${cleanup_targets[@]}"; do
        local target_domain target_variant dir
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
10) Exit
EOF
}

main() {
  while true; do
    main_menu
    local choice
    read -rp "Choose an option [1-10]: " choice
    case "$choice" in
      1|"")
        issue_single_domain_certificate
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

require_root
load_env_file
main
