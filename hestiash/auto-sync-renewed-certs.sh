#!/bin/bash
#
# auto-sync-renewed-certs.sh
# Automatically detect renewed certificates from acme.sh and sync them to HestiaCP.
#
# Web domains are updated with HestiaCP's own v-update-web-domain-ssl, which
# stores the certificate in HestiaCP's data directory ($HESTIA/data/users/<user>/ssl,
# the source of truth used when web configs are rebuilt) and rewrites
# /home/<user>/conf/web/<domain>/ssl. Domains without SSL enabled in HestiaCP are
# skipped. A certificate is considered renewed when the acme.sh certificate file
# is newer than the copy HestiaCP stores.
#
# Exit status: 0 when every sync succeeded, 1 when at least one failed.
#
# Configuration (edit below or override through the environment):

LOG_FILE="${LOG_FILE:-/var/log/acme-auto-sync.log}"
ACME_DIR="${ACME_DIR:-/root/.acme.sh}"
HESTIA="${HESTIA:-/usr/local/hestia}"
HESTIA_HOME_DIR="${HESTIA_HOME_DIR:-/home}"
HESTIA_USER="${HESTIA_USER:-admin}"               # HestiaCP panel user
PANEL_DOMAIN="${PANEL_DOMAIN:-panel.example.com}" # HestiaCP panel domain
PANEL_SSL_DIR="${PANEL_SSL_DIR:-$HESTIA/ssl}"     # HestiaCP panel certificate directory

set -euo pipefail

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Copies the acme.sh files into a new private directory using the names
# HestiaCP expects and prints its path.
stage_certificate() {
    local domain="$1" acme_cert_dir="$2"
    local stage_dir

    stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/acme-auto-sync.XXXXXX")" || return 1
    if cp -- "$acme_cert_dir/${domain}.cer" "$stage_dir/${domain}.crt" \
        && cp -- "$acme_cert_dir/${domain}.key" "$stage_dir/${domain}.key" \
        && { [[ ! -f "$acme_cert_dir/ca.cer" ]] || cp -- "$acme_cert_dir/ca.cer" "$stage_dir/${domain}.ca"; } \
        && chmod 600 "$stage_dir/${domain}".*; then
        echo "$stage_dir"
        return 0
    fi
    rm -rf -- "$stage_dir"
    return 1
}

# Sync certificate for a single web domain.
# Returns 0 when synced, 2 when up to date or skipped, 1 on failure.
sync_domain() {
    local domain="$1"
    local acme_cert_dir="${ACME_DIR}/${domain}_ecc"
    local hestia_cert="$HESTIA/data/users/${HESTIA_USER}/ssl/${domain}.crt"
    local stage_dir status=0

    # Check if certificate files exist
    if [[ ! -f "$acme_cert_dir/${domain}.cer" || ! -f "$acme_cert_dir/${domain}.key" ]]; then
        log "⚠️  ACME certificate not found for $domain"
        return 1
    fi

    # Only domains that already have SSL enabled in HestiaCP are updated
    if [[ ! -f "$hestia_cert" ]]; then
        log "ℹ️  SSL is not enabled in HestiaCP for $domain; skipping"
        return 2
    fi

    if [[ ! "$acme_cert_dir/${domain}.cer" -nt "$hestia_cert" ]]; then
        log "ℹ️  Certificate for $domain is up to date"
        return 2
    fi

    log "📋 Syncing certificate for $domain..."
    if ! stage_dir="$(stage_certificate "$domain" "$acme_cert_dir")"; then
        log "❌ Could not stage certificate files for $domain"
        return 1
    fi

    "$HESTIA/bin/v-update-web-domain-ssl" "$HESTIA_USER" "$domain" "$stage_dir" 2>&1 \
        | tee -a "$LOG_FILE" || status=$?
    rm -rf -- "$stage_dir"

    if ((status != 0)); then
        log "❌ HestiaCP failed to update the certificate for $domain"
        return 1
    fi
    log "✅ Certificate synced for $domain"
    return 0
}

# Sync HestiaCP panel certificate (special handling).
# Returns 0 when synced, 2 when up to date, 1 on failure.
sync_panel_cert() {
    local domain="$PANEL_DOMAIN"
    local acme_cert_dir="${ACME_DIR}/${domain}_ecc"
    local user_ssl_dir="$HESTIA/data/users/${HESTIA_USER}/ssl"

    if [[ ! -f "$acme_cert_dir/${domain}.cer" || ! -f "$acme_cert_dir/fullchain.cer" || ! -f "$acme_cert_dir/${domain}.key" ]]; then
        log "⚠️  Panel certificate files not found in $acme_cert_dir"
        return 1
    fi

    # -nt is also true when the panel certificate does not exist yet
    if [[ ! "$acme_cert_dir/${domain}.cer" -nt "$PANEL_SSL_DIR/certificate.crt" ]]; then
        log "ℹ️  Panel certificate is up to date"
        return 2
    fi

    log "📋 Syncing panel certificate for $domain..."

    # Copy to panel directory, then to the user directory
    if ! {
        cp -- "$acme_cert_dir/fullchain.cer" "$PANEL_SSL_DIR/certificate.crt" \
            && cp -- "$acme_cert_dir/${domain}.key" "$PANEL_SSL_DIR/certificate.key" \
            && mkdir -p "$user_ssl_dir" \
            && cp -- "$acme_cert_dir/fullchain.cer" "$user_ssl_dir/${domain}.pem" \
            && cp -- "$acme_cert_dir/fullchain.cer" "$user_ssl_dir/${domain}.crt" \
            && cp -- "$acme_cert_dir/${domain}.key" "$user_ssl_dir/${domain}.key"
    }; then
        log "❌ Could not copy the panel certificate files"
        return 1
    fi

    log "✅ Panel certificate synced"
    log "♻️  Restarting HestiaCP..."
    if ! systemctl restart hestia; then
        log "❌ Restarting HestiaCP failed"
        return 1
    fi
    return 0
}

main() {
    local cert_dir domain status
    local need_reload=false failures=0

    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "🔄 Starting auto-sync for renewed certificates"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Iterate through all ECC certificate directories
    for cert_dir in "$ACME_DIR"/*_ecc/; do
        [[ -d "$cert_dir" ]] || continue
        domain="${cert_dir%/}"
        domain="${domain##*/}"
        domain="${domain%_ecc}"

        # Skip wildcard certificates
        if [[ "$domain" == \** ]]; then
            continue
        fi

        status=0
        if [[ "$domain" == "$PANEL_DOMAIN" ]]; then
            # Restarting hestia does not reload the system nginx, so a reload
            # requested by another domain must be kept.
            sync_panel_cert || status=$?
        elif [[ -d "${HESTIA_HOME_DIR}/${HESTIA_USER}/conf/web/${domain}" ]]; then
            sync_domain "$domain" || status=$?
            if ((status == 0)); then
                need_reload=true
            fi
        else
            continue
        fi
        if ((status == 1)); then
            failures=$((failures + 1))
        fi
    done

    # Reload nginx if there are updates
    if [[ "$need_reload" == true ]]; then
        log "♻️  Reloading nginx..."
        if systemctl reload nginx; then
            log "✅ Nginx reloaded"
        else
            log "❌ Nginx reload failed"
            failures=$((failures + 1))
        fi
    fi

    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if ((failures > 0)); then
        log "❌ Auto-sync completed with $failures error(s)"
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        return 1
    fi
    log "✅ Auto-sync completed"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
