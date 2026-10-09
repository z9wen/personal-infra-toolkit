#!/bin/bash
#
# sync-cert-to-hestia - Install an acme.sh certificate into a HestiaCP web domain.
#
# Usage:
#   sync-cert-to-hestia domain.com [user]             # Use the domain.com certificate
#   sync-cert-to-hestia '*' domain.com [user]         # Use the wildcard certificate
#   sync-cert-to-hestia --wildcard domain.com [user]  # Same as '*', no quoting needed
#
# Examples:
#   sync-cert-to-hestia subdomain.example.com             # subdomain.example.com certificate
#   sync-cert-to-hestia '*' subdomain.example.com         # *.example.com wildcard certificate
#
# Quote the '*' or use --wildcard/-w. An unquoted * is expanded by the shell to
# the file names in the current directory before this script starts; when that
# happens the script detects the expansion and still uses wildcard mode.
#
# The certificate is staged in a private temporary directory and installed with
# HestiaCP's own commands (v-update-web-domain-ssl when SSL is already enabled,
# v-add-web-domain-ssl otherwise), so HestiaCP's data and web config stay in sync.
#
# Environment overrides:
#   ACME_HOME  acme.sh home directory (default: /root/.acme.sh)
#   HESTIA     HestiaCP installation directory (default: /usr/local/hestia)

set -euo pipefail

ACME_HOME="${ACME_HOME:-/root/.acme.sh}"
HESTIA="${HESTIA:-/usr/local/hestia}"
DEFAULT_USER="admin"

CERT_TYPE=""
DOMAIN=""
HESTIA_USER=""
STAGE_DIR=""

usage() {
    echo "Usage: sync-cert-to-hestia domain.com [user]"
    echo "       sync-cert-to-hestia '*' domain.com [user]"
    echo "       sync-cert-to-hestia --wildcard domain.com [user]"
    echo ""
    echo "Examples:"
    echo "  sync-cert-to-hestia subdomain.example.com             # Single domain cert"
    echo "  sync-cert-to-hestia '*' subdomain.example.com         # Wildcard cert (quote the *)"
    echo "  sync-cert-to-hestia --wildcard subdomain.example.com  # Wildcard cert"
}

fail() {
    echo "❌ $*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$STAGE_DIR" ]]; then
        rm -rf -- "$STAGE_DIR"
    fi
}

# Prints how many leading arguments are the shell's expansion of an unquoted *
# in the current directory (with the default bash glob settings), or 0.
expanded_star_count() {
    local entries=(*)
    local count=${#entries[@]} index

    # Wildcard mode needs a domain (with a dot) and at most a user after the *.
    (($# > count && $# <= count + 2)) || {
        echo 0
        return
    }
    for ((index = 0; index < count; index++)); do
        if [[ "${entries[index]}" != "$1" ]]; then
            echo 0
            return
        fi
        shift
    done
    if [[ "$1" == *.* ]]; then
        echo "$count"
    else
        echo 0
    fi
}

parse_args() {
    local star_words

    (($# > 0)) || {
        usage
        exit 1
    }

    case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
        '*' | -w | --wildcard)
            CERT_TYPE="wildcard"
            shift
            ;;
        *)
            star_words="$(expanded_star_count "$@")"
            if ((star_words > 0)); then
                echo "⚠️  An unquoted * was expanded by the shell; using wildcard mode (quote it as '*' next time)."
                CERT_TYPE="wildcard"
                shift "$star_words"
            else
                CERT_TYPE="single"
            fi
            ;;
    esac

    (($# >= 1 && $# <= 2)) || {
        usage
        exit 1
    }
    DOMAIN="$1"
    HESTIA_USER="${2:-$DEFAULT_USER}"

    [[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$DOMAIN" == *.* ]] \
        || fail "Invalid domain name: $DOMAIN"
    [[ "$HESTIA_USER" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
        || fail "Invalid HestiaCP user name: $HESTIA_USER"
}

# Parent zone covered by a wildcard for DOMAIN: sub.example.com -> example.com.
# A two-label domain is its own zone (example.com -> example.com).
wildcard_zone() {
    local domain="$1"
    local parent="${domain#*.}"
    if [[ "$parent" == *.* ]]; then
        echo "$parent"
    else
        echo "$domain"
    fi
}

# Prints the acme.sh certificate directory (ECC first, then RSA) or returns 1.
find_acme_dir() {
    local candidates=() candidate zone

    if [[ "$CERT_TYPE" == "wildcard" ]]; then
        zone="$(wildcard_zone "$DOMAIN")"
        candidates=(
            "$ACME_HOME/*.${zone}_ecc"
            "$ACME_HOME/*.${zone}"
            "$ACME_HOME/${zone}_ecc"
            "$ACME_HOME/${zone}"
        )
    else
        candidates=("$ACME_HOME/${DOMAIN}_ecc" "$ACME_HOME/${DOMAIN}")
    fi

    for candidate in "${candidates[@]}"; do
        if [[ -d "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

show_available_certificates() {
    local dir found=0
    echo ""
    echo "💡 Available certificates:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    for dir in "$ACME_HOME"/*_ecc; do
        [[ -d "$dir" ]] || continue
        found=$((found + 1))
        dir="${dir##*/}"
        printf '%6d\t%s\n' "$found" "${dir%_ecc}"
    done
    ((found > 0)) || echo "   No certificates found"
    echo ""
}

print_header() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ "$CERT_TYPE" == "wildcard" ]]; then
        echo "🌐 Mode: Wildcard Certificate"
        echo "📍 Domain: $DOMAIN"
        echo "🔑 Certificate: *.$(wildcard_zone "$DOMAIN")"
    else
        echo "📄 Mode: Single Domain Certificate"
        echo "📍 Domain: $DOMAIN"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Copies the certificate into a private temporary directory using the file
# names HestiaCP expects (<domain>.crt, <domain>.key and optional <domain>.ca).
# Staging must not use /home/<user>/conf/web/<domain>/ssl: HestiaCP rewrites
# that directory itself.
stage_certificate() {
    local acme_dir="$1"
    local cert_name="${acme_dir##*/}"
    cert_name="${cert_name%_ecc}"
    local cert_file="$acme_dir/$cert_name.cer"
    local key_file="$acme_dir/$cert_name.key"
    local ca_file="$acme_dir/ca.cer"

    if [[ ! -f "$cert_file" || ! -f "$key_file" ]]; then
        echo "❌ Certificate or key file not found in $acme_dir" >&2
        echo "" >&2
        echo "Directory contents:" >&2
        ls -la "$acme_dir" >&2 || true
        exit 1
    fi

    echo "📋 Copying certificates..."
    echo "   ✓ Certificate: ${cert_file##*/}"
    echo "   ✓ Key: ${key_file##*/}"

    STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sync-cert-to-hestia.XXXXXX")" \
        || fail "Cannot create a temporary staging directory"
    chmod 700 "$STAGE_DIR"

    cp -- "$cert_file" "$STAGE_DIR/$DOMAIN.crt"
    cp -- "$key_file" "$STAGE_DIR/$DOMAIN.key"
    if [[ -f "$ca_file" ]]; then
        echo "   ✓ CA: ${ca_file##*/}"
        cp -- "$ca_file" "$STAGE_DIR/$DOMAIN.ca"
    fi

    echo "🔒 Setting permissions..."
    chmod 600 "$STAGE_DIR/$DOMAIN".*
}

install_certificate() {
    local user_ssl_cert="$HESTIA/data/users/$HESTIA_USER/ssl/$DOMAIN.crt"

    echo "🔧 Enabling SSL in HestiaCP..."
    if [[ -f "$user_ssl_cert" ]]; then
        # SSL is already enabled: replace the certificate in place so SSL never
        # goes offline and settings such as forced HTTPS are kept.
        "$HESTIA/bin/v-update-web-domain-ssl" "$HESTIA_USER" "$DOMAIN" "$STAGE_DIR"
    else
        "$HESTIA/bin/v-add-web-domain-ssl" "$HESTIA_USER" "$DOMAIN" "$STAGE_DIR"
    fi
}

reload_nginx() {
    if systemctl is-active --quiet nginx; then
        echo "♻️  Reloading nginx..."
        systemctl reload nginx || fail "SSL was installed but reloading nginx failed"
    fi
}

main() {
    local acme_dir

    parse_args "$@"
    print_header

    if ! acme_dir="$(find_acme_dir)"; then
        echo ""
        echo "❌ Certificate not found!"
        show_available_certificates
        exit 1
    fi
    echo "📁 Certificate source: $acme_dir"

    trap cleanup EXIT
    stage_certificate "$acme_dir"

    if ! install_certificate; then
        echo ""
        echo "❌ Failed to enable SSL in HestiaCP"
        exit 1
    fi

    reload_nginx
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ Success! SSL enabled for $DOMAIN"
    echo "🔗 Test: https://$DOMAIN"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
