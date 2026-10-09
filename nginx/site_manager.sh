#!/bin/bash
#
# Nginx Site Manager - menu-driven management of Nginx sites and reverse
# proxies for Docker Nginx (container "nginx", files under $NGINX_ROOT) or
# native Nginx (sites-available/sites-enabled, /var/www, /var/log/nginx).
#
# Certificates are issued elsewhere (acme_manage.sh). This script finds the
# certificates already on the machine (acme.sh, the Docker acme container,
# certbot, its own cert directory) and attaches them to sites in a way that
# keeps renewals deployed and Nginx reloaded.
#
# Run without arguments for the menu; `site_manager.sh help` lists the CLI and
# the settings that ./site_manager.conf or the environment can override.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
if [ -f "$SCRIPT_DIR/site_manager.conf" ]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/site_manager.conf"
fi

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Defaults (each may be set in site_manager.conf or the environment)
NGINX_ROOT="${NGINX_ROOT:-/opt/nginx}"             # Docker layout: conf.d, html, logs, certs
NATIVE_NGINX_DIR="${NATIVE_NGINX_DIR:-/etc/nginx}" # Native: sites-available, sites-enabled, certs
NATIVE_WEB_ROOT="${NATIVE_WEB_ROOT:-/var/www}"     # Native: site document roots
NATIVE_LOG_DIR="${NATIVE_LOG_DIR:-/var/log/nginx}" # Native: per-site log directories
NGINX_MODE="${NGINX_MODE:-}"                       # "docker" or "native"; auto-detected if empty
NGINX_CONTAINER="${NGINX_CONTAINER:-nginx}"
ACME_HOME="${ACME_HOME:-${HOME:-/root}/.acme.sh}"                             # Native acme.sh home (as in acme_manage.sh)
ACME_SH_PATH="${ACME_SH_PATH:-$ACME_HOME/acme.sh}"                            # Native acme.sh binary
ACME_CONTAINER="${ACME_CONTAINER:-acme}"                                      # Docker acme.sh container
ACME_DOCKER_DATA="${ACME_DOCKER_DATA:-/opt/acme/data}"                        # Its /acme.sh when not inspectable
ACME_RELOAD_CMD="${ACME_RELOAD_CMD:-}"                                        # Override the acme.sh --reloadcmd
CERTBOT_LIVE_DIR="${CERTBOT_LIVE_DIR:-/etc/letsencrypt/live}"                 # certbot certificates
CERTBOT_HOOK_DIR="${CERTBOT_HOOK_DIR:-/etc/letsencrypt/renewal-hooks/deploy}" # certbot deploy hooks
ACME_MANAGE_SH="${ACME_MANAGE_SH:-}"                                          # Path to acme_manage.sh

# Marker the Docker acme container touches after a renewal (see reload-if-renewed)
RENEW_MARKER_NAME=".reload-nginx"
RENEW_CRON_SCHEDULE="*/15 * * * *"
ACME_MANAGE_URL="https://raw.githubusercontent.com/z9wen/personal-infra-toolkit/main/acme_manage.sh"

# 1 while the menu runs: allows follow-up questions (HTTPS offer, cron job)
INTERACTIVE=0

TAB=$'\t'

# Print colored messages
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1" >&2; }
print_info() { echo -e "${BLUE}ℹ${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }

die() {
    print_error "$1"
    exit 1
}

# Show help
show_help() {
    cat <<'HELP'
Nginx Site Manager - manage Nginx sites and reverse proxies (Docker & native)

Usage:
  ./site_manager.sh                 Open the interactive menu (recommended)
  ./site_manager.sh <command> ...   Run a single action, e.g. from scripts

The menu picks sites from a numbered list and asks only what each action needs:
  1) List sites               4) Enable HTTPS on a site    7) View logs
  2) Add a static site        5) Enable / disable a site   8) Test and reload Nginx
  3) Reverse proxy a site     6) Delete a site             9) Issue a certificate

Certificates:
  This script does not issue certificates. Issue, renew and remove them with
  acme_manage.sh (menu option 9 runs it when it is next to this script or in
  PATH). "Enable HTTPS" then finds certificates already on this machine that
  cover the site and are not expired, and attaches one so renewals keep working:
    acme.sh (~/.acme.sh)       acme.sh --install-cert with a --reloadcmd that
                               reloads Nginx after every renewal
    acme.sh Docker container   --install-cert into its /certs mount; on renewal it
                               touches a marker that the host cron job
                               "site_manager.sh reload-if-renewed" turns into a reload
    certbot (letsencrypt/live) used in place (native Nginx) or copied (Docker Nginx),
                               plus a certbot deploy hook that re-copies and reloads
    Nginx cert directory       certificates already installed there, used as they are
    Manual paths               copied into the cert directory; NOT renewed automatically

Commands:
  menu                         Open the menu (same as no arguments)
  list                         List sites: status, HTTP/HTTPS, static or proxy, certificate expiry
  add <domain>                 Add a static site
  proxy <domain> <backend>     Reverse proxy a site; backend is 3000, 127.0.0.1:3000 or a
                               full http(s):// URL (add --no-websocket to omit WebSocket headers)
  ssl <domain>                 Enable HTTPS with the best certificate found for <domain>
  ssl <domain> --cert <file> --key <file>
                               Enable HTTPS with these files (copied, not renewed automatically)
  enable <domain>              Enable a site
  disable <domain>             Disable a site
  delete <domain>              Delete a site (type 'yes' to confirm; a backup is kept)
  logs <domain> [lines]        Show access and error logs (default: 50 lines)
  test                         Test the Nginx configuration
  reload                       Test the configuration, then reload Nginx
  reload-if-renewed            Reload Nginx if the acme container renewed a certificate
                               (for host cron, e.g. */15 * * * *)
  help                         Show this help

Every configuration change is checked with "nginx -t"; on failure the previous
configuration is restored and Nginx is not reloaded.

Configuration (environment variables or ./site_manager.conf):
  NGINX_MODE         docker|native (default: auto-detected, container "nginx" first)
  NGINX_ROOT         Docker Nginx host directory: conf.d, html, logs, certs (default: /opt/nginx)
  NGINX_CONTAINER    Docker Nginx container name (default: nginx)
  NATIVE_NGINX_DIR   Native Nginx directory (default: /etc/nginx)
  NATIVE_WEB_ROOT    Native document root (default: /var/www)
  NATIVE_LOG_DIR     Native log directory (default: /var/log/nginx)
  ACME_HOME          Native acme.sh home (default: ~/.acme.sh, as in acme_manage.sh)
  ACME_SH_PATH       Native acme.sh binary (default: $ACME_HOME/acme.sh)
  ACME_CONTAINER     Docker acme.sh container name (default: acme)
  ACME_DOCKER_DATA   Host directory of the container's /acme.sh, used when the
                     container cannot be inspected (default: /opt/acme/data)
  ACME_RELOAD_CMD    Command acme.sh runs after installing/renewing a certificate
  CERTBOT_LIVE_DIR   certbot live directory (default: /etc/letsencrypt/live)
  CERTBOT_HOOK_DIR   certbot deploy hooks (default: /etc/letsencrypt/renewal-hooks/deploy)
  ACME_MANAGE_SH     Path to acme_manage.sh (default: next to this script or in PATH)
HELP
}

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------

# Portable lowercase (bash 3.2 has no ${var,,})
to_lower() {
    printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

trim() {
    local s=${1:-}
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Exit unless a mode variable holds a supported value
validate_mode() {
    case $2 in
        docker | native) ;;
        *) die "Invalid $1: '$2' (expected docker or native)" ;;
    esac
}

# Plain host names only: domains end up in file paths (including rm -rf) and
# in generated Nginx configuration.
is_valid_domain() {
    local re='^[A-Za-z0-9]([A-Za-z0-9_.-]*[A-Za-z0-9])?$'
    [[ $1 =~ $re ]] && [[ $1 != *..* ]]
}

validate_domain() {
    if ! is_valid_domain "$1"; then
        die "Invalid domain: $1"
    fi
}

# Proxy backends must be http(s) URLs without characters that could break the config
validate_backend() {
    case $1 in
        http://?* | https://?*) ;;
        *) die "Invalid backend URL: $1 (must start with http:// or https://)" ;;
    esac
    case $1 in
        *[[:space:]]* | *[\;{}]* | *[\"\']*) die "Invalid backend URL: $1" ;;
    esac
}

# Turn "3000", "127.0.0.1:3000", "localhost:8080" or a full URL into a URL;
# prints nothing and returns 1 for input that cannot be a backend.
normalize_backend() {
    local input port
    input="$(trim "${1:-}")"
    case $input in
        "") return 1 ;;
        http://* | https://*)
            echo "$input"
            return 0
            ;;
        *://*) return 1 ;;
    esac
    if [[ $input =~ ^[0-9]+$ ]]; then
        port=$input
        input="127.0.0.1:$port"
    else
        port=${input##*:}
        if [ "$port" = "$input" ] || [[ ! $port =~ ^[0-9]+$ ]]; then
            return 1
        fi
    fi
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        return 1
    fi
    echo "http://$input"
}

# True if a running container has exactly this name
container_running() {
    local names
    names="$(docker ps --format '{{.Names}}' 2>/dev/null || true)"
    case $'\n'"$names"$'\n' in
        *$'\n'"$1"$'\n'*) return 0 ;;
    esac
    return 1
}

# Run a command with root privileges when managing native Nginx
run_priv() {
    if [ "$NGINX_MODE" = "native" ] && [ "$(id -u)" -ne 0 ]; then
        sudo "$@"
    else
        "$@"
    fi
}

# Run a command as root regardless of the Nginx mode (system paths such as /etc/letsencrypt)
run_root() {
    if [ "$(id -u)" -ne 0 ]; then
        sudo "$@"
    else
        "$@"
    fi
}

# Write stdin to a file (with root privileges for native Nginx)
write_file() {
    run_priv tee "$1" >/dev/null
}

# True if <path> lies inside <dir>
path_under() {
    case $1 in
        *..*) return 1 ;;
        "${2%/}"/*) return 0 ;;
    esac
    return 1
}

# True if both paths name the same directory
same_dir() {
    local a b
    a="$(cd "$1" 2>/dev/null && pwd -P)" || a="${1%/}"
    b="$(cd "$2" 2>/dev/null && pwd -P)" || b="${2%/}"
    [ "$a" = "$b" ]
}

# ---------------------------------------------------------------------------
# Prompts. They read from stdin; end of input cancels the current action
# instead of looping forever.
# ---------------------------------------------------------------------------

# ask <var> <prompt> [default]
ask() {
    local reply="" prompt=$2 default=${3:-}
    if [ -n "$default" ]; then
        prompt="$prompt [$default]"
    fi
    # A last line without a newline still counts as an answer
    if ! IFS= read -r -p "$prompt: " reply && [ -z "$reply" ]; then
        echo
        die "No input, cancelled"
    fi
    reply="$(trim "$reply")"
    if [ -z "$reply" ]; then
        reply=$default
    fi
    printf -v "$1" '%s' "$reply"
}

# confirm <prompt> <y|n default>
confirm() {
    local answer hint="y/N"
    if [ "${2:-n}" = "y" ]; then
        hint="Y/n"
    fi
    while true; do
        ask answer "$1 ($hint)"
        case "$(to_lower "$answer")" in
            "") [ "${2:-n}" = "y" ] && return 0 || return 1 ;;
            y | yes) return 0 ;;
            n | no) return 1 ;;
            *) print_error "Please answer y or n" ;;
        esac
    done
}

# Wait for Enter so the result stays on screen (only when a person is typing)
pause() {
    local key
    if [ -t 0 ]; then
        read -r -p "Press Enter to return to the menu..." key || true
    fi
}

# ---------------------------------------------------------------------------
# Mode-aware paths
# ---------------------------------------------------------------------------

# Host filesystem path for: conf | enabled | web | log | cert | backup
site_path() {
    if [ "$NGINX_MODE" = "docker" ]; then
        case $1 in
            conf | enabled) echo "$NGINX_ROOT/conf.d" ;;
            web) echo "$NGINX_ROOT/html" ;;
            log) echo "$NGINX_ROOT/logs" ;;
            cert) echo "$NGINX_ROOT/certs" ;;
            backup) echo "$NGINX_ROOT/backups" ;;
            *) return 1 ;;
        esac
    else
        case $1 in
            conf) echo "$NATIVE_NGINX_DIR/sites-available" ;;
            enabled) echo "$NATIVE_NGINX_DIR/sites-enabled" ;;
            web) echo "$NATIVE_WEB_ROOT" ;;
            log) echo "$NATIVE_LOG_DIR" ;;
            cert) echo "$NATIVE_NGINX_DIR/certs" ;;
            backup) echo "$NATIVE_NGINX_DIR/backups" ;;
            *) return 1 ;;
        esac
    fi
}

# The same locations as seen by the Nginx process (used in generated configs): web | log | cert
nginx_path() {
    if [ "$NGINX_MODE" = "docker" ]; then
        case $1 in
            web) echo "/var/www" ;;
            log) echo "/var/log/nginx" ;;
            cert) echo "/etc/nginx/certs" ;;
            *) return 1 ;;
        esac
    else
        case $1 in
            web | log | cert) site_path "$1" ;;
            *) return 1 ;;
        esac
    fi
}

# Certificate path as Nginx sees it. Docker Nginx only sees the mounted cert
# directory, so anything outside it cannot be referenced (returns 1).
host_to_nginx_cert_path() {
    if [ "$NGINX_MODE" = "docker" ]; then
        path_under "$1" "$(site_path cert)" || return 1
        echo "$(nginx_path cert)/${1#"$(site_path cert)"/}"
    else
        echo "$1"
    fi
}

# Host path of a certificate path taken from a config file
nginx_to_host_cert_path() {
    if [ "$NGINX_MODE" = "docker" ] && path_under "$1" "$(nginx_path cert)"; then
        echo "$(site_path cert)/${1#"$(nginx_path cert)"/}"
    else
        echo "$1"
    fi
}

# Site configuration file (in Docker mode a disabled site is "<file>.disabled")
site_conf_file() {
    echo "$(site_path conf)/$1.conf"
}

# Native mode: symlink in sites-enabled that activates the site
site_enabled_link() {
    echo "$(site_path enabled)/$1.conf"
}

# True if a configuration exists for the site, enabled or not
site_exists() {
    local conf
    conf="$(site_conf_file "$1")"
    [ -f "$conf" ] || [ -f "$conf.disabled" ]
}

# The site's configuration file, wherever it currently is
site_conf_any() {
    local conf
    conf="$(site_conf_file "$1")"
    if [ ! -f "$conf" ] && [ -f "$conf.disabled" ]; then
        conf="$conf.disabled"
    fi
    echo "$conf"
}

is_site_enabled() {
    if [ "$NGINX_MODE" = "docker" ]; then
        [ -f "$(site_conf_file "$1")" ]
    else
        [ -f "$(site_conf_file "$1")" ] && [ -e "$(site_enabled_link "$1")" ]
    fi
}

# Print the first value of an Nginx directive in a config file
conf_directive() {
    sed -n "s/^[[:space:]]*$2[[:space:]]\{1,\}\([^;]*\);.*/\1/p" "$1" 2>/dev/null | sed -n '1p'
}

# Print the proxy_pass target of a config file (empty if it is not a proxy)
get_proxy_backend() { conf_directive "$1" proxy_pass; }

# Print the server_name list of a config file
get_server_names() { conf_directive "$1" server_name; }

get_ssl_cert() { conf_directive "$1" ssl_certificate; }

get_ssl_key() { conf_directive "$1" ssl_certificate_key; }

is_https_conf() {
    grep -q 'listen 443 ssl' "$1" 2>/dev/null
}

has_websocket() {
    grep -q 'proxy_set_header Upgrade' "$1" 2>/dev/null
}

# Text after "# SSL Certificate" (where the certificate came from), kept when re-rendering
get_cert_note() {
    sed -n 's/^[[:space:]]*# SSL Certificate\(.*\)$/\1/p' "$1" 2>/dev/null | sed -n '1p'
}

# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------

# Detect Nginx mode (docker or native)
detect_nginx_mode() {
    if [ -n "$NGINX_MODE" ]; then
        validate_mode NGINX_MODE "$NGINX_MODE"
        return 0 # Already detected
    fi

    # Check Docker Nginx first
    if container_running "$NGINX_CONTAINER"; then
        NGINX_MODE="docker"
        print_info "Using Nginx (Docker mode)"
        return 0
    fi

    # Check native Nginx installation
    if command -v nginx >/dev/null 2>&1; then
        NGINX_MODE="native"
        print_info "Using Nginx (Native mode)"
        return 0
    fi

    # No Nginx found
    print_error "Nginx not found!"
    echo ""
    echo "Would you like to install Nginx now?"
    echo ""
    echo "1) Docker Nginx (recommended, isolated)"
    echo "2) Native Nginx Stable (system-wide installation)"
    echo "3) Cancel"
    echo ""
    local nginx_choice=""
    read -r -p "Select [1-3]: " nginx_choice || true

    case $nginx_choice in
        1)
            print_info "Please install Docker Nginx manually using docker-compose"
            echo ""
            echo "Example docker-compose.yml:"
            echo "services:"
            echo "  nginx:"
            echo "    image: nginx:stable-alpine"
            echo "    container_name: nginx"
            echo "    ports:"
            echo "      - 80:80"
            echo "      - 443:443"
            echo "    volumes:"
            echo "      - $NGINX_ROOT/conf.d:/etc/nginx/conf.d"
            echo "      - $NGINX_ROOT/html:/var/www"
            echo "      - $NGINX_ROOT/logs:/var/log/nginx"
            echo "      - $NGINX_ROOT/certs:/etc/nginx/certs"
            echo ""
            exit 1
            ;;
        2)
            install_native_nginx
            ;;
        3)
            print_info "Cancelled"
            exit 0
            ;;
        *)
            die "Invalid choice"
            ;;
    esac
}

# Install native Nginx (stable version)
install_native_nginx() {
    print_info "Installing Nginx Stable..."

    local os
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        os=${ID:-}
    else
        die "Cannot detect OS"
    fi

    case $os in
        ubuntu | debian)
            print_info "Detected: $os"
            sudo apt update
            sudo apt install -y curl gnupg2 ca-certificates lsb-release

            # Import signing key
            curl -fsSL https://nginx.org/keys/nginx_signing.key \
                | sudo gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg

            # Add Nginx official repository
            echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
http://nginx.org/packages/$os $(lsb_release -cs) nginx" \
                | sudo tee /etc/apt/sources.list.d/nginx.list

            sudo apt update
            sudo apt install -y nginx
            ;;

        centos | rhel | fedora)
            print_info "Detected: $os"
            sudo yum install -y yum-utils

            cat <<EOF | sudo tee /etc/yum.repos.d/nginx.repo
[nginx-stable]
name=nginx stable repo
baseurl=http://nginx.org/packages/centos/\$releasever/\$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
EOF

            sudo yum install -y nginx
            ;;

        *)
            print_info "Please install Nginx manually"
            die "Unsupported OS: $os"
            ;;
    esac

    sudo systemctl start nginx
    sudo systemctl enable nginx

    NGINX_MODE="native"

    # Create standard directory structure
    sudo mkdir -p "$(site_path conf)" "$(site_path enabled)" "$(site_path web)" "$(site_path cert)"

    # Backup original nginx.conf
    sudo cp "$NATIVE_NGINX_DIR/nginx.conf" "$NATIVE_NGINX_DIR/nginx.conf.bak"

    # Add include for sites-enabled if not exists
    if ! grep -q "sites-enabled" "$NATIVE_NGINX_DIR/nginx.conf"; then
        sudo sed -i "/http {/a \\    include $(site_path enabled)/*.conf;" "$NATIVE_NGINX_DIR/nginx.conf"
    fi

    sudo systemctl restart nginx

    print_success "Nginx Stable installed successfully!"
    nginx -v
    echo ""
    print_info "Directory structure:"
    echo "  Config:  $(site_path conf)/"
    echo "  Enabled: $(site_path enabled)/"
    echo "  Sites:   $(site_path web)/"
    echo "  Logs:    $(site_path log)/"
    echo "  Certs:   $(site_path cert)/"
}

# ---------------------------------------------------------------------------
# Nginx control
# ---------------------------------------------------------------------------

# True when native Nginx is managed by systemd. Without systemd (containers,
# minimal hosts) the master process is checked and signalled directly.
# NGINX_SYSTEMD=1/0 forces the choice (auto-detected by default).
nginx_uses_systemd() {
    case "${NGINX_SYSTEMD:-auto}" in
        1 | yes | true) return 0 ;;
        0 | no | false) return 1 ;;
    esac
    [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1
}

# Reload command for native Nginx, run as root.
native_reload_cmd() {
    if nginx_uses_systemd; then
        echo "systemctl reload nginx"
    else
        echo "nginx -s reload"
    fi
}

nginx_running() {
    if [ "$NGINX_MODE" = "docker" ]; then
        container_running "$NGINX_CONTAINER"
    elif nginx_uses_systemd; then
        systemctl is-active --quiet nginx
    else
        pgrep -x nginx >/dev/null 2>&1
    fi
}

# Exit unless Nginx is running
check_nginx_running() {
    detect_nginx_mode
    if nginx_running; then
        return 0
    fi
    if [ "$NGINX_MODE" = "docker" ]; then
        die "Nginx container '$NGINX_CONTAINER' is not running!"
    fi
    if nginx_uses_systemd; then
        echo "Start it with: sudo systemctl start nginx"
    else
        echo "Start it with: sudo nginx"
    fi
    die "Nginx service is not running!"
}

# Test Nginx configuration
test_nginx() {
    detect_nginx_mode
    print_info "Testing Nginx configuration..."

    local rc=0
    if [ "$NGINX_MODE" = "docker" ]; then
        docker exec "$NGINX_CONTAINER" nginx -t 2>&1 || rc=$?
    else
        run_priv nginx -t 2>&1 || rc=$?
    fi

    if [ "$rc" -eq 0 ]; then
        print_success "Configuration syntax is correct"
        return 0
    fi
    print_error "Configuration syntax error!"
    return 1
}

# Reload the running Nginx without testing first; exits on failure
reload_service() {
    print_info "Reloading Nginx..."
    local rc=0
    if [ "$NGINX_MODE" = "docker" ]; then
        docker exec "$NGINX_CONTAINER" nginx -s reload || rc=$?
    else
        # shellcheck disable=SC2046 # the command is two plain words
        run_priv $(native_reload_cmd) || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        die "Nginx reload failed"
    fi
    print_success "Nginx reloaded"
}

# Test, then reload Nginx
reload_nginx() {
    if ! test_nginx; then
        die "Configuration test failed, not reloaded"
    fi
    reload_service
}

# Test the configuration, then reload. If the test fails, run the given
# rollback command so the broken change is not left on disk, and exit.
commit_or_rollback() {
    if ! test_nginx; then
        print_error "Configuration test failed, changes rolled back, Nginx not reloaded"
        "$@"
        exit 1
    fi
    reload_service
}

# Rollback helper for apply_site_config: <conf> <backup|""> <link|"">
restore_site_config() {
    if [ -n "$2" ]; then
        write_file "$1" <"$2"
    else
        run_priv rm -f "$1"
    fi
    if [ -n "$3" ]; then
        run_priv rm -f "$3"
    fi
}

# Usage: apply_site_config <domain> <render-function> [args...]
# Writes the rendered config, enables the site and reloads Nginx. If
# "nginx -t" fails the previous config is restored (or the new one removed),
# so a broken file never lingers to break the next Nginx restart.
apply_site_config() {
    local domain=$1
    shift

    local conf backup="" new_link="" rc=0
    conf="$(site_conf_file "$domain")"
    run_priv mkdir -p "$(site_path conf)" "$(site_path enabled)"

    if [ -f "$conf" ]; then
        backup="$(mktemp "${TMPDIR:-/tmp}/site_manager.XXXXXX")" || die "Cannot create backup file"
        if ! cat "$conf" >"$backup"; then
            rm -f "$backup"
            die "Cannot back up $conf"
        fi
    fi

    if ! "$@" | write_file "$conf"; then
        if [ -n "$backup" ]; then
            restore_site_config "$conf" "$backup" ""
            rm -f "$backup"
        fi
        die "Failed to write $conf"
    fi

    # Native Nginx only loads sites linked into sites-enabled
    if [ "$NGINX_MODE" = "native" ]; then
        local link
        link="$(site_enabled_link "$domain")"
        if [ ! -e "$link" ]; then
            run_priv ln -sf "$conf" "$link"
            new_link="$link"
        fi
    fi

    if ! test_nginx; then
        print_error "Configuration test failed, restoring previous configuration"
        restore_site_config "$conf" "$backup" "$new_link"
        rc=1
    fi
    if [ -n "$backup" ]; then
        rm -f "$backup"
    fi
    if [ "$rc" -ne 0 ]; then
        exit 1
    fi
    reload_service
}

# ---------------------------------------------------------------------------
# Templates (all output goes to stdout)
# ---------------------------------------------------------------------------

render_index_page() {
    cat <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome to $1</title>
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            max-width: 800px;
            margin: 100px auto;
            padding: 20px;
            text-align: center;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
        }
        .container {
            background: rgba(255, 255, 255, 0.1);
            padding: 40px;
            border-radius: 10px;
            backdrop-filter: blur(10px);
        }
        h1 { font-size: 3em; margin-bottom: 20px; }
        p { font-size: 1.2em; line-height: 1.6; }
        .status { color: #90EE90; font-weight: bold; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🚀 Welcome to $1</h1>
        <p class="status">✓ Site is running successfully!</p>
    </div>
</body>
</html>
HTML
}

# Port 80 must keep serving HTTP-01 challenges so certificates can be renewed.
# <domain>
render_acme_location() {
    cat <<NGINX
    # ACME certificate validation path
    location ^~ /.well-known/acme-challenge/ {
        root $(nginx_path web)/$1;
        try_files \$uri =404;
    }
NGINX
}

# <backend> <websocket yes|no>
render_proxy_location() {
    local websocket=""
    if [ "${2:-yes}" = "yes" ]; then
        websocket="
        # WebSocket support
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
"
    fi
    cat <<NGINX
    # Reverse Proxy Settings
    location / {
        proxy_pass $1;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
$websocket
        # Timeout settings
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
NGINX
}

# <domain>
render_static_location() {
    cat <<NGINX
    root $(nginx_path web)/$1;
    index index.html index.htm index.php;
NGINX
}

# <domain>
render_log_lines() {
    cat <<NGINX
    # Logs
    access_log $(nginx_path log)/$1/access.log;
    error_log $(nginx_path log)/$1/error.log;
NGINX
}

# HTTP-only static site: <domain> <server_names>
render_http_site() {
    cat <<NGINX
# HTTP Configuration
server {
    listen 80;
    listen [::]:80;
    server_name $2;

$(render_static_location "$1")

$(render_acme_location "$1")

    # Temporary HTTP access (redirects to HTTPS once a certificate is attached)
    location / {
        try_files \$uri \$uri/ =404;
    }

$(render_log_lines "$1")
}
NGINX
}

# HTTP-only reverse proxy: <domain> <server_names> <backend> <websocket>
render_http_proxy() {
    cat <<NGINX
# HTTP Reverse Proxy Configuration
server {
    listen 80;
    listen [::]:80;
    server_name $2;

$(render_acme_location "$1")

$(render_proxy_location "$3" "$4")

$(render_log_lines "$1")
}
NGINX
}

# HTTPS site (static, or reverse proxy when a backend is given):
# <domain> <server_names> <certificate> <key> [backend] [websocket] [certificate note]
# True when version $1 >= $2 (dotted numbers).
version_at_least() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        split(a, x, "."); split(b, y, ".")
        for (i = 1; i <= 3; i++) {
            if ((x[i] + 0) > (y[i] + 0)) exit 0
            if ((x[i] + 0) < (y[i] + 0)) exit 1
        }
        exit 0
    }'
}

# The standalone "http2 on;" directive exists since nginx 1.25.1; older
# releases (Debian 12 ships 1.22, Ubuntu 22.04 1.18) reject it and need
# "listen ... ssl http2". The old form still works (deprecated) on newer
# nginx, so it is also the fallback when the version cannot be read.
render_https_listen() {
    local version
    if [ "$NGINX_MODE" = "docker" ]; then
        version=$(docker exec "$NGINX_CONTAINER" nginx -v 2>&1 || true)
    else
        version=$(run_priv nginx -v 2>&1 || true)
    fi
    version=$(printf '%s\n' "$version" | sed -n 's|.*nginx/\([0-9][0-9.]*\).*|\1|p' | head -n 1)
    if [ -n "$version" ] && version_at_least "$version" 1.25.1; then
        printf '    listen 443 ssl;\n    listen [::]:443 ssl;\n    http2 on;\n'
    else
        printf '    listen 443 ssl http2;\n    listen [::]:443 ssl http2;\n'
    fi
}

render_https_config() {
    local domain=$1 server_names=$2 cert=$3 key=$4 backend=${5:-} websocket=${6:-yes} note=${7:-}
    local title="HTTPS Configuration" content
    if [ -n "$backend" ]; then
        title="HTTPS Reverse Proxy Configuration"
        content="$(render_proxy_location "$backend" "$websocket")"
    else
        content="$(render_static_location "$domain")

    location / {
        try_files \$uri \$uri/ =404;
    }"
    fi

    cat <<NGINX
# HTTP Configuration (redirect to HTTPS)
server {
    listen 80;
    listen [::]:80;
    server_name $server_names;

$(render_acme_location "$domain")

    # Redirect to HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }

$(render_log_lines "$domain")
}

# $title
server {
$(render_https_listen)
    server_name $server_names;

    # SSL Certificate$note
    ssl_certificate $cert;
    ssl_certificate_key $key;

    # SSL Optimization
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # Security Headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

$content

$(render_log_lines "$domain")
}
NGINX
}

# certbot deploy hook: <lineage name> <reload command> [<copy dir> <key file name>]
# certbot runs every deploy hook for every renewed lineage, so the hook
# checks that the renewed lineage is its own before doing anything.
render_certbot_hook() {
    local copy=""
    if [ -n "${3:-}" ]; then
        copy="install -m 644 \"\$RENEWED_LINEAGE/fullchain.pem\" \"$3/fullchain.cer\"
install -m 600 \"\$RENEWED_LINEAGE/privkey.pem\" \"$3/$4\"
"
    fi
    cat <<HOOK
#!/bin/sh
# Generated by site_manager.sh: deploy the renewed "$1" certificate to Nginx.
set -e
[ "\${RENEWED_LINEAGE##*/}" = "$1" ] || exit 0
${copy}$2
HOOK
}

# ---------------------------------------------------------------------------
# Certificates: inspection
# ---------------------------------------------------------------------------

# DNS names of a certificate from "openssl x509 -text" output (the CN only when
# there is no subjectAltName), lowercased, one per line.
cert_names_from_text() {
    awk '
        san {
            n = split($0, parts, ",")
            for (i = 1; i <= n; i++) {
                name = parts[i]
                gsub(/^[ \t]+|[ \t]+$/, "", name)
                if (name ~ /^DNS:/) print tolower(substr(name, 5))
            }
            san = 0
            found = 1
        }
        /X509v3 Subject Alternative Name/ { san = 1 }
        /^[ \t]*Subject:/ && cn == "" {
            if (match($0, /CN[ ]?=[ ]?[^,\/]+/)) {
                cn = substr($0, RSTART, RLENGTH)
                sub(/^CN[ ]?=[ ]?/, "", cn)
            }
        }
        END { if (!found && cn != "") print tolower(cn) }
    ' <<<"$1"
}

# Prints "exact" or "wildcard" if one of the names covers <domain>, else returns 1.
# A wildcard covers exactly one label, as in TLS.
name_match() {
    local domain=$1 parent result="" name
    parent=${domain#*.}
    while IFS= read -r name; do
        if [ "$name" = "$domain" ]; then
            echo "exact"
            return 0
        fi
        if [ "$parent" != "$domain" ] && [[ $parent == *.* ]] && [ "$name" = "*.$parent" ]; then
            result="wildcard"
        fi
    done <<<"$2"
    if [ -n "$result" ]; then
        echo "$result"
        return 0
    fi
    return 1
}

# Organisation (or common name) of an "issuer=..." line; handles both the
# OpenSSL ("O = X, CN = Y") and LibreSSL ("/O=X/CN=Y") formats.
issuer_label() {
    local s=",${1#issuer=}" value
    value="$(sed -n 's|.*[,/][[:space:]]*O[[:space:]]*=[[:space:]]*\([^,/]*\).*|\1|p' <<<"$s")"
    if [ -z "$value" ]; then
        value="$(sed -n 's|.*[,/][[:space:]]*CN[[:space:]]*=[[:space:]]*\([^,/]*\).*|\1|p' <<<"$s")"
    fi
    value="$(trim "$value")"
    echo "${value:--}"
}

# "notAfter=Nov  8 05:05:36 2026 GMT" -> "20261108050536<TAB>2026-11-08"
# (a sortable key without GNU/BSD date differences, and a display date)
parse_enddate() {
    awk '{
        sub(/^notAfter=/, "")
        m = index("JanFebMarAprMayJunJulAugSepOctNovDec", $1)
        mon = (m + 2) / 3
        split($3, t, ":")
        printf "%04d%02d%02d%s%s%s\t%04d-%02d-%02d\n", $4, mon, $2, t[1], t[2], t[3], $4, mon, $2
    }' <<<"$1"
}

# cert_check <certificate file> <domain>
# Prints "match<TAB>sortkey<TAB>expiry<TAB>fingerprint<TAB>issuer" when the
# certificate covers <domain> and has not expired. Returns 1 when it cannot be
# read or does not cover the domain, 2 when it has expired.
cert_check() {
    local file=$1 domain=$2 text match line enddate="" issuer="" fingerprint="" dates
    [ -r "$file" ] || return 1
    text="$(openssl x509 -in "$file" -noout -text 2>/dev/null)" || return 1
    match="$(name_match "$domain" "$(cert_names_from_text "$text")")" || return 1
    if ! openssl x509 -in "$file" -noout -checkend 0 >/dev/null 2>&1; then
        return 2
    fi
    text="$(openssl x509 -in "$file" -noout -enddate -issuer -fingerprint -sha256 2>/dev/null)" || return 1
    while IFS= read -r line; do
        case $line in
            notAfter=*) enddate=$line ;;
            issuer=*) issuer="$(issuer_label "$line")" ;;
            *[Ff]ingerprint=*) fingerprint=${line#*=} ;;
        esac
    done <<<"$text"
    dates="$(parse_enddate "$enddate")"
    printf '%s\t%s\t%s\t%s\n' "$match" "$dates" "${fingerprint:--}" "${issuer:--}"
}

# One-line summary for the site list: "expires 2026-11-08, Let's Encrypt"
cert_summary() {
    local file=$1 text line enddate="" issuer="" dates
    if [ ! -r "$file" ]; then
        echo "certificate not readable"
        return 0
    fi
    text="$(openssl x509 -in "$file" -noout -enddate -issuer 2>/dev/null)" || {
        echo "invalid certificate"
        return 0
    }
    while IFS= read -r line; do
        case $line in
            notAfter=*) enddate=$line ;;
            issuer=*) issuer="$(issuer_label "$line")" ;;
        esac
    done <<<"$text"
    dates="$(parse_enddate "$enddate")"
    if openssl x509 -in "$file" -noout -checkend 0 >/dev/null 2>&1; then
        echo "expires ${dates#*"$TAB"}, $issuer"
    else
        echo "EXPIRED ${dates#*"$TAB"}, $issuer"
    fi
}

# Names a certificate file covers, for checking a site's server_name list
cert_names_of_file() {
    local text
    text="$(openssl x509 -in "$1" -noout -text 2>/dev/null)" || return 0
    cert_names_from_text "$text"
}

# Warn about server names the certificate does not cover (e.g. www.<domain>)
warn_uncovered_names() {
    local cert=$1 covered name
    local -a names
    # read -a splits without glob expansion (server names may be *.example.com)
    read -r -a names <<<"$2"
    covered="$(cert_names_of_file "$cert")"
    for name in ${names[@]+"${names[@]}"}; do
        if ! name_match "$(to_lower "$name")" "$covered" >/dev/null; then
            print_warning "The certificate does not cover $name; browsers will reject HTTPS for it"
        fi
    done
}

# ---------------------------------------------------------------------------
# Certificates: discovery
# ---------------------------------------------------------------------------

# Candidates for one domain, best first (filled by discover_certificates).
# Sources: acme (native acme.sh), acme-docker, certbot, installed.
C_SRC=()
C_NAME=()
C_DIR=()
C_CERT=()
C_KEY=()
C_ECC=()
C_MATCH=()
C_EXPIRY=()
C_ISSUER=()
DISCOVER_DOMAIN=""
DISCOVER_LINES=""
DISCOVER_EXPIRED=0
DISCOVER_HINT=""

# consider_certificate <rank> <source> <name> <dir> <cert> <key> <ecc 0|1>
consider_certificate() {
    local info="" rc=0 match sortkey expiry fingerprint issuer mrank=0
    info="$(cert_check "$5" "$DISCOVER_DOMAIN")" || rc=$?
    if [ "$rc" -eq 2 ]; then
        DISCOVER_EXPIRED=$((DISCOVER_EXPIRED + 1))
        return 0
    fi
    if [ "$rc" -ne 0 ]; then
        return 0
    fi
    IFS="$TAB" read -r match sortkey expiry fingerprint issuer <<<"$info"
    if [ "$match" = "wildcard" ]; then
        mrank=1
    fi
    DISCOVER_LINES+="$1$mrank$TAB$sortkey$TAB$2$TAB$3$TAB$4$TAB$5$TAB$6$TAB$7$TAB$match$TAB$expiry$TAB$fingerprint$TAB$issuer"$'\n'
}

# acme.sh keeps each certificate in <home>/<main domain>[_ecc]/ with
# fullchain.cer and <main domain>.key; every directory is checked by SAN, so
# certificates whose SAN list (not name) covers the domain are found too.
scan_acme_dir() { # <source> <acme home>
    local d base main ecc
    for d in "$2"/*/; do
        d=${d%/}
        base=${d##*/}
        main=${base%_ecc}
        ecc=0
        if [ "$main" != "$base" ]; then
            ecc=1
        fi
        if [ -f "$d/fullchain.cer" ] && [ -e "$d/$main.key" ]; then
            consider_certificate 1 "$1" "$main" "$d" "$d/fullchain.cer" "$d/$main.key" "$ecc"
        fi
    done
}

scan_certbot_dir() {
    local d
    if [ -d "$CERTBOT_LIVE_DIR" ] && [ ! -x "$CERTBOT_LIVE_DIR" ]; then
        DISCOVER_HINT="$CERTBOT_LIVE_DIR is not readable; run as root to include certbot certificates"
        return 0
    fi
    for d in "$CERTBOT_LIVE_DIR"/*/; do
        d=${d%/}
        if [ -f "$d/fullchain.pem" ] && [ -e "$d/privkey.pem" ]; then
            consider_certificate 2 certbot "${d##*/}" "$d" "$d/fullchain.pem" "$d/privkey.pem" 0
        fi
    done
}

# Certificates already in this tool's cert directory (any layout it ever used)
scan_installed_dir() {
    local d name cert key
    for d in "$(site_path cert)"/*/; do
        d=${d%/}
        name=${d##*/}
        cert=""
        key=""
        if [ -f "$d/fullchain.cer" ]; then
            cert="$d/fullchain.cer"
        elif [ -f "$d/fullchain.pem" ]; then
            cert="$d/fullchain.pem"
        fi
        if [ -f "$d/$name.key" ]; then
            key="$d/$name.key"
        elif [ -f "$d/privkey.pem" ]; then
            key="$d/privkey.pem"
        fi
        if [ -n "$cert" ] && [ -n "$key" ]; then
            consider_certificate 3 installed "$name" "$d" "$cert" "$key" 0
        fi
    done
}

acme_container_exists() {
    command -v docker >/dev/null 2>&1 \
        && docker inspect --type container "$ACME_CONTAINER" >/dev/null 2>&1
}

# Host directory mounted at <destination> in the acme container (empty if unknown)
acme_container_mount() {
    local format="{{range .Mounts}}{{if eq .Destination \"$1\"}}{{.Source}}{{end}}{{end}}"
    command -v docker >/dev/null 2>&1 || return 0
    docker inspect --type container -f "$format" "$ACME_CONTAINER" 2>/dev/null || true
}

# Host directory with the acme container's acme.sh data (empty if none)
acme_docker_data_dir() {
    local mount
    mount="$(acme_container_mount /acme.sh)"
    if [ -n "$mount" ]; then
        echo "$mount"
    elif [ -d "$ACME_DOCKER_DATA" ]; then
        echo "$ACME_DOCKER_DATA"
    fi
}

# Host directory behind the acme container's /certs (docker-compose default:
# /opt/nginx/certs, the Docker Nginx cert directory)
acme_docker_certs_dir() {
    local mount
    mount="$(acme_container_mount /certs)"
    echo "${mount:-$NGINX_ROOT/certs}"
}

# Fill the C_* arrays with usable certificates for <domain>, best first:
# renewable sources (acme.sh, certbot) before installed copies, exact names
# before wildcards, later expiry first. Copies of the same certificate are
# listed once, under the best source.
discover_certificates() {
    local native_home docker_data sorted seen=" "
    local _rank _sortkey src name dir cert key ecc match expiry fingerprint issuer
    DISCOVER_DOMAIN="$(to_lower "$1")"
    DISCOVER_LINES=""
    DISCOVER_EXPIRED=0
    DISCOVER_HINT=""
    C_SRC=()
    C_NAME=()
    C_DIR=()
    C_CERT=()
    C_KEY=()
    C_ECC=()
    C_MATCH=()
    C_EXPIRY=()
    C_ISSUER=()

    native_home=${ACME_HOME%/}
    docker_data="$(acme_docker_data_dir)"
    # One directory used by both: attribute it to whichever can install it
    if [ -n "$docker_data" ] && same_dir "$docker_data" "$native_home"; then
        if acme_container_exists; then
            native_home=""
        else
            docker_data=""
        fi
    fi
    if [ -n "$native_home" ]; then
        scan_acme_dir acme "$native_home"
    fi
    if [ -n "$docker_data" ]; then
        scan_acme_dir acme-docker "$docker_data"
    fi
    scan_certbot_dir
    scan_installed_dir

    sorted="$(printf '%s' "$DISCOVER_LINES" | sort -t "$TAB" -k1,1 -k2,2r)"
    while IFS="$TAB" read -r _rank _sortkey src name dir cert key ecc match expiry fingerprint issuer; do
        if [ -z "$src" ]; then
            continue
        fi
        if [ "$fingerprint" != "-" ]; then
            case $seen in *" $fingerprint "*) continue ;; esac
            seen="$seen$fingerprint "
        fi
        C_SRC+=("$src")
        C_NAME+=("$name")
        C_DIR+=("$dir")
        C_CERT+=("$cert")
        C_KEY+=("$key")
        C_ECC+=("$ecc")
        C_MATCH+=("$match")
        C_EXPIRY+=("$expiry")
        C_ISSUER+=("$issuer")
    done <<<"$sorted"
}

source_label() {
    case $1 in
        acme) echo "acme.sh" ;;
        acme-docker) echo "acme.sh (docker)" ;;
        certbot) echo "certbot" ;;
        installed) echo "installed" ;;
        *) echo "$1" ;;
    esac
}

print_candidates() {
    local i name extra
    for ((i = 0; i < ${#C_SRC[@]}; i++)); do
        name=${C_NAME[i]}
        if [ "${C_ECC[i]}" = "1" ]; then
            name="$name (ECC)"
        fi
        extra=""
        if [ "${C_MATCH[i]}" = "wildcard" ]; then
            extra=" [wildcard]"
        fi
        printf '  %d) %-17s %-30s %-24s expires %s%s\n' "$((i + 1))" \
            "$(source_label "${C_SRC[i]}")" "$name" "${C_ISSUER[i]}" "${C_EXPIRY[i]}" "$extra"
        printf '     %s\n' "${C_CERT[i]}"
    done
}

# ---------------------------------------------------------------------------
# Certificates: attaching. Each attach_* function makes the certificate
# visible to Nginx and sets up renewal, then sets:
#   ATTACH_CERT / ATTACH_KEY  paths as Nginx sees them
#   ATTACH_HOST_CERT          host path of the certificate (for checks)
#   ATTACH_NOTE               comment for the config file
# ---------------------------------------------------------------------------

ATTACH_CERT=""
ATTACH_KEY=""
ATTACH_HOST_CERT=""
ATTACH_NOTE=""

# Directory name for a certificate inside the cert directory
cert_store_name() {
    local name=$1
    case $name in
        \*.*) name="wildcard.${name#\*.}" ;;
    esac
    printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_'
}

# Value of a variable in an acme.sh domain conf file (quotes removed)
acme_conf_value() {
    local line
    line="$(grep -m 1 "^$2=" "$1" 2>/dev/null || true)"
    line=${line#*=}
    line=${line#\'}
    line=${line%\'}
    line=${line#\"}
    line=${line%\"}
    echo "$line"
}

# Command acme.sh runs after installing or renewing a certificate: <native|docker>
acme_reload_cmd() {
    if [ -n "$ACME_RELOAD_CMD" ]; then
        echo "$ACME_RELOAD_CMD"
    elif [ "$1" = "docker" ]; then
        # The acme container has no access to Docker: leave a marker that the
        # host-side "reload-if-renewed" cron job picks up.
        echo "touch /certs/$RENEW_MARKER_NAME"
    elif [ "$NGINX_MODE" = "docker" ]; then
        echo "docker exec $NGINX_CONTAINER nginx -s reload"
    elif [ "$(id -u)" -eq 0 ]; then
        native_reload_cmd
    else
        echo "sudo -n $(native_reload_cmd)"
    fi
}

# Reload command for hooks that run as root (certbot)
root_reload_cmd() {
    if [ "$NGINX_MODE" = "docker" ]; then
        echo "docker exec $NGINX_CONTAINER nginx -s reload"
    else
        native_reload_cmd
    fi
}

find_acme_sh() {
    if [ -x "$ACME_SH_PATH" ]; then
        echo "$ACME_SH_PATH"
    elif command -v acme.sh >/dev/null 2>&1; then
        command -v acme.sh
    else
        return 1
    fi
}

# Remove links left by the old wildcard reuse so that acme.sh does not write
# through them into another certificate's files.
drop_symlinks() {
    local f
    for f in "$@"; do
        if [ -L "$f" ]; then
            run_priv rm -f "$f"
        fi
    done
}

# Deploy targets for an acme.sh certificate. acme.sh remembers one install
# target per certificate, so an existing target inside <cert root> is reused
# (other sites may already point at it); otherwise <cert root>/<store>/ is used.
# Prints "<fullchain><TAB><key>".
acme_install_targets() { # <acme domain dir> <main> <cert root>
    local conf old_chain old_key store
    conf="$1/$2.conf"
    old_chain="$(acme_conf_value "$conf" Le_RealFullChainPath)"
    old_key="$(acme_conf_value "$conf" Le_RealKeyPath)"
    if [ -n "$old_chain" ] && [ -n "$old_key" ] \
        && path_under "$old_chain" "$3" && path_under "$old_key" "$3"; then
        printf '%s\t%s\n' "$old_chain" "$old_key"
        return 0
    fi
    if [ -n "$old_chain" ]; then
        print_warning "acme.sh currently deploys $2 to $old_chain; it will deploy to $3 instead" >&2
    fi
    store="$(cert_store_name "$2")"
    printf '%s\t%s\n' "$3/$store/fullchain.cer" "$3/$store/$store.key"
}

attach_acme_native() { # <index>
    local i=$1 acme_bin main targets chain key reload
    local -a args
    main=${C_NAME[i]}
    acme_bin="$(find_acme_sh)" || die "acme.sh not found (looked at $ACME_SH_PATH and PATH)"

    targets="$(acme_install_targets "${C_DIR[i]}" "$main" "$(site_path cert)")"
    chain=${targets%%"$TAB"*}
    key=${targets#*"$TAB"}
    run_priv mkdir -p "$(dirname "$chain")" "$(dirname "$key")"
    drop_symlinks "$chain" "$key"

    reload="$(acme_reload_cmd native)"
    args=(--install-cert -d "$main")
    if [ "${C_ECC[i]}" = "1" ]; then
        args+=(--ecc)
    fi
    args+=(--key-file "$key" --fullchain-file "$chain" --reloadcmd "$reload")
    if [ "${ACME_HOME%/}" != "${HOME:-}/.acme.sh" ]; then
        args+=(--home "$ACME_HOME")
    fi

    print_info "Installing $main with acme.sh (renewals will run: $reload)"
    if ! "$acme_bin" "${args[@]}"; then
        die "acme.sh --install-cert failed; the Nginx configuration was not changed"
    fi
    if [ ! -s "$chain" ]; then
        die "Installed certificate not found at $chain"
    fi

    ATTACH_HOST_CERT=$chain
    ATTACH_CERT="$(host_to_nginx_cert_path "$chain")"
    ATTACH_KEY="$(host_to_nginx_cert_path "$key")"
    ATTACH_NOTE=" (source: acme.sh, certificate: $main)"
}

attach_acme_docker() { # <index>
    local i=$1 main certs_host targets chain key host_chain host_key reload
    local -a args
    main=${C_NAME[i]}
    if ! container_running "$ACME_CONTAINER"; then
        die "The acme container '$ACME_CONTAINER' is not running; start it (docker compose up -d in its directory) and try again"
    fi
    certs_host="$(acme_docker_certs_dir)"
    if [ "$NGINX_MODE" = "docker" ] && ! same_dir "$certs_host" "$(site_path cert)"; then
        die "The acme container's /certs is $certs_host, but Docker Nginx reads certificates from $(site_path cert); mount that directory as /certs in the acme container"
    fi

    # Paths inside the container; /certs is the host's $certs_host
    targets="$(acme_install_targets "${C_DIR[i]}" "$main" /certs)"
    chain=${targets%%"$TAB"*}
    key=${targets#*"$TAB"}
    host_chain="$certs_host/${chain#/certs/}"
    host_key="$certs_host/${key#/certs/}"
    run_priv mkdir -p "$(dirname "$host_chain")" "$(dirname "$host_key")"
    drop_symlinks "$host_chain" "$host_key"

    reload="$(acme_reload_cmd docker)"
    args=(--install-cert -d "$main")
    if [ "${C_ECC[i]}" = "1" ]; then
        args+=(--ecc)
    fi
    args+=(--key-file "$key" --fullchain-file "$chain" --reloadcmd "$reload")

    print_info "Installing $main with the acme container"
    if ! docker exec "$ACME_CONTAINER" acme.sh "${args[@]}"; then
        die "acme.sh --install-cert failed in the acme container; the Nginx configuration was not changed"
    fi
    if [ ! -s "$host_chain" ]; then
        die "Installed certificate not found at $host_chain (check the acme container's /certs mount)"
    fi

    ATTACH_HOST_CERT=$host_chain
    if [ "$NGINX_MODE" = "docker" ]; then
        ATTACH_CERT="$(host_to_nginx_cert_path "$host_chain")"
        ATTACH_KEY="$(host_to_nginx_cert_path "$host_key")"
    else
        ATTACH_CERT=$host_chain
        ATTACH_KEY=$host_key
    fi
    ATTACH_NOTE=" (source: acme.sh docker, certificate: $main)"
}

attach_certbot() { # <index>
    local i=$1 name live store dst="" hook
    name=${C_NAME[i]}
    live=${C_DIR[i]}

    if [ "$NGINX_MODE" = "docker" ]; then
        # Docker Nginx cannot see /etc/letsencrypt: copy into the mounted cert dir
        store="$(cert_store_name "certbot-$name")"
        dst="$(site_path cert)/$store"
        run_priv mkdir -p "$dst"
        drop_symlinks "$dst/fullchain.cer" "$dst/$store.key"
        run_root install -m 644 "$live/fullchain.pem" "$dst/fullchain.cer"
        run_root install -m 600 "$live/privkey.pem" "$dst/$store.key"
        ATTACH_HOST_CERT="$dst/fullchain.cer"
        ATTACH_CERT="$(host_to_nginx_cert_path "$dst/fullchain.cer")"
        ATTACH_KEY="$(host_to_nginx_cert_path "$dst/$store.key")"
    else
        ATTACH_HOST_CERT="$live/fullchain.pem"
        ATTACH_CERT="$live/fullchain.pem"
        ATTACH_KEY="$live/privkey.pem"
    fi

    hook="$CERTBOT_HOOK_DIR/site-manager-$(cert_store_name "$name").sh"
    run_root mkdir -p "$CERTBOT_HOOK_DIR"
    if [ -n "$dst" ]; then
        render_certbot_hook "$name" "$(root_reload_cmd)" "$dst" "$store.key" | run_root tee "$hook" >/dev/null
    else
        render_certbot_hook "$name" "$(root_reload_cmd)" | run_root tee "$hook" >/dev/null
    fi
    run_root chmod 755 "$hook"
    print_info "certbot deploy hook written: $hook"
    ATTACH_NOTE=" (source: certbot, certificate: $name)"
}

attach_installed() { # <index>
    local i=$1
    ATTACH_HOST_CERT=${C_CERT[i]}
    ATTACH_CERT="$(host_to_nginx_cert_path "${C_CERT[i]}")" || die "Docker Nginx cannot read ${C_CERT[i]}"
    ATTACH_KEY="$(host_to_nginx_cert_path "${C_KEY[i]}")" || die "Docker Nginx cannot read ${C_KEY[i]}"
    ATTACH_NOTE=" (source: installed, certificate: ${C_NAME[i]})"
}

# attach_manual <domain> [cert] [key]: prompts for the paths when not given
attach_manual() {
    local domain=$1 cert=${2:-} key=${3:-} info="" rc=0 cert_pub key_pub store dst
    if [ -z "$cert" ]; then
        ask cert "Certificate (full chain) file"
        ask key "Private key file"
    fi
    [ -n "$cert" ] && [ -n "$key" ] || die "Both a certificate and a key file are needed"
    [ -r "$cert" ] || die "Cannot read certificate: $cert"
    [ -r "$key" ] || die "Cannot read key: $key"

    info="$(cert_check "$cert" "$(to_lower "$domain")")" || rc=$?
    case $rc in
        0) ;;
        2) die "The certificate in $cert has expired" ;;
        *)
            openssl x509 -in "$cert" -noout >/dev/null 2>&1 || die "Not a PEM certificate: $cert"
            if [ "$INTERACTIVE" != "1" ]; then
                die "The certificate in $cert does not cover $domain"
            fi
            print_warning "The certificate in $cert does not cover $domain"
            confirm "Use it anyway?" n || die "Cancelled"
            ;;
    esac

    cert_pub="$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null || true)"
    key_pub="$(openssl pkey -in "$key" -pubout 2>/dev/null || true)"
    if [ -z "$cert_pub" ] || [ "$cert_pub" != "$key_pub" ]; then
        die "The private key does not match the certificate"
    fi

    store="$(cert_store_name "manual-$domain")"
    dst="$(site_path cert)/$store"
    run_priv mkdir -p "$dst"
    drop_symlinks "$dst/fullchain.cer" "$dst/$store.key"
    run_priv install -m 644 "$cert" "$dst/fullchain.cer"
    run_priv install -m 600 "$key" "$dst/$store.key"

    ATTACH_HOST_CERT="$dst/fullchain.cer"
    ATTACH_CERT="$(host_to_nginx_cert_path "$dst/fullchain.cer")"
    ATTACH_KEY="$(host_to_nginx_cert_path "$dst/$store.key")"
    ATTACH_NOTE=" (source: manual copy of $cert)"
}

# Fail early (before installing anything) unless the site can take HTTPS
require_enabled_site() {
    if ! site_exists "$1"; then
        die "Website $1 does not exist"
    fi
    if ! is_site_enabled "$1"; then
        die "Website $1 is disabled; enable it first"
    fi
}

# Rewrite the site as HTTPS with ATTACH_*, keeping its proxy backend,
# WebSocket setting and server names.
enable_https() {
    local domain=$1 conf names backend websocket=yes
    conf="$(site_conf_file "$domain")"
    names="$(get_server_names "$conf")"
    names=${names:-$domain}
    backend="$(get_proxy_backend "$conf")"
    if [ -n "$backend" ]; then
        print_info "Keeping reverse proxy backend: $backend"
        if ! has_websocket "$conf"; then
            websocket=no
        fi
    fi
    warn_uncovered_names "$ATTACH_HOST_CERT" "$names"
    apply_site_config "$domain" render_https_config "$domain" "$names" \
        "$ATTACH_CERT" "$ATTACH_KEY" "$backend" "$websocket" "$ATTACH_NOTE"
}

cron_has_reload() {
    local current
    command -v crontab >/dev/null 2>&1 || return 1
    current="$(crontab -l 2>/dev/null || true)"
    case $current in
        *"$SCRIPT_PATH reload-if-renewed"*) return 0 ;;
    esac
    return 1
}

reload_cron_line() {
    echo "$RENEW_CRON_SCHEDULE bash $SCRIPT_PATH reload-if-renewed >/dev/null 2>&1"
}

# Add the reload-if-renewed cron job to this user's crontab (once)
ensure_reload_cron() {
    local current
    if cron_has_reload; then
        print_info "Cron job for reload-if-renewed already present"
        return 0
    fi
    if ! command -v crontab >/dev/null 2>&1; then
        print_warning "crontab not found; add this line to the host's crontab:"
        echo "  $(reload_cron_line)"
        return 0
    fi
    current="$(crontab -l 2>/dev/null || true)"
    if [ -n "$current" ]; then
        current="$current"$'\n'
    fi
    if printf '%s%s\n' "$current" "$(reload_cron_line)" | crontab -; then
        print_success "Cron job added: $(reload_cron_line)"
    else
        print_warning "Could not update the crontab; add this line yourself:"
        echo "  $(reload_cron_line)"
    fi
}

# After the Docker acme container got a new install target: Nginx was just
# reloaded, so drop the marker install-cert left, and make sure renewals
# trigger a reload.
docker_acme_followup() {
    rm -f "$(acme_docker_certs_dir)/$RENEW_MARKER_NAME" 2>/dev/null || true
    if cron_has_reload; then
        print_info "Renewals are reloaded by the existing reload-if-renewed cron job"
        return 0
    fi
    print_info "The acme container cannot reload Nginx itself; a host cron job does it after renewals."
    if [ "$INTERACTIVE" = "1" ] && confirm "Add the cron job now?" y; then
        ensure_reload_cron
    else
        print_warning "Add this line to the host's crontab so renewed certificates are loaded:"
        echo "  $(reload_cron_line)"
    fi
}

# attach_certificate <domain> <candidate index|manual> [cert] [key]
attach_certificate() {
    local domain=$1 choice=$2 kind
    require_enabled_site "$domain"
    if [ "$choice" = "manual" ]; then
        kind=manual
        attach_manual "$domain" "${3:-}" "${4:-}"
    else
        kind=${C_SRC[choice]}
        case $kind in
            acme) attach_acme_native "$choice" ;;
            acme-docker) attach_acme_docker "$choice" ;;
            certbot) attach_certbot "$choice" ;;
            installed) attach_installed "$choice" ;;
            *) die "Unknown certificate source: $kind" ;;
        esac
    fi

    enable_https "$domain"
    print_success "HTTPS enabled for $domain"

    case $kind in
        acme) print_info "Renewal: acme.sh renews the certificate, re-installs it and reloads Nginx" ;;
        acme-docker) docker_acme_followup ;;
        certbot) print_info "Renewal: certbot renews it; the deploy hook updates Nginx" ;;
        installed) print_info "Using the installed files as they are; whatever installed them keeps them renewed" ;;
        manual)
            print_warning "Manual certificate: renewal is NOT automatic. Replace the files before"
            print_warning "it expires, or issue one with acme_manage.sh and attach it instead."
            ;;
    esac
    print_info "Visit: https://$domain"
}

# choose_certificate <domain> <offer|menu>: sets CHOSEN to a candidate index,
# "manual", or "" when the user skips.
CHOSEN=""
choose_certificate() {
    local domain=$1 mode=$2 n answer
    CHOSEN=""
    discover_certificates "$domain"
    n=${#C_SRC[@]}

    if [ "$n" -eq 0 ]; then
        if [ "$mode" = "menu" ]; then
            print_warning "No usable certificate found for $domain"
        else
            print_info "No existing certificate covers $domain yet"
        fi
        if [ "$DISCOVER_EXPIRED" -gt 0 ]; then
            print_info "Ignored $DISCOVER_EXPIRED expired certificate(s)"
        fi
        if [ -n "$DISCOVER_HINT" ]; then
            print_info "$DISCOVER_HINT"
        fi
        print_info "Issue one with menu option 9 (acme_manage.sh), then attach it with option 4"
        if [ "$mode" = "menu" ] && confirm "Enter certificate and key paths manually?" n; then
            CHOSEN=manual
        fi
        return 0
    fi

    echo ""
    print_info "Certificates for $domain (best first):"
    print_candidates
    echo "  m) Enter certificate and key paths manually"
    if [ "$mode" = "offer" ]; then
        echo "  0) Skip (stay on HTTP)"
    else
        echo "  0) Cancel"
    fi
    if [ "$DISCOVER_HINT" != "" ]; then
        print_info "$DISCOVER_HINT"
    fi
    while true; do
        ask answer "Certificate to use" 1
        case $answer in
            0) return 0 ;;
            m | M)
                CHOSEN=manual
                return 0
                ;;
        esac
        if [[ $answer =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ] && [ "$answer" -le "$n" ]; then
            CHOSEN=$((answer - 1))
            return 0
        fi
        print_error "Choose 1-$n, m or 0"
    done
}

# After adding a site: attach a certificate right away when one exists
offer_https() {
    local conf
    conf="$(site_conf_file "$1")"
    if is_https_conf "$conf"; then
        return 0
    fi
    choose_certificate "$1" offer
    if [ -n "$CHOSEN" ]; then
        attach_certificate "$1" "$CHOSEN"
    fi
}

# ---------------------------------------------------------------------------
# Sites
# ---------------------------------------------------------------------------

# Managed site names, sorted (Docker: *.conf and *.conf.disabled in conf.d;
# native: *.conf in sites-available)
site_names() {
    local f conf_dir
    conf_dir="$(site_path conf)"
    {
        for f in "$conf_dir"/*.conf; do
            if [ -f "$f" ]; then
                basename "$f" .conf
            fi
        done
        if [ "$NGINX_MODE" = "docker" ]; then
            for f in "$conf_dir"/*.conf.disabled; do
                if [ -f "$f" ]; then
                    basename "$f" .conf.disabled
                fi
            done
        fi
    } | sort -u
}

# Fill SITES with site names: <all|enabled>
SITES=()
collect_sites() {
    local name list
    SITES=()
    list="$(site_names)"
    while IFS= read -r name; do
        if [ -z "$name" ]; then
            continue
        fi
        if [ "$1" = "enabled" ] && ! is_site_enabled "$name"; then
            continue
        fi
        SITES+=("$name")
    done <<<"$list"
}

# One list row: <number> <domain>
print_site_row() {
    local domain=$2 conf state="disabled" proto="HTTP" target="static" backend cert info=""
    conf="$(site_conf_any "$domain")"
    if is_site_enabled "$domain"; then
        state="enabled"
    fi
    backend="$(get_proxy_backend "$conf")"
    if [ -n "$backend" ]; then
        target="proxy -> $backend"
    fi
    if is_https_conf "$conf"; then
        proto="HTTPS"
        cert="$(get_ssl_cert "$conf")"
        if [ -n "$cert" ]; then
            info="$(cert_summary "$(nginx_to_host_cert_path "$cert")")"
        fi
    fi
    printf '%3s) %-30s %-8s %-5s %-32s %s\n' "$1" "$domain" "$state" "$proto" "$target" "$info"
}

print_site_table() {
    local i
    printf '%3s  %-30s %-8s %-5s %-32s %s\n' "#" "Domain" "Status" "Proto" "Serves" "Certificate"
    for ((i = 0; i < ${#SITES[@]}; i++)); do
        print_site_row "$((i + 1))" "${SITES[i]}"
    done
}

list_sites() {
    collect_sites all
    if [ "${#SITES[@]}" -eq 0 ]; then
        print_info "No sites yet (configs live in $(site_path conf))"
        return 0
    fi
    print_info "Sites ($(site_path conf)):"
    print_site_table
}

# pick_site <all|enabled> <allow new 0|1>: sets PICKED_SITE. Ends the action
# when cancelled (menu actions run in a subshell, so exit only leaves the action).
PICKED_SITE=""
pick_site() {
    local filter=$1 allow_new=$2 n answer prompt
    PICKED_SITE=""
    collect_sites "$filter"
    n=${#SITES[@]}
    if [ "$n" -eq 0 ] && [ "$allow_new" = "0" ]; then
        print_warning "No matching sites"
        exit 0
    fi
    if [ "$n" -gt 0 ]; then
        print_site_table
    fi
    if [ "$allow_new" = "1" ]; then
        prompt="Site number, or a new domain (empty to cancel)"
    else
        prompt="Site number (empty to cancel)"
    fi
    while true; do
        ask answer "$prompt"
        if [ -z "$answer" ]; then
            print_info "Cancelled"
            exit 0
        fi
        if [[ $answer =~ ^[0-9]+$ ]]; then
            if [ "$answer" -ge 1 ] && [ "$answer" -le "$n" ]; then
                PICKED_SITE=${SITES[answer - 1]}
                return 0
            fi
            print_error "No site number $answer"
        elif [ "$allow_new" = "1" ] && is_valid_domain "$answer"; then
            PICKED_SITE="$(to_lower "$answer")"
            return 0
        else
            print_error "Invalid choice: $answer"
        fi
    done
}

# Write a site's config, keeping HTTPS and server names if it has them:
# <domain> <backend|""> <websocket yes|no>
write_site() {
    local domain=$1 backend=$2 websocket=$3 conf names cert="" key="" note=""
    conf="$(site_conf_file "$domain")"
    names=$domain
    if [ -f "$conf" ]; then
        names="$(get_server_names "$conf")"
        names=${names:-$domain}
        if is_https_conf "$conf"; then
            cert="$(get_ssl_cert "$conf")"
            key="$(get_ssl_key "$conf")"
            note="$(get_cert_note "$conf")"
        fi
    fi
    if [ -n "$cert" ] && [ -n "$key" ]; then
        print_info "Keeping HTTPS ($cert)"
        apply_site_config "$domain" render_https_config "$domain" "$names" "$cert" "$key" \
            "$backend" "$websocket" "$note"
    elif [ -n "$backend" ]; then
        apply_site_config "$domain" render_http_proxy "$domain" "$names" "$backend" "$websocket"
    else
        apply_site_config "$domain" render_http_site "$domain" "$names"
    fi
}

# Add a static site
add_site() {
    local domain web_dir
    domain="$(to_lower "${1:-}")"
    [ -n "$domain" ] || die "Please specify a domain"
    validate_domain "$domain"

    web_dir="$(site_path web)/$domain"
    if site_exists "$domain"; then
        if ! is_site_enabled "$domain"; then
            die "Website $domain is disabled; enable it first"
        fi
        print_warning "Website $domain already exists"
        if ! confirm "Replace its configuration with a static site?" n; then
            print_info "Cancelled"
            exit 0
        fi
    fi

    print_info "Creating website $domain..."
    run_priv mkdir -p "$web_dir" "$(site_path log)/$domain"
    if [ ! -f "$web_dir/index.html" ]; then
        render_index_page "$domain" | write_file "$web_dir/index.html"
    fi

    write_site "$domain" "" yes

    print_success "Website $domain created"
    print_info "Website files: $web_dir/"
    if [ "$INTERACTIVE" = "1" ]; then
        offer_https "$domain"
    elif ! is_https_conf "$(site_conf_file "$domain")"; then
        print_info "Enable HTTPS with: $SCRIPT_PATH ssl $domain"
    fi
}

# Set up a reverse proxy: <domain> <backend> [websocket yes|no]
setup_proxy() {
    local domain backend websocket=${3:-yes}
    domain="$(to_lower "${1:-}")"
    [ -n "$domain" ] && [ -n "${2:-}" ] || die "Usage: site_manager.sh proxy <domain> <backend>"
    validate_domain "$domain"
    backend="$(normalize_backend "$2")" || die "Invalid backend: $2 (use 3000, 127.0.0.1:3000 or http(s)://host:port)"
    validate_backend "$backend"

    if site_exists "$domain" && ! is_site_enabled "$domain"; then
        die "Website $domain is disabled; enable it first"
    fi

    print_info "Configuring reverse proxy $domain -> $backend..."
    # The web dir serves ACME HTTP-01 challenges for the proxy
    run_priv mkdir -p "$(site_path log)/$domain" "$(site_path web)/$domain"
    write_site "$domain" "$backend" "$websocket"

    print_success "Reverse proxy configured: $domain -> $backend (WebSocket: $websocket)"
    if [ "$INTERACTIVE" = "1" ]; then
        offer_https "$domain"
    elif ! is_https_conf "$(site_conf_file "$domain")"; then
        print_info "Enable HTTPS with: $SCRIPT_PATH ssl $domain"
    fi
}

# Enable website
enable_site() {
    local domain=${1:-} conf
    [ -n "$domain" ] || die "Please specify a domain"
    validate_domain "$domain"
    conf="$(site_conf_file "$domain")"

    if [ "$NGINX_MODE" = "docker" ]; then
        [ -f "$conf.disabled" ] || die "No disabled configuration for $domain"
        mv "$conf.disabled" "$conf"
        commit_or_rollback mv "$conf" "$conf.disabled"
    else
        local link
        link="$(site_enabled_link "$domain")"
        [ -f "$conf" ] || die "Website $domain does not exist"
        if [ -e "$link" ]; then
            die "Website $domain is already enabled"
        fi
        run_priv ln -sf "$conf" "$link"
        commit_or_rollback run_priv rm -f "$link"
    fi
    print_success "Website $domain enabled"
}

# Disable website
disable_site() {
    local domain=${1:-} conf
    [ -n "$domain" ] || die "Please specify a domain"
    validate_domain "$domain"
    conf="$(site_conf_file "$domain")"
    [ -f "$conf" ] || die "Website $domain does not exist or is already disabled"

    if [ "$NGINX_MODE" = "docker" ]; then
        mv "$conf" "$conf.disabled"
        commit_or_rollback mv "$conf.disabled" "$conf"
    else
        local link
        link="$(site_enabled_link "$domain")"
        if [ ! -e "$link" ] && [ ! -L "$link" ]; then
            die "Website $domain is already disabled"
        fi
        run_priv rm -f "$link"
        commit_or_rollback run_priv ln -sf "$conf" "$link"
    fi
    print_success "Website $domain disabled"
}

# Delete website. Certificate files are kept: they belong to the certificate
# (acme.sh/certbot keep deploying there) and other sites may use them.
delete_site() {
    local domain=${1:-} conf web_dir log_dir link="" cert="" confirm_word=""
    [ -n "$domain" ] || die "Please specify a domain"
    validate_domain "$domain"

    conf="$(site_conf_file "$domain")"
    web_dir="$(site_path web)/$domain"
    log_dir="$(site_path log)/$domain"
    if [ "$NGINX_MODE" = "native" ]; then
        link="$(site_enabled_link "$domain")"
    fi
    site_exists "$domain" || die "Website $domain does not exist"
    cert="$(get_ssl_cert "$(site_conf_any "$domain")")"

    print_warning "About to delete website: $domain"
    print_warning "This will delete the following files and directories:"
    echo "  - $conf"
    if [ -n "$link" ]; then
        echo "  - $link"
    fi
    echo "  - $web_dir/"
    echo "  - $log_dir/"
    echo ""
    ask confirm_word "Confirm deletion? Type 'yes' to continue"
    if [ "$confirm_word" != "yes" ]; then
        print_info "Cancelled"
        exit 0
    fi

    local backup_dir
    backup_dir="$(site_path backup)/$domain-$(date +%Y%m%d-%H%M%S)"
    run_priv mkdir -p "$backup_dir"
    print_info "Creating backup in $backup_dir..."
    if [ -f "$conf" ]; then
        run_priv cp "$conf" "$backup_dir/"
    fi
    if [ -f "$conf.disabled" ]; then
        run_priv cp "$conf.disabled" "$backup_dir/"
    fi
    if [ -d "$web_dir" ]; then
        run_priv cp -r "$web_dir" "$backup_dir/"
    fi

    if [ -n "$link" ]; then
        run_priv rm -f "$link"
    fi
    run_priv rm -f "$conf" "$conf.disabled"
    run_priv rm -rf "$web_dir" "$log_dir"

    reload_nginx
    print_success "Website $domain deleted"
    print_info "Backup saved at: $backup_dir"
    if [ -n "$cert" ]; then
        print_info "Certificate files were kept: $(nginx_to_host_cert_path "$cert")"
    fi
}

# View logs
view_logs() {
    local domain=${1:-} lines=${2:-50} log_dir
    [ -n "$domain" ] || die "Usage: site_manager.sh logs <domain> [lines]"
    validate_domain "$domain"
    [[ $lines =~ ^[0-9]+$ ]] || die "Invalid line count: $lines"

    log_dir="$(site_path log)/$domain"
    [ -d "$log_dir" ] || die "No logs for $domain ($log_dir)"

    print_info "Logs for $domain (last $lines lines):"
    echo ""
    echo "=== Access Log ==="
    run_priv tail -n "$lines" "$log_dir/access.log" || print_warning "No access log yet"
    echo ""
    echo "=== Error Log ==="
    run_priv tail -n "$lines" "$log_dir/error.log" || print_warning "No error log yet"
}

# Reload Nginx after the Docker acme container renewed a certificate.
# Intended for host cron; silent when there is nothing to do.
reload_if_renewed() {
    local dir markers="" marker found=0
    for dir in "$NGINX_ROOT/certs" "$(acme_docker_certs_dir)"; do
        marker="$dir/$RENEW_MARKER_NAME"
        if [ -e "$marker" ]; then
            found=1
            markers="$markers$marker"$'\n'
        fi
    done
    if [ "$found" -eq 0 ]; then
        return 0
    fi

    print_info "Renewed certificate detected"
    check_nginx_running
    reload_nginx # exits on failure, keeping the marker so the next run retries
    while IFS= read -r marker; do
        if [ -n "$marker" ] && ! rm -f "$marker"; then
            print_warning "Could not remove $marker"
        fi
    done <<<"$markers"
}

# CLI "ssl": <domain> [--cert FILE --key FILE]
cli_ssl() {
    local domain cert="" key=""
    domain="$(to_lower "${1:-}")"
    [ -n "$domain" ] && [[ $domain != -* ]] || die "Usage: site_manager.sh ssl <domain> [--cert FILE --key FILE]"
    validate_domain "$domain"
    shift
    while [ $# -gt 0 ]; do
        case $1 in
            --cert | --key)
                [ $# -ge 2 ] && [ -n "$2" ] || die "Option $1 requires a file"
                if [ "$1" = "--cert" ]; then cert=$2; else key=$2; fi
                shift 2
                ;;
            --with-www | --extra | --wildcard | --server | -w | -e | -s)
                die "site_manager.sh no longer issues certificates; issue them with acme_manage.sh, then run: site_manager.sh ssl $domain"
                ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    if [ -n "$cert$key" ]; then
        [ -n "$cert" ] && [ -n "$key" ] || die "Use --cert and --key together"
        attach_certificate "$domain" manual "$cert" "$key"
        return 0
    fi

    require_enabled_site "$domain"
    discover_certificates "$domain"
    if [ "${#C_SRC[@]}" -eq 0 ]; then
        if [ "$DISCOVER_EXPIRED" -gt 0 ]; then
            print_info "Ignored $DISCOVER_EXPIRED expired certificate(s)"
        fi
        if [ -n "$DISCOVER_HINT" ]; then
            print_info "$DISCOVER_HINT"
        fi
        die "No usable certificate found for $domain; issue one with acme_manage.sh first"
    fi
    print_info "Using $(source_label "${C_SRC[0]}") certificate ${C_NAME[0]} (expires ${C_EXPIRY[0]})"
    attach_certificate "$domain" 0
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------

menu_add_static() {
    local domain
    ask domain "New site domain (e.g. example.com, empty to cancel)"
    if [ -z "$domain" ]; then
        print_info "Cancelled"
        return 0
    fi
    add_site "$domain"
}

menu_proxy() {
    local domain conf existing="" input backend websocket=yes default_ws=y
    pick_site enabled 1
    domain=$PICKED_SITE
    conf="$(site_conf_file "$domain")"
    if site_exists "$domain" && ! is_site_enabled "$domain"; then
        die "Website $domain is disabled; enable it first"
    fi
    if [ -f "$conf" ]; then
        existing="$(get_proxy_backend "$conf")"
        if [ -n "$existing" ] && ! has_websocket "$conf"; then
            default_ws=n
        fi
        if [ -z "$existing" ]; then
            print_warning "$domain is a static site; it will become a reverse proxy (its files are kept)"
        fi
    fi
    while true; do
        ask input "Backend (port, host:port or http(s):// URL)" "$existing"
        if backend="$(normalize_backend "$input")"; then
            break
        fi
        print_error "Invalid backend: '$input' (e.g. 3000, 127.0.0.1:3000, http://10.0.0.5:8080)"
    done
    if ! confirm "Enable WebSocket support?" "$default_ws"; then
        websocket=no
    fi
    setup_proxy "$domain" "$backend" "$websocket"
}

menu_enable_https() {
    pick_site enabled 0
    choose_certificate "$PICKED_SITE" menu
    if [ -z "$CHOSEN" ]; then
        print_info "Cancelled"
        return 0
    fi
    attach_certificate "$PICKED_SITE" "$CHOSEN"
}

menu_toggle_site() {
    pick_site all 0
    if is_site_enabled "$PICKED_SITE"; then
        if confirm "Disable $PICKED_SITE?" y; then
            disable_site "$PICKED_SITE"
        fi
    elif confirm "Enable $PICKED_SITE?" y; then
        enable_site "$PICKED_SITE"
    fi
}

menu_delete_site() {
    pick_site all 0
    delete_site "$PICKED_SITE"
}

menu_logs() {
    local lines
    pick_site all 0
    ask lines "Number of lines" 50
    view_logs "$PICKED_SITE" "$lines"
}

find_acme_manage() {
    local candidate
    if [ -n "$ACME_MANAGE_SH" ]; then
        [ -f "$ACME_MANAGE_SH" ] || return 1
        echo "$ACME_MANAGE_SH"
        return 0
    fi
    for candidate in "$SCRIPT_DIR/../acme_manage.sh" "$SCRIPT_DIR/acme_manage.sh"; do
        if [ -f "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    command -v acme_manage.sh 2>/dev/null
}

menu_issue_certificate() {
    local tool
    if ! tool="$(find_acme_manage)"; then
        print_warning "acme_manage.sh was not found next to this script or in PATH."
        echo "  Download it: curl -fsSL $ACME_MANAGE_URL -o acme_manage.sh"
        echo "  Put it next to site_manager.sh (or set ACME_MANAGE_SH), issue the"
        echo "  certificate there, then use option 4 to attach it."
        return 0
    fi
    print_info "Starting $tool (it needs root); this menu continues when it exits"
    # acme_manage.sh insists on root, and keeps acme.sh in root's ~/.acme.sh
    if ! run_root bash "$tool"; then
        print_warning "acme_manage.sh exited with an error"
    fi
    if confirm "Attach a certificate to a site now?" y; then
        menu_enable_https
    fi
}

menu_test_reload() {
    reload_nginx
}

show_menu() {
    cat <<MENU

==========================================
 Nginx Site Manager ($NGINX_MODE mode)
==========================================
 1) List sites
 2) Add a static site
 3) Reverse proxy a site
 4) Enable HTTPS on a site (attach a certificate)
 5) Enable / disable a site
 6) Delete a site
 7) View logs
 8) Test and reload Nginx
 9) Issue a certificate (acme_manage.sh)
 0) Exit
MENU
}

# Run a menu action in a subshell with errexit: any failure or "exit" ends
# only that action, and the menu continues.
run_action() {
    local rc
    set +e
    (
        set -e
        "$@"
    )
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        print_warning "Action not completed"
    fi
    pause
}

menu_loop() {
    local choice
    INTERACTIVE=1
    if ! nginx_running; then
        print_warning "Nginx is not running; changes will fail their configuration test"
    fi
    while true; do
        show_menu
        if ! IFS= read -r -p "Choose an option [0-9]: " choice; then
            echo
            return 0
        fi
        choice="$(trim "$choice")"
        case $choice in
            1) run_action list_sites ;;
            2) run_action menu_add_static ;;
            3) run_action menu_proxy ;;
            4) run_action menu_enable_https ;;
            5) run_action menu_toggle_site ;;
            6) run_action menu_delete_site ;;
            7) run_action menu_logs ;;
            8) run_action menu_test_reload ;;
            9) run_action menu_issue_certificate ;;
            0 | q | quit | exit)
                echo "Bye."
                return 0
                ;;
            "") ;;
            *) print_error "Unknown option: $choice" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    local cmd=${1:-menu}
    case $cmd in
        menu)
            detect_nginx_mode
            menu_loop
            ;;
        list | ls)
            detect_nginx_mode
            list_sites
            ;;
        add)
            check_nginx_running
            add_site "${2:-}"
            ;;
        proxy)
            check_nginx_running
            if [ "${4:-}" = "--no-websocket" ]; then
                setup_proxy "${2:-}" "${3:-}" no
            elif [ -n "${4:-}" ]; then
                die "Unknown option: $4"
            else
                setup_proxy "${2:-}" "${3:-}" yes
            fi
            ;;
        ssl)
            check_nginx_running
            shift
            cli_ssl "$@"
            ;;
        enable)
            check_nginx_running
            enable_site "${2:-}"
            ;;
        disable)
            check_nginx_running
            disable_site "${2:-}"
            ;;
        delete | remove | rm)
            check_nginx_running
            delete_site "${2:-}"
            ;;
        logs)
            detect_nginx_mode
            view_logs "${2:-}" "${3:-50}"
            ;;
        reload)
            check_nginx_running
            reload_nginx
            ;;
        reload-if-renewed)
            reload_if_renewed
            ;;
        test)
            check_nginx_running
            test_nginx
            ;;
        help | --help | -h)
            show_help
            ;;
        acme-status | acme | status)
            die "'$cmd' was removed: certificates are managed by acme_manage.sh; use 'list' for sites"
            ;;
        *)
            print_error "Unknown command: $cmd"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

main "$@"
