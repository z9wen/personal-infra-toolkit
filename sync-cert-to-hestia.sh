#!/bin/bash

# sync-cert-to-hestia - Sync ACME certificates to HestiaCP
# 
# Usage:
#   sync-cert-to-hestia domain.com [user]         # Use single domain certificate
#   sync-cert-to-hestia * domain.com [user]       # Use wildcard certificate (no quotes needed!)
#
# Examples:
#   sync-cert-to-hestia subdomain.example.com             # Use subdomain.example.com certificate
#   sync-cert-to-hestia * subdomain.example.com           # Use *.example.com wildcard certificate

ARG1=$1
ARG2=$2
ARG3=$3

# Show help
if [ -z "$ARG1" ]; then
  echo "Usage: sync-cert-to-hestia domain.com [user]"
  echo "       sync-cert-to-hestia * domain.com [user]"
  echo ""
  echo "Examples:"
  echo "  sync-cert-to-hestia subdomain.example.com          # Single domain cert"
  echo "  sync-cert-to-hestia * subdomain.example.com        # Wildcard cert (no quotes!)"
  exit 1
fi

# Determine if single domain or wildcard
if [ "$ARG1" = "*" ]; then
  # Wildcard mode
  CERT_TYPE="wildcard"
  DOMAIN="$ARG2"
  USER="${ARG3:-admin}"

  # Extract main domain
  MAIN_DOMAIN=$(echo "$DOMAIN" | awk -F. '{if (NF>=2) print $(NF-1)"."$NF; else print $0}')
  
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🌐 Mode: Wildcard Certificate"
  echo "📍 Domain: $DOMAIN"
  echo "🔑 Certificate: *.$MAIN_DOMAIN"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
else
  # Single domain mode
  CERT_TYPE="single"
  DOMAIN="$ARG1"
  USER="${ARG2:-admin}"
  MAIN_DOMAIN="$DOMAIN"

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "📄 Mode: Single Domain Certificate"
  echo "📍 Domain: $DOMAIN"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi

# Determine certificate directory
if [ "$CERT_TYPE" = "wildcard" ]; then
  # Try multiple possible wildcard certificate directory formats
  if [ -d "/root/.acme.sh/\*.${MAIN_DOMAIN}_ecc" ]; then
    ACME_DIR="/root/.acme.sh/\*.${MAIN_DOMAIN}_ecc"
  elif [ -d "/root/.acme.sh/${MAIN_DOMAIN}_ecc" ]; then
    ACME_DIR="/root/.acme.sh/${MAIN_DOMAIN}_ecc"
  else
    ACME_DIR=""
  fi
else
  ACME_DIR="/root/.acme.sh/${DOMAIN}_ecc"
fi

SSL_DIR="/home/$USER/conf/web/$DOMAIN/ssl"

# Check if certificate exists
if [ -z "$ACME_DIR" ] || [ ! -d "$ACME_DIR" ]; then
  echo ""
  echo "❌ Certificate not found!"
  echo ""
  echo "💡 Available certificates:"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  ls -d /root/.acme.sh/*_ecc 2>/dev/null | sed 's|/root/.acme.sh/||g' | sed 's|_ecc||g' | nl || echo "   No certificates found"
  echo ""
  exit 1
fi

echo "📁 Certificate source: $ACME_DIR"

# Create SSL directory
mkdir -p "$SSL_DIR"

# Copy certificate files
echo "📋 Copying certificates..."

# Find certificate files
CERT_FILE=$(find "$ACME_DIR" -maxdepth 1 -name "*.cer" ! -name "ca.cer" ! -name "fullchain.cer" -type f | head -1)
KEY_FILE=$(find "$ACME_DIR" -maxdepth 1 -name "*.key" -type f | head -1)

if [ -z "$CERT_FILE" ] || [ -z "$KEY_FILE" ]; then
  echo "❌ Certificate or key file not found in $ACME_DIR"
  echo ""
  echo "Directory contents:"
  ls -la "$ACME_DIR"
  exit 1
fi

echo "   ✓ Certificate: $(basename "$CERT_FILE")"
echo "   ✓ Key: $(basename "$KEY_FILE")"

cp "$CERT_FILE" "$SSL_DIR/${DOMAIN}.crt"
cp "$KEY_FILE" "$SSL_DIR/${DOMAIN}.key"
cp "$ACME_DIR/ca.cer" "$SSL_DIR/${DOMAIN}.ca"
cp "$ACME_DIR/fullchain.cer" "$SSL_DIR/${DOMAIN}.pem"

# Set permissions
echo "🔒 Setting permissions..."
chmod 644 "$SSL_DIR/${DOMAIN}.crt"
chmod 600 "$SSL_DIR/${DOMAIN}.key"
chmod 644 "$SSL_DIR/${DOMAIN}.ca"
chmod 644 "$SSL_DIR/${DOMAIN}.pem"

# Enable SSL in HestiaCP
echo "🔧 Enabling SSL in HestiaCP..."
/usr/local/hestia/bin/v-delete-web-domain-ssl "$USER" "$DOMAIN" 2>/dev/null
/usr/local/hestia/bin/v-add-web-domain-ssl "$USER" "$DOMAIN" "$SSL_DIR"

if [ $? -eq 0 ]; then
  echo "♻️  Reloading nginx..."
  systemctl reload nginx
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "✅ Success! SSL enabled for $DOMAIN"
  echo "🔗 Test: https://$DOMAIN"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
else
  echo ""
  echo "❌ Failed to enable SSL in HestiaCP"
  exit 1
fi
