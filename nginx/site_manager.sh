#!/bin/bash

# Load configuration if exists
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/site_manager.conf" ]; then
    source "$SCRIPT_DIR/site_manager.conf"
fi

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

NGINX_ROOT="/opt/nginx"
ACME_SERVER="${ACME_SERVER:-letsencrypt}"  # Default: letsencrypt, Options: letsencrypt, zerossl, google, buypass
ACME_MODE=""  # Will be set to "docker" or "native"
ACME_SH_PATH="$HOME/.acme.sh/acme.sh"  # Default native acme.sh path
NGINX_MODE=""  # Will be set to "docker" or "native"

# Print colored messages
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_info() { echo -e "${BLUE}ℹ${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }

# Show help
show_help() {
    cat << HELP
Nginx Site Manager - Nginx Virtual Host Management Tool (Docker & Native)

Usage: ./site_manager.sh <command> [options]

Commands:
  add <domain>                           Add new website (single domain)
  ssl <domain> [options]                 Apply SSL certificate
  enable <domain>                        Enable website
  disable <domain>                       Disable website
  delete <domain>                        Delete website (with confirmation)
  list                                   List all websites
  status                                 Show Nginx status
  acme-status                            Show ACME.sh status and certificate list (auto-install if not found)
  logs <domain> [lines]                  View website logs (default: last 50 lines)
  reload                                 Reload Nginx configuration
  test                                   Test Nginx configuration
  help                                   Show this help message

SSL Options:
  --with-www                             Add www.$domain to certificate
  --extra <domains>                      Add custom domains (comma-separated)
  --wildcard                             Use wildcard certificate (requires DNS API)
  --server <provider>                    ACME server (letsencrypt|zerossl|google|buypass, default: letsencrypt)
  
Examples:
  # Add websites
  ./site_manager.sh add example.com                     # Add example.com
  ./site_manager.sh add api.example.com                 # Add API subdomain
  
  # SSL certificates
  ./site_manager.sh ssl api.example.com                 # Single domain: api.example.com
  ./site_manager.sh ssl example.com --with-www          # Two domains: example.com + www.example.com
  ./site_manager.sh ssl example.com --extra www,api,cdn # Multiple: example.com + www + api + cdn
  ./site_manager.sh ssl example.com --wildcard          # Wildcard: example.com + *.example.com
  ./site_manager.sh ssl example.com --server zerossl    # Use ZeroSSL instead of Let's Encrypt
  ./site_manager.sh ssl example.com --server google     # Use Google Trust Services
  ./site_manager.sh ssl example.com --server buypass    # Use BuyPass (180-day validity)
  
  # Other operations
  ./site_manager.sh logs example.com 100                # View last 100 lines of logs
  ./site_manager.sh list                                # List all websites
  ./site_manager.sh delete old-site.com                 # Delete website
  ./site_manager.sh acme-status                         # Check ACME.sh status or install it

Notes:
  - Default: Single domain only (no www)
  - Wildcard SSL requires Cloudflare DNS API (script will prompt for credentials)
  - HTTP validation requires domain accessible on port 80
  - Supported CA: Let's Encrypt (letsencrypt) | ZeroSSL (zerossl) | Google Trust Services (google) | BuyPass (buypass)
  - BuyPass offers 180-day validity (vs 90-day for others)
  - Supports both Docker Nginx and Native Nginx (auto-detected)
  - Supports both Docker acme.sh and Native acme.sh (auto-detected)
  - If Nginx is not installed, script will offer to install Nginx Stable

Required Credentials (will be prompted automatically):
  - Wildcard certificates: Cloudflare API Token or Global API Key
  - Google Trust Services: EAB KID and HMAC Key from Google Cloud Console

HELP
}

# Detect and set ACME mode (docker or native)
detect_acme_mode() {
    if [ -n "$ACME_MODE" ]; then
        return 0  # Already detected
    fi
    
    # Check Docker acme container first
    if docker ps 2>/dev/null | grep -q "acme"; then
        ACME_MODE="docker"
        print_info "Using ACME (Docker mode)"
        return 0
    fi
    
    # Check native acme.sh installation
    if [ -f "$ACME_SH_PATH" ]; then
        ACME_MODE="native"
        print_info "Using ACME (Native mode: $ACME_SH_PATH)"
        return 0
    fi
    
    # No acme.sh found
    print_error "ACME.sh not found!"
    echo ""
    echo "Please install acme.sh using one of these methods:"
    echo ""
    echo "1. Docker version (recommended):"
    echo "   docker run -d --name acme --restart=unless-stopped \\"
    echo "     -v ~/.acme.sh:/acme.sh \\"
    echo "     -v /opt/nginx/certs:/certs \\"
    echo "     -v /opt/nginx/html:/webroot \\"
    echo "     neilpang/acme.sh:latest daemon"
    echo ""
    echo "2. Native installation:"
    echo "   curl https://get.acme.sh | sh"
    echo ""
    exit 1
}

# Execute acme.sh command (automatically use docker or native)
acme_exec() {
    detect_acme_mode
    
    if [ "$ACME_MODE" = "docker" ]; then
        docker exec acme acme.sh "$@"
    else
        "$ACME_SH_PATH" "$@"
    fi
}

# Check required credentials for specific scenarios
check_credentials() {
    local acme_server=$1
    local wildcard=$2
    
    # Check wildcard DNS API credentials
    if [ "$wildcard" = true ]; then
        if [ -z "$CF_Email" ] && [ -z "$CF_Token" ]; then
            print_warning "Wildcard certificate requires Cloudflare DNS API credentials"
            echo ""
            echo "Choose authentication method:"
            echo "  1) API Token (recommended)"
            echo "  2) Global API Key"
            echo ""
            read -p "Select [1-2]: " cf_choice
            
            case $cf_choice in
                1)
                    echo ""
                    print_info "Get API Token at: https://dash.cloudflare.com/profile/api-tokens"
                    echo "Required permissions: Zone:DNS:Edit"
                    echo ""
                    read -p "Enter Cloudflare API Token: " CF_Token
                    export CF_Token
                    
                    if [ -z "$CF_Token" ]; then
                        print_error "API Token cannot be empty!"
                        return 1
                    fi
                    ;;
                2)
                    echo ""
                    print_info "Get Global API Key at: https://dash.cloudflare.com/profile/api-tokens"
                    echo ""
                    read -p "Enter Cloudflare Email: " CF_Email
                    read -p "Enter Cloudflare Global API Key: " CF_Key
                    export CF_Email
                    export CF_Key
                    
                    if [ -z "$CF_Email" ] || [ -z "$CF_Key" ]; then
                        print_error "Email and API Key cannot be empty!"
                        return 1
                    fi
                    ;;
                *)
                    print_error "Invalid choice!"
                    return 1
                    ;;
            esac
            echo ""
        fi
        
        if [ -n "$CF_Token" ]; then
            print_info "Using Cloudflare API Token for DNS validation"
        else
            print_info "Using Cloudflare Global API Key for DNS validation"
        fi
    fi
    
    # Check Google Trust Services EAB credentials
    if [ "$acme_server" = "google" ]; then
        if [ -z "$GOOGLE_EAB_KID" ] || [ -z "$GOOGLE_EAB_HMAC_KEY" ]; then
            print_warning "Google Trust Services requires EAB (External Account Binding) credentials"
            echo ""
            print_info "Get EAB credentials at: https://cloud.google.com/certificate-manager/docs/public-ca"
            echo ""
            echo "Steps to get credentials:"
            echo "  1. Go to Google Cloud Console"
            echo "  2. Enable 'Public Certificate Authority API'"
            echo "  3. Create External Account Binding credentials"
            echo ""
            read -p "Enter GOOGLE_EAB_KID: " GOOGLE_EAB_KID
            read -p "Enter GOOGLE_EAB_HMAC_KEY: " GOOGLE_EAB_HMAC_KEY
            export GOOGLE_EAB_KID
            export GOOGLE_EAB_HMAC_KEY
            
            if [ -z "$GOOGLE_EAB_KID" ] || [ -z "$GOOGLE_EAB_HMAC_KEY" ]; then
                print_error "EAB credentials cannot be empty!"
                return 1
            fi
            echo ""
        fi
        print_info "Using Google Trust Services with EAB credentials"
    fi
    
    return 0
}

# Detect Nginx mode (docker or native)
detect_nginx_mode() {
    if [ -n "$NGINX_MODE" ]; then
        return 0  # Already detected
    fi
    
    # Check Docker Nginx first
    if docker ps 2>/dev/null | grep -q "nginx"; then
        NGINX_MODE="docker"
        print_info "Using Nginx (Docker mode)"
        return 0
    fi
    
    # Check native Nginx installation
    if command -v nginx &> /dev/null; then
        NGINX_MODE="native"
        NGINX_ROOT="/etc/nginx"
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
    read -p "Select [1-3]: " nginx_choice
    
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
            echo "      - /opt/nginx/conf.d:/etc/nginx/conf.d"
            echo "      - /opt/nginx/html:/var/www"
            echo "      - /opt/nginx/logs:/var/log/nginx"
            echo "      - /opt/nginx/certs:/etc/nginx/certs"
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
            print_error "Invalid choice"
            exit 1
            ;;
    esac
}

# Install native Nginx (stable version)
install_native_nginx() {
    print_info "Installing Nginx Stable..."
    
    # Detect OS
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        print_error "Cannot detect OS"
        exit 1
    fi
    
    case $OS in
        ubuntu|debian)
            print_info "Detected: $OS"
            sudo apt update
            sudo apt install -y curl gnupg2 ca-certificates lsb-release
            
            # Add Nginx official repository
            echo "deb http://nginx.org/packages/$OS $(lsb_release -cs) nginx" | \
                sudo tee /etc/apt/sources.list.d/nginx.list
            
            # Import signing key
            curl -fsSL https://nginx.org/keys/nginx_signing.key | \
                sudo gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg
            
            echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
http://nginx.org/packages/$OS $(lsb_release -cs) nginx" | \
                sudo tee /etc/apt/sources.list.d/nginx.list
            
            # Install Nginx
            sudo apt update
            sudo apt install -y nginx
            ;;
            
        centos|rhel|fedora)
            print_info "Detected: $OS"
            sudo yum install -y yum-utils
            
            # Add Nginx repository
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
            print_error "Unsupported OS: $OS"
            print_info "Please install Nginx manually"
            exit 1
            ;;
    esac
    
    # Start and enable Nginx
    sudo systemctl start nginx
    sudo systemctl enable nginx
    
    # Create standard directory structure
    sudo mkdir -p /etc/nginx/sites-available
    sudo mkdir -p /etc/nginx/sites-enabled
    sudo mkdir -p /var/www
    sudo mkdir -p /etc/nginx/certs
    
    # Backup original nginx.conf
    sudo cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
    
    # Add include for sites-enabled if not exists
    if ! grep -q "sites-enabled" /etc/nginx/nginx.conf; then
        sudo sed -i '/http {/a \    include /etc/nginx/sites-enabled/*.conf;' /etc/nginx/nginx.conf
    fi
    
    # Restart Nginx to apply changes
    sudo systemctl restart nginx
    
    NGINX_MODE="native"
    NGINX_ROOT="/etc/nginx"
    
    print_success "Nginx Stable installed successfully!"
    print_info "Nginx version:"
    nginx -v
    echo ""
    print_info "Directory structure:"
    echo "  Config:  /etc/nginx/sites-available/"
    echo "  Enabled: /etc/nginx/sites-enabled/"
    echo "  Sites:   /var/www/"
    echo "  Logs:    /var/log/nginx/"
    echo "  Certs:   /etc/nginx/certs/"
}

# Execute Nginx command (automatically use docker or native)
nginx_exec() {
    detect_nginx_mode
    
    if [ "$NGINX_MODE" = "docker" ]; then
        docker exec nginx "$@"
    else
        sudo "$@"
    fi
}

# Check if Nginx is running
check_nginx_running() {
    detect_nginx_mode
    
    if [ "$NGINX_MODE" = "docker" ]; then
        if ! docker ps | grep -q "nginx"; then
            print_error "Nginx container is not running!"
            exit 1
        fi
    else
        if ! systemctl is-active --quiet nginx; then
            print_error "Nginx service is not running!"
            echo "Start it with: sudo systemctl start nginx"
            exit 1
        fi
    fi
}

# Test Nginx configuration
test_nginx() {
    detect_nginx_mode
    print_info "Testing Nginx configuration..."
    
    if [ "$NGINX_MODE" = "docker" ]; then
        if docker exec nginx nginx -t 2>&1; then
            print_success "Configuration syntax is correct"
            return 0
        else
            print_error "Configuration syntax error!"
            return 1
        fi
    else
        if sudo nginx -t 2>&1; then
            print_success "Configuration syntax is correct"
            return 0
        else
            print_error "Configuration syntax error!"
            return 1
        fi
    fi
}

# Reload Nginx
reload_nginx() {
    if test_nginx; then
        print_info "Reloading Nginx..."
        if [ "$NGINX_MODE" = "docker" ]; then
            docker exec nginx nginx -s reload
        else
            sudo systemctl reload nginx
        fi
        print_success "Nginx reloaded"
    else
        print_error "Configuration test failed, not reloaded"
        exit 1
    fi
}

# Add website
add_site() {
    local domain=$1
    
    if [ -z "$domain" ]; then
        print_error "Please specify a domain"
        echo "Usage: ./site_manager.sh add <domain>"
        exit 1
    fi
    
    detect_nginx_mode
    
    # Set paths based on Nginx mode
    local conf_dir site_root log_dir cert_dir
    if [ "$NGINX_MODE" = "docker" ]; then
        conf_dir="$NGINX_ROOT/conf.d"
        site_root="$NGINX_ROOT/html"
        log_dir="$NGINX_ROOT/logs"
        cert_dir="$NGINX_ROOT/certs"
    else
        conf_dir="$NGINX_ROOT/sites-available"
        site_root="/var/www"
        log_dir="/var/log/nginx"
        cert_dir="/etc/nginx/certs"
    fi
    
    # Check if website already exists
    if [ -f "$conf_dir/$domain.conf" ]; then
        print_warning "Website $domain already exists!"
        read -p "Overwrite? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Cancelled"
            exit 0
        fi
    fi
    
    print_info "Creating website $domain..."
    
    # Create directories
    if [ "$NGINX_MODE" = "native" ]; then
        sudo mkdir -p "$site_root/$domain"
        sudo mkdir -p "$log_dir/$domain"
        sudo mkdir -p "$cert_dir/$domain"
    else
        mkdir -p "$site_root/$domain"
        mkdir -p "$log_dir/$domain"
        mkdir -p "$cert_dir/$domain"
    fi
    
    # Create sample page
    local index_file="$site_root/$domain/index.html"
    if [ "$NGINX_MODE" = "native" ]; then
        sudo tee "$index_file" > /dev/null <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome to $domain</title>
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
        code { 
            background: rgba(0,0,0,0.3); 
            padding: 2px 8px; 
            border-radius: 4px;
            font-family: 'Courier New', monospace;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Welcome to $domain</h1>
        <p class="status">✓ Site is running successfully!</p>
    </div>
</body>
</html>
HTML
    else
        cat > "$index_file" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome to $domain</title>
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
        code { 
            background: rgba(0,0,0,0.3); 
            padding: 2px 8px; 
            border-radius: 4px;
            font-family: 'Courier New', monospace;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>🚀 Welcome to $domain</h1>
        <p class="status">✓ Site is running successfully!</p>
    </div>
</body>
</html>
HTML
    fi
    
    # Create Nginx configuration
    local nginx_conf="$conf_dir/$domain.conf"
    
    if [ "$NGINX_MODE" = "native" ]; then
        sudo tee "$nginx_conf" > /dev/null <<NGINX
# HTTP Configuration
server {
    listen 80;
    listen [::]:80;
    server_name $domain;
    
    root /var/www/$domain;
    index index.html index.htm index.php;
    
    # ACME certificate validation path
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/$domain;
        try_files \$uri =404;
    }
    
    # Temporary HTTP access (will auto-redirect after SSL setup)
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    # Logs
    access_log /var/log/nginx/$domain/access.log;
    error_log /var/log/nginx/$domain/error.log;
}
NGINX
        # Enable site by creating symlink
        sudo ln -sf "$nginx_conf" "$NGINX_ROOT/sites-enabled/$domain.conf"
    else
        cat > "$nginx_conf" <<NGINX
# HTTP Configuration
server {
    listen 80;
    listen [::]:80;
    server_name $domain;
    
    root /var/www/$domain;
    index index.html index.htm index.php;
    
    # ACME certificate validation path
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/$domain;
        try_files \$uri =404;
    }
    
    # Temporary HTTP access (will auto-redirect after SSL setup)
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    # Logs
    access_log /var/log/nginx/$domain/access.log;
    error_log /var/log/nginx/$domain/error.log;
}
NGINX
    fi
    
    # Test and reload
    reload_nginx
    
    print_success "Website $domain created successfully!"
    echo ""
    print_info "Next steps:"
    echo "  1. Point domain DNS to this server"
    echo "  2. Apply SSL certificate:"
    echo "     - Single domain:  ./site_manager.sh ssl $domain"
    echo "     - With www:       ./site_manager.sh ssl $domain --with-www"
    echo "     - Custom domains: ./site_manager.sh ssl $domain --extra www.$domain,cdn.$domain"
    echo "     - Wildcard:       ./site_manager.sh ssl $domain --wildcard"
    echo "  3. Visit: http://$domain"
    echo ""
    print_info "Website files location: $site_root/$domain/"
}

# Apply SSL certificate
add_ssl() {
    local domain=$1
    local wildcard=false
    local with_www=false
    local extra_domains=""
    local all_domains="-d $domain"
    local acme_server="${ACME_SERVER}"  # Use global default
    
    if [ -z "$domain" ]; then
        print_error "Please specify a domain"
        echo "Usage: ./site_manager.sh ssl <domain> [options]"
        echo ""
        echo "Options:"
        echo "  --with-www              Add www.$domain"
        echo "  --extra domain1,domain2 Add custom domains (comma-separated)"
        echo "  --wildcard              Use wildcard (*.$domain, requires DNS API)"
        echo "  --server <provider>     ACME server (letsencrypt|zerossl|google|buypass)"
        echo ""
        echo "Examples:"
        echo "  ./site_manager.sh ssl api.example.com                          # Single domain only"
        echo "  ./site_manager.sh ssl example.com --with-www                   # example.com + www.example.com"
        echo "  ./site_manager.sh ssl example.com --extra www,cdn,api          # example.com + www,cdn,api subdomains"
        echo "  ./site_manager.sh ssl example.com --wildcard                   # example.com + *.example.com"
        echo "  ./site_manager.sh ssl example.com --server zerossl             # Use ZeroSSL"
        echo "  ./site_manager.sh ssl example.com --server google              # Use Google Trust Services"
        echo "  ./site_manager.sh ssl example.com --server buypass             # Use BuyPass (180-day validity)"
        exit 1
    fi
    
    # Parse arguments
    shift
    while [[ $# -gt 0 ]]; do
        case $1 in
            --wildcard|-w)
                wildcard=true
                shift
                ;;
            --with-www)
                with_www=true
                shift
                ;;
            --extra|-e)
                extra_domains="$2"
                shift 2
                ;;
            --server|-s)
                acme_server="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done
    
    # Validate and normalize ACME server name
    case "${acme_server,,}" in  # Convert to lowercase
        letsencrypt|le)
            acme_server="letsencrypt"
            ;;
        zerossl|zero)
            acme_server="zerossl"
            ;;
        google|gts|googletrustservices)
            acme_server="google"
            ;;
        buypass|bp)
            acme_server="buypass"
            ;;
        *)
            print_warning "Unknown ACME server: $acme_server, using letsencrypt"
            acme_server="letsencrypt"
            ;;
    esac
    
    print_info "Using ACME server: $acme_server"
    
    # Check if website configuration exists
    if [ ! -f "$NGINX_ROOT/conf.d/$domain.conf" ]; then
        print_error "Website $domain does not exist!"
        print_info "Please run first: ./site_manager.sh add $domain"
        exit 1
    fi
    
    # Detect ACME mode
    detect_acme_mode
    
    # Check required credentials
    if ! check_credentials "$acme_server" "$wildcard"; then
        exit 1
    fi
    
    # Check if parent domain has wildcard certificate (for subdomains)
    if [[ "$domain" =~ \. ]]; then
        # Extract parent domain (e.g., api.example.com -> example.com)
        local parent_domain=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')
        
        # Check if wildcard certificate exists for parent domain
        if acme_exec --list 2>/dev/null | grep -q "\*\.$parent_domain"; then
            print_info "Found existing wildcard certificate for *.$parent_domain"
            print_info "Reusing wildcard certificate instead of issuing new one..."
            
            # Check if parent domain cert directory exists
            if [ -d "$NGINX_ROOT/certs/$parent_domain" ]; then
                # Create symlink or copy certificate
                mkdir -p "$NGINX_ROOT/certs/$domain"
                
                # Use symlinks to reuse wildcard certificate
                ln -sf "../$parent_domain/$parent_domain.key" "$NGINX_ROOT/certs/$domain/$domain.key"
                ln -sf "../$parent_domain/fullchain.cer" "$NGINX_ROOT/certs/$domain/fullchain.cer"
                
                print_success "Wildcard certificate linked successfully!"
                
                # Update configuration to enable HTTPS
                local server_name_line="server_name $domain;"
                
                cat > "$NGINX_ROOT/conf.d/$domain.conf" <<NGINX
# HTTP Configuration (redirect to HTTPS)
server {
    listen 80;
    listen [::]:80;
    $server_name_line
    
    # ACME certificate validation path
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/$domain;
        try_files \$uri =404;
    }
    
    # Redirect to HTTPS
    location / {
        return 301 https://\$server_name\$request_uri;
    }
    
    # Logs
    access_log /var/log/nginx/$domain/access.log;
    error_log /var/log/nginx/$domain/error.log;
}

# HTTPS Configuration
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    $server_name_line
    
    # SSL Certificate (using wildcard cert from $parent_domain)
    ssl_certificate /etc/nginx/certs/$domain/fullchain.cer;
    ssl_certificate_key /etc/nginx/certs/$domain/$domain.key;
    
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
    
    root /var/www/$domain;
    index index.html index.htm index.php;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    # Logs
    access_log /var/log/nginx/$domain/access.log;
    error_log /var/log/nginx/$domain/error.log;
}
NGINX
                
                reload_nginx
                
                print_success "SSL configured successfully using wildcard certificate!"
                print_info "Using wildcard certificate from: $parent_domain"
                return 0
            fi
        fi
    fi
    
    # Build domain list
    if [ "$wildcard" = true ]; then
        all_domains="-d $domain -d *.$domain"
        local server_name_line="server_name $domain *.$domain;"
        print_info "Applying wildcard SSL certificate for $domain and *.$domain..."
        print_warning "Wildcard SSL requires DNS API validation"
        
        # Issue wildcard certificate using DNS validation
        print_info "Step 1/3: Issuing certificate via DNS validation..."
        
        # Build command with optional EAB parameters for Google
        local issue_cmd="--issue --dns dns_cf $all_domains --server $acme_server --force"
        if [ "$acme_server" = "google" ]; then
            issue_cmd="$issue_cmd --eab-kid $GOOGLE_EAB_KID --eab-hmac-key $GOOGLE_EAB_HMAC_KEY"
        fi
        
        acme_exec $issue_cmd
            
    else
        # Build server_name and domains for certificate
        local server_name_parts="$domain"
        
        # Add www if requested
        if [ "$with_www" = true ]; then
            all_domains="$all_domains -d www.$domain"
            server_name_parts="$server_name_parts www.$domain"
        fi
        
        # Add extra domains if provided
        if [ -n "$extra_domains" ]; then
            IFS=',' read -ra DOMAINS <<< "$extra_domains"
            for extra in "${DOMAINS[@]}"; do
                # Trim whitespace
                extra=$(echo "$extra" | xargs)
                
                # If it doesn't contain a dot, treat as subdomain
                if [[ ! "$extra" =~ \. ]]; then
                    extra="$extra.$domain"
                fi
                
                all_domains="$all_domains -d $extra"
                server_name_parts="$server_name_parts $extra"
            done
        fi
        
        local server_name_line="server_name $server_name_parts;"
        
        print_info "Applying SSL certificate for: $server_name_parts"
        
        # Issue certificate using HTTP validation
        print_info "Step 1/3: Issuing certificate via HTTP validation..."
        
        # Set webroot path based on ACME mode
        local webroot_path
        if [ "$ACME_MODE" = "docker" ]; then
            webroot_path="/webroot/$domain"
        else
            webroot_path="$NGINX_ROOT/html/$domain"
        fi
        
        # Build command with optional EAB parameters for Google
        local issue_cmd="--issue $all_domains -w $webroot_path --server $acme_server --force"
        if [ "$acme_server" = "google" ]; then
            issue_cmd="$issue_cmd --eab-kid $GOOGLE_EAB_KID --eab-hmac-key $GOOGLE_EAB_HMAC_KEY"
        fi
        
        acme_exec $issue_cmd
    fi
    
    if [ $? -ne 0 ]; then
        print_error "Certificate issuance failed!"
        print_info "Possible reasons:"
        echo "  - DNS not pointing to this server"
        echo "  - Domain is not accessible"
        echo "  - Firewall blocking port 80"
        if [ "$wildcard" = true ]; then
            echo "  - DNS API credentials not configured"
        fi
        exit 1
    fi
    
    # Install certificate
    print_info "Step 2/3: Installing certificate..."
    
    # Set certificate paths based on ACME mode
    local cert_key_path
    local cert_fullchain_path
    if [ "$ACME_MODE" = "docker" ]; then
        cert_key_path="/certs/$domain/$domain.key"
        cert_fullchain_path="/certs/$domain/fullchain.cer"
    else
        mkdir -p "$NGINX_ROOT/certs/$domain"
        cert_key_path="$NGINX_ROOT/certs/$domain/$domain.key"
        cert_fullchain_path="$NGINX_ROOT/certs/$domain/fullchain.cer"
    fi
    
    acme_exec --install-cert -d "$domain" \
        --key-file "$cert_key_path" \
        --fullchain-file "$cert_fullchain_path"
    
    # Update configuration to enable HTTPS
    print_info "Step 3/3: Enabling HTTPS configuration..."
    
    cat > "$NGINX_ROOT/conf.d/$domain.conf" <<NGINX
# HTTP Configuration (redirect to HTTPS)
server {
    listen 80;
    listen [::]:80;
    $server_name_line
    
    # ACME certificate validation path
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/$domain;
        try_files \$uri =404;
    }
    
    # Redirect to HTTPS
    location / {
        return 301 https://\$server_name\$request_uri;
    }
    
    # Logs
    access_log /var/log/nginx/$domain/access.log;
    error_log /var/log/nginx/$domain/error.log;
}

# HTTPS Configuration
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    $server_name_line
    
    # SSL Certificate
    ssl_certificate /etc/nginx/certs/$domain/fullchain.cer;
    ssl_certificate_key /etc/nginx/certs/$domain/$domain.key;
    
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
    
    root /var/www/$domain;
    index index.html index.htm index.php;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    # Logs
    access_log /var/log/nginx/$domain/access.log;
    error_log /var/log/nginx/$domain/error.log;
}
NGINX
    
    reload_nginx
    
    print_success "SSL certificate configured successfully!"
    echo ""
    print_info "SSL is now active for: $server_name_parts"
    print_info "Certificate will auto-renew"
}

# List all websites
list_sites() {
    print_info "All websites:"
    echo ""
    
    for conf in "$NGINX_ROOT/conf.d"/*.conf; do
        if [ -f "$conf" ]; then
            local domain=$(basename "$conf" .conf)
            local status="✓ Enabled"
            local ssl_status="❌ No SSL"
            local ssl_type=""
            
            # Check SSL
            if [ -f "$NGINX_ROOT/certs/$domain/fullchain.cer" ]; then
                ssl_status="✓ SSL"
                
                # Check if it's a symlink (using wildcard from parent domain)
                if [ -L "$NGINX_ROOT/certs/$domain/fullchain.cer" ]; then
                    local parent_domain=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')
                    ssl_type=" (Using wildcard from $parent_domain)"
                # Check if wildcard cert for this domain
                elif detect_acme_mode 2>/dev/null && acme_exec --list 2>/dev/null | grep -q "\*\.$domain"; then
                    ssl_type=" (Wildcard)"
                fi
                
                # Check ACME server/CA
                if detect_acme_mode 2>/dev/null; then
                    local cert_info=$(acme_exec --info -d "$domain" 2>/dev/null | grep "Le_API" || echo "")
                    if [[ "$cert_info" == *"zerossl"* ]]; then
                        ssl_type="$ssl_type [ZeroSSL]"
                    elif [[ "$cert_info" == *"google"* ]]; then
                        ssl_type="$ssl_type [Google]"
                    elif [[ "$cert_info" == *"buypass"* ]]; then
                        ssl_type="$ssl_type [BuyPass]"
                    elif [[ "$cert_info" == *"letsencrypt"* ]]; then
                        ssl_type="$ssl_type [Let's Encrypt]"
                    fi
                fi
            fi
            
            echo -e "${GREEN}●${NC} $domain"
            echo "   Status: $status | SSL: $ssl_status$ssl_type"
            echo "   Config: $conf"
            echo "   Files: $NGINX_ROOT/html/$domain/"
            echo ""
        fi
    done
    
    for conf in "$NGINX_ROOT/conf.d"/*.disabled; do
        if [ -f "$conf" ]; then
            local domain=$(basename "$conf" .conf.disabled)
            echo -e "${YELLOW}●${NC} $domain"
            echo "   Status: ⚠ Disabled"
            echo ""
        fi
    done
}

# Enable website
enable_site() {
    local domain=$1
    
    if [ -z "$domain" ]; then
        print_error "Please specify a domain"
        exit 1
    fi
    
    if [ ! -f "$NGINX_ROOT/conf.d/$domain.conf.disabled" ]; then
        print_error "Disabled configuration file not found"
        exit 1
    fi
    
    mv "$NGINX_ROOT/conf.d/$domain.conf.disabled" "$NGINX_ROOT/conf.d/$domain.conf"
    reload_nginx
    print_success "Website $domain enabled"
}

# Disable website
disable_site() {
    local domain=$1
    
    if [ -z "$domain" ]; then
        print_error "Please specify a domain"
        exit 1
    fi
    
    if [ ! -f "$NGINX_ROOT/conf.d/$domain.conf" ]; then
        print_error "Website $domain does not exist"
        exit 1
    fi
    
    mv "$NGINX_ROOT/conf.d/$domain.conf" "$NGINX_ROOT/conf.d/$domain.conf.disabled"
    reload_nginx
    print_success "Website $domain disabled"
}

# Delete website
delete_site() {
    local domain=$1
    
    if [ -z "$domain" ]; then
        print_error "Please specify a domain"
        exit 1
    fi
    
    if [ ! -f "$NGINX_ROOT/conf.d/$domain.conf" ] && [ ! -f "$NGINX_ROOT/conf.d/$domain.conf.disabled" ]; then
        print_error "Website $domain does not exist"
        exit 1
    fi
    
    print_warning "About to delete website: $domain"
    print_warning "This will delete the following files and directories:"
    echo "  - $NGINX_ROOT/conf.d/$domain.conf"
    echo "  - $NGINX_ROOT/html/$domain/"
    echo "  - $NGINX_ROOT/logs/$domain/"
    echo "  - $NGINX_ROOT/certs/$domain/"
    echo ""
    read -p "Confirm deletion? Type 'yes' to continue: " confirm
    
    if [ "$confirm" != "yes" ]; then
        print_info "Cancelled"
        exit 0
    fi
    
    # Create backup
    local backup_dir="$NGINX_ROOT/backups/$domain-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    
    print_info "Creating backup to $backup_dir..."
    [ -f "$NGINX_ROOT/conf.d/$domain.conf" ] && cp "$NGINX_ROOT/conf.d/$domain.conf" "$backup_dir/"
    [ -d "$NGINX_ROOT/html/$domain" ] && cp -r "$NGINX_ROOT/html/$domain" "$backup_dir/"
    
    # Delete files
    rm -f "$NGINX_ROOT/conf.d/$domain.conf"
    rm -f "$NGINX_ROOT/conf.d/$domain.conf.disabled"
    rm -rf "$NGINX_ROOT/html/$domain"
    rm -rf "$NGINX_ROOT/logs/$domain"
    rm -rf "$NGINX_ROOT/certs/$domain"
    
    reload_nginx
    print_success "Website $domain deleted"
    print_info "Backup saved at: $backup_dir"
}

# View logs
view_logs() {
    local domain=$1
    local lines=${2:-50}
    
    if [ -z "$domain" ]; then
        print_error "Please specify a domain"
        echo "Usage: ./site_manager.sh logs <domain> [lines]"
        exit 1
    fi
    
    if [ ! -d "$NGINX_ROOT/logs/$domain" ]; then
        print_error "Website $domain does not exist"
        exit 1
    fi
    
    print_info "Viewing logs for $domain (last $lines lines):"
    echo ""
    echo "=== Access Log ==="
    tail -n "$lines" "$NGINX_ROOT/logs/$domain/access.log"
    echo ""
    echo "=== Error Log ==="
    tail -n "$lines" "$NGINX_ROOT/logs/$domain/error.log"
}

# Show status
show_status() {
    print_info "Nginx container status:"
    docker ps | grep nginx
    echo ""
    
    print_info "Configuration test:"
    test_nginx
    echo ""
    
    print_info "Website statistics:"
    local enabled=$(ls "$NGINX_ROOT/conf.d"/*.conf 2>/dev/null | wc -l)
    local disabled=$(ls "$NGINX_ROOT/conf.d"/*.disabled 2>/dev/null | wc -l)
    echo "  Enabled: $enabled"
    echo "  Disabled: $disabled"
}

# Install ACME.sh (interactive)
install_acme() {
    print_info "ACME.sh is not installed"
    echo ""
    echo "Choose installation method:"
    echo "  1) Docker (recommended, isolated)"
    echo "  2) Native (install to ~/.acme.sh/)"
    echo "  3) Cancel"
    echo ""
    read -p "Select [1-3]: " acme_choice
    
    case $acme_choice in
        1)
            print_info "Installing ACME.sh via Docker..."
            echo ""
            
            # Check if Docker is available
            if ! command -v docker &> /dev/null; then
                print_error "Docker is not installed!"
                print_info "Please install Docker first: https://docs.docker.com/get-docker/"
                exit 1
            fi
            
            # Create directories
            mkdir -p ~/.acme.sh
            mkdir -p /opt/nginx/certs
            mkdir -p /opt/nginx/html
            
            # Run ACME container
            docker run -d --name acme \
                --restart=unless-stopped \
                -v ~/.acme.sh:/acme.sh \
                -v /opt/nginx/certs:/certs \
                -v /opt/nginx/html:/webroot \
                neilpang/acme.sh:latest daemon
            
            if [ $? -eq 0 ]; then
                print_success "ACME.sh Docker container installed successfully!"
                ACME_MODE="docker"
            else
                print_error "Failed to install ACME.sh Docker container"
                exit 1
            fi
            ;;
            
        2)
            print_info "Installing ACME.sh natively..."
            echo ""
            
            # Install acme.sh
            curl -fsSL https://get.acme.sh | sh -s email=my@example.com
            
            if [ $? -eq 0 ]; then
                print_success "ACME.sh installed successfully!"
                print_info "Installation path: $HOME/.acme.sh/"
                ACME_MODE="native"
                ACME_SH_PATH="$HOME/.acme.sh/acme.sh"
            else
                print_error "Failed to install ACME.sh"
                exit 1
            fi
            ;;
            
        3)
            print_info "Cancelled"
            exit 0
            ;;
            
        *)
            print_error "Invalid choice"
            exit 1
            ;;
    esac
}

# Show ACME status and certificate list
show_acme_status() {
    # Try to detect, but don't exit if not found
    if [ -z "$ACME_MODE" ]; then
        if docker ps 2>/dev/null | grep -q "acme"; then
            ACME_MODE="docker"
        elif [ -f "$ACME_SH_PATH" ]; then
            ACME_MODE="native"
        else
            # ACME not found, offer to install
            install_acme
        fi
    fi
    
    echo ""
    print_success "ACME Mode: $ACME_MODE"
    
    if [ "$ACME_MODE" = "docker" ]; then
        print_info "Docker container status:"
        docker ps | grep acme || print_warning "ACME container not found"
        echo ""
    else
        print_info "Native installation path: $ACME_SH_PATH"
        echo ""
    fi
    
    print_info "Certificate list:"
    echo ""
    acme_exec --list
    
    echo ""
    print_info "ACME version:"
    acme_exec --version
}

# Main function
main() {
    case "$1" in
        add)
            check_nginx_running
            add_site "$2"
            ;;
        ssl)
            check_nginx_running
            add_ssl "$2" "$3"
            ;;
        enable)
            check_nginx_running
            enable_site "$2"
            ;;
        disable)
            check_nginx_running
            disable_site "$2"
            ;;
        delete|remove|rm)
            check_nginx_running
            delete_site "$2"
            ;;
        list|ls)
            list_sites
            ;;
        logs)
            view_logs "$2" "$3"
            ;;
        reload)
            check_nginx_running
            reload_nginx
            ;;
        test)
            check_nginx_running
            test_nginx
            ;;
        status)
            check_nginx_running
            show_status
            ;;
        acme-status|acme)
            show_acme_status
            ;;
        help|--help|-h|"")
            show_help
            ;;
        *)
            print_error "Unknown command: $1"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

main "$@"