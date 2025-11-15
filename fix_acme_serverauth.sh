#!/usr/bin/env bash
set -euo pipefail

ACME_HOME="${ACME_HOME:-$HOME/.acme.sh}"
ACME_ENV_FILE="${ACME_ENV_FILE:-/etc/acme.sh.env}"
ACCOUNT_CONF="$ACME_HOME/account.conf"

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
  local names=("$@")
  if [[ ! -f "$file" ]]; then
    echo "$file not found."
    return
  fi
  for name in "${names[@]}"; do
    local line
    line="$(grep -nE "^${name}=" "$file" || true)"
    if [[ -n "$line" ]]; then
      echo "$line"
    else
      echo "$name not set in $file"
    fi
  done
}

search_clientauth_csr_confs() {
  if [[ ! -d "$ACME_HOME" ]]; then
    return
  fi
  if command -v rg >/dev/null 2>&1; then
    rg -l "clientAuth" --glob "*.csr.conf" "$ACME_HOME" || true
  else
    grep -rl "clientAuth" "$ACME_HOME" --include "*.csr.conf" || true
  fi
}

remove_polluted_csrs() {
  if ((${#polluted_confs[@]} == 0)); then
    echo "No polluted CSR config files detected."
    return
  fi
  echo "The following CSR config files include clientAuth:"
  printf ' - %s\n' "${polluted_confs[@]}"
  read -r -p "Remove these CSR configs and their CSR files now? [y/N]: " answer
  if [[ "${answer,,}" != "y" && "${answer,,}" != "yes" ]]; then
    echo "Skipping CSR cleanup."
    return
  fi
  local removed=0
  for conf in "${polluted_confs[@]}"; do
    local csr="${conf%.conf}"
    rm -f "$conf" "$csr"
    echo "Removed $conf and ${csr##*/}" 
    ((removed++))
  done
  echo "Removed $removed polluted CSR config(s)."
}

ensure_serverauth_profile() {
  if [[ ! -f "$ACCOUNT_CONF" ]]; then
    echo "$ACCOUNT_CONF not found; cannot update Le_ExtKeyUse." >&2
    return 1
  fi
  local tmp
  tmp="$(mktemp)"
  if grep -q "^Le_ExtKeyUse=" "$ACCOUNT_CONF"; then
    if grep -q "^Le_ExtKeyUse='serverAuth'" "$ACCOUNT_CONF"; then
      echo "Le_ExtKeyUse already set to serverAuth."
      return 0
    fi
    sed "s|^Le_ExtKeyUse=.*|Le_ExtKeyUse='serverAuth'|" "$ACCOUNT_CONF" >"$tmp"
  else
    cat "$ACCOUNT_CONF" >"$tmp"
    echo "Le_ExtKeyUse='serverAuth'" >>"$tmp"
  fi
  mv "$tmp" "$ACCOUNT_CONF"
  echo "Le_ExtKeyUse set to serverAuth in $ACCOUNT_CONF"
}

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
polluted_confs=()
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  polluted_confs+=("$line")
done < <(search_clientauth_csr_confs)
if ((${#polluted_confs[@]})); then
  printf '%s\n' "${polluted_confs[@]}"
else
  echo "No clientAuth entries found in CSR configs."
fi

remove_polluted_csrs

print_section "Ensuring Le_ExtKeyUse=serverAuth"
ensure_serverauth_profile

print_section "Re-checking CSR configs"
polluted_confs=()
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  polluted_confs+=("$line")
done < <(search_clientauth_csr_confs)
if ((${#polluted_confs[@]})); then
  echo "Still detected clientAuth in:"
  printf ' - %s\n' "${polluted_confs[@]}"
  echo "Please investigate remaining files manually."
else
  echo "All CSR configs are free of clientAuth entries."
fi
