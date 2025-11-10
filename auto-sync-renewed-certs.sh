#!/bin/bash

# auto-sync-renewed-certs.sh
# Automatically detect renewed certificates from acme.sh and sync to HestiaCP

LOG_FILE="/var/log/acme-auto-sync.log"
ACME_DIR="/root/.acme.sh"
USER="admin" # HestiaCP panel user
PANEL_DOMAIN="panel.example.com"  # HestiaCP panel domain

# Logging function
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "🔄 Starting auto-sync for renewed certificates"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Sync certificate for a single domain
sync_domain() {
  local domain=$1
  local acme_cert_dir="${ACME_DIR}/${domain}_ecc"
  local ssl_dir="/home/${USER}/conf/web/${domain}/ssl"

  # Check if certificate directory exists
  if [ ! -d "$acme_cert_dir" ]; then
    log "⚠️  Certificate directory not found: $acme_cert_dir"
    return 1
  fi

  # Check if SSL directory exists
  if [ ! -d "$ssl_dir" ]; then
    log "⚠️  SSL directory not found: $ssl_dir"
    return 1
  fi

  # Get certificate modification time
  local acme_cert_time=$(stat -c %Y "$acme_cert_dir/${domain}.cer" 2>/dev/null)
  local hestia_cert_time=$(stat -c %Y "$ssl_dir/${domain}.crt" 2>/dev/null)

  if [ -z "$acme_cert_time" ]; then
    log "⚠️  ACME certificate not found for $domain"
    return 1
  fi

  # Sync if certificate is updated
  if [ -z "$hestia_cert_time" ] || [ "$acme_cert_time" -gt "$hestia_cert_time" ]; then
    log "📋 Syncing certificate for $domain..."

    # Copy certificate files
    cp "$acme_cert_dir/${domain}.cer" "$ssl_dir/${domain}.crt"
    cp "$acme_cert_dir/${domain}.key" "$ssl_dir/${domain}.key"
    cp "$acme_cert_dir/ca.cer" "$ssl_dir/${domain}.ca" 2>/dev/null
    cp "$acme_cert_dir/fullchain.cer" "$ssl_dir/${domain}.pem"

    # Set permissions
    chmod 644 "$ssl_dir/${domain}.crt"
    chmod 600 "$ssl_dir/${domain}.key"
    chmod 644 "$ssl_dir/${domain}.ca" 2>/dev/null
    chmod 644 "$ssl_dir/${domain}.pem"

    log "✅ Certificate synced for $domain"
    return 0
  else
    log "ℹ️  Certificate for $domain is up to date"
    return 2
  fi
}

# Sync HestiaCP panel certificate (special handling)
sync_panel_cert() {
  local domain="$PANEL_DOMAIN"
  local acme_cert_dir="${ACME_DIR}/${domain}_ecc"
  local panel_ssl_dir="/usr/local/hestia/ssl"
  local user_ssl_dir="/usr/local/hestia/data/users/${USER}/ssl"

  if [ ! -d "$acme_cert_dir" ]; then
    log "⚠️  Panel certificate directory not found"
    return 1
  fi

  # Get certificate modification time
  local acme_cert_time=$(stat -c %Y "$acme_cert_dir/${domain}.cer" 2>/dev/null)
  local panel_cert_time=$(stat -c %Y "$panel_ssl_dir/certificate.crt" 2>/dev/null)

  if [ -z "$acme_cert_time" ]; then
    return 1
  fi

  # Sync if certificate is updated
  if [ -z "$panel_cert_time" ] || [ "$acme_cert_time" -gt "$panel_cert_time" ]; then
    log "📋 Syncing panel certificate for $domain..."

    # Copy to panel directory
    cp "$acme_cert_dir/fullchain.cer" "$panel_ssl_dir/certificate.crt"
    cp "$acme_cert_dir/${domain}.key" "$panel_ssl_dir/certificate.key"

    # Copy to user directory
    mkdir -p "$user_ssl_dir"
    cp "$acme_cert_dir/fullchain.cer" "$user_ssl_dir/${domain}.pem"
    cp "$acme_cert_dir/fullchain.cer" "$user_ssl_dir/${domain}.crt"
    cp "$acme_cert_dir/${domain}.key" "$user_ssl_dir/${domain}.key"

    log "✅ Panel certificate synced"
    log "♻️  Restarting HestiaCP..."
    systemctl restart hestia
    return 0
  else
    log "ℹ️  Panel certificate is up to date"
    return 2
  fi
}

# Get all domains that need to be synced
DOMAINS=()
NEED_RELOAD=false

# Iterate through all ECC certificate directories
for cert_dir in ${ACME_DIR}/*_ecc/; do
  if [ -d "$cert_dir" ]; then
    domain=$(basename "$cert_dir" | sed 's/_ecc$//')

    # Skip wildcard certificates
    if [[ "$domain" == \** ]]; then
      continue
    fi

    # Check if it's the panel domain
    if [ "$domain" = "$PANEL_DOMAIN" ]; then
      sync_panel_cert
      if [ $? -eq 0 ]; then
        NEED_RELOAD=false  # Panel restarted, no need to reload nginx
      fi
    else
      # Check if domain exists in HestiaCP
      if [ -d "/home/${USER}/conf/web/${domain}" ]; then
        sync_domain "$domain"
        if [ $? -eq 0 ]; then
          NEED_RELOAD=true
        fi
      fi
    fi
  fi
done

# Reload nginx if there are updates
if [ "$NEED_RELOAD" = true ]; then
  log "♻️  Reloading nginx..."
  systemctl reload nginx
  log "✅ Nginx reloaded"
fi

log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "✅ Auto-sync completed"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
