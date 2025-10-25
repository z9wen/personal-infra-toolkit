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
ACME_SERVER="${ACME_SERVER:-letsencrypt}"  # Default: letsencrypt, Options: letsencrypt, zerossl, google

# Print colored messages
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_info() { echo -e "${BLUE}ℹ${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }

# Show help
show_help() {
    cat << HELP
Nginx Site Manager - Docker Nginx Virtual Host Management Tool

Usage: $0 <command> [options]

Commands:
  add <domain>                           Add new website (single domain)
  ssl <domain> [options]                 Apply SSL certificate
  enable <domain>                        Enable website
  disable <domain>                       Disable website
  delete <domain>                        Delete website (with confirmation)
  list                                   List all websites
  status                                 Show Nginx status
  logs <domain> [lines]                  View website logs (default: last 50 lines)
  reload                                 Reload Nginx configuration
  test                                   Test Nginx configuration

SSL Options:
  --with-www                             Add www.$domain to certificate
  --extra <domains>                      Add custom domains (comma-separated)
  --wildcard                             Use wildcard certificate (requires DNS API)
  --server <provider>                    ACME server (letsencrypt|zerossl|google, default: letsencrypt)
  
Examples:
  # Add websites
  $0 add example.com                     # Add example.com
  $0 add api.example.com                 # Add API subdomain
  
  # SSL certificates
  $0 ssl api.example.com                 # Single domain: api.example.com
  $0 ssl example.com --with-www          # Two domains: example.com + www.example.com
  $0 ssl example.com --extra www,api,cdn # Multiple: example.com + www + api + cdn
  $0 ssl example.com --wildcard          # Wildcard: example.com + *.example.com
  $0 ssl example.com --server zerossl    # Use ZeroSSL instead of Let's Encrypt
  $0 ssl example.com --server google     # Use Google Trust Services
  
  # Other operations
  $0 logs example.com 100                # View last 100 lines of logs
  $0 list                                # List all websites
  $0 delete old-site.com                 # Delete website

Notes:
  - Default: Single domain only (no www)
  - Wildcard SSL requires DNS API (Cloudflare CF_Email and CF_Key)
  - HTTP validation requires domain accessible on port 80
  - Supported CA: Let's Encrypt (letsencrypt) | ZeroSSL (zerossl) | Google Trust Services (google)

HELP
}

# Check if Docker containers are running
check_containers() {
    if ! docker ps | grep -q "nginx"; then
        print_error "Nginx container is not running!"
        exit 1
    fi
}

# Test Nginx configuration
test_nginx() {
    print_info "Testing Nginx configuration..."
    if docker exec nginx nginx -t 2>&1; then
        print_success "Configuration syntax is correct"
        return 0
    else
        print_error "Configuration syntax error!"
        return 1
    fi
}

# Reload Nginx
reload_nginx() {
    if test_nginx; then
        print_info "Reloading Nginx..."
        docker exec nginx nginx -s reload
        print_success "Nginx reloaded"
    else
        print_error "Configuration test failed, not reloaded"
        exit 1
    fi
}

# Add website
# Add website
add_site() {
    local domain=$1
    
    if [ -z "$domain" ]; then
        print_error "Please specify a domain"
        echo "Usage: $0 add <domain>"
        exit 1
    fi
    
    # Check if website already exists
    if [ -f "$NGINX_ROOT/conf.d/$domain.conf" ]; then
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
    mkdir -p "$NGINX_ROOT/html/$domain"
    mkdir -p "$NGINX_ROOT/logs/$domain"
    mkdir -p "$NGINX_ROOT/certs/$domain"
    
    # Create sample page
    cat > "$NGINX_ROOT/html/$domain/index.html" <<HTML
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
    
    # Create Nginx configuration (only listen on exact domain, no www)
    cat > "$NGINX_ROOT/conf.d/$domain.conf" <<NGINX
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

# HTTPS Configuration (will be auto-enabled after SSL certificate)
# server {
#     listen 443 ssl http2;
#     listen [::]:443 ssl http2;
#     server_name $domain;
#     
#     # SSL Certificate
#     ssl_certificate /etc/nginx/certs/$domain/fullchain.cer;
#     ssl_certificate_key /etc/nginx/certs/$domain/$domain.key;
#     
#     # SSL Optimization
#     ssl_protocols TLSv1.2 TLSv1.3;
#     ssl_ciphers HIGH:!aNULL:!MD5;
#     ssl_prefer_server_ciphers on;
#     ssl_session_cache shared:SSL:10m;
#     ssl_session_timeout 10m;
#     
#     # Security Headers
#     add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
#     
#     root /var/www/$domain;
#     index index.html index.htm index.php;
#     
#     location / {
#         try_files \$uri \$uri/ =404;
#     }
#     
#     # Logs
#     access_log /var/log/nginx/$domain/access.log;
#     error_log /var/log/nginx/$domain/error.log;
# }
NGINX
    
    # Test and reload
    reload_nginx
    
    print_success "Website $domain created successfully!"
    echo ""
    print_info "Next steps:"
    echo "  1. Point domain DNS to this server"
    echo "  2. Apply SSL certificate:"
    echo "     - Single domain:  $0 ssl $domain"
    echo "     - With www:       $0 ssl $domain --with-www"
    echo "     - Custom domains: $0 ssl $domain --extra www.$domain,cdn.$domain"
    echo "     - Wildcard:       $0 ssl $domain --wildcard"
    echo "  3. Visit: http://$domain"
    echo ""
    print_info "Website files location: $NGINX_ROOT/html/$domain/"
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
        echo "Usage: $0 ssl <domain> [options]"
        echo ""
        echo "Options:"
        echo "  --with-www              Add www.$domain"
        echo "  --extra domain1,domain2 Add custom domains (comma-separated)"
        echo "  --wildcard              Use wildcard (*.$domain, requires DNS API)"
        echo "  --server <provider>     ACME server (letsencrypt|zerossl|google)"
        echo ""
        echo "Examples:"
        echo "  $0 ssl api.example.com                          # Single domain only"
        echo "  $0 ssl example.com --with-www                   # example.com + www.example.com"
        echo "  $0 ssl example.com --extra www,cdn,api          # example.com + www,cdn,api subdomains"
        echo "  $0 ssl example.com --wildcard                   # example.com + *.example.com"
        echo "  $0 ssl example.com --server zerossl             # Use ZeroSSL"
        echo "  $0 ssl example.com --server google              # Use Google Trust Services"
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
        *)
            print_warning "Unknown ACME server: $acme_server, using letsencrypt"
            acme_server="letsencrypt"
            ;;
    esac
    
    print_info "Using ACME server: $acme_server"
    
    # Check if website configuration exists
    if [ ! -f "$NGINX_ROOT/conf.d/$domain.conf" ]; then
        print_error "Website $domain does not exist!"
        print_info "Please run first: $0 add $domain"
        exit 1
    fi
    
    # Check ACME container
    if ! docker ps | grep -q "acme"; then
        print_error "ACME container is not running!"
        exit 1
    fi
    
    # Check if parent domain has wildcard certificate (for subdomains)
    if [[ "$domain" =~ \. ]]; then
        # Extract parent domain (e.g., api.example.com -> example.com)
        local parent_domain=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')
        
        # Check if wildcard certificate exists for parent domain
        if docker exec acme acme.sh --list 2>/dev/null | grep -q "\*\.$parent_domain"; then
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
        docker exec acme acme.sh --issue \
            --dns dns_cf \
            $all_domains \
            --server "$acme_server" \
            --force
            
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
        docker exec acme acme.sh --issue \
            $all_domains \
            -w "/webroot/$domain" \
            --server "$acme_server" \
            --force
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
    docker exec acme acme.sh --install-cert -d "$domain" \
        --key-file "/certs/$domain/$domain.key" \
        --fullchain-file "/certs/$domain/fullchain.cer"
    
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
                elif docker exec acme acme.sh --list 2>/dev/null | grep -q "\*\.$domain"; then
                    ssl_type=" (Wildcard)"
                fi
                
                # Check ACME server/CA
                local cert_info=$(docker exec acme acme.sh --info -d "$domain" 2>/dev/null | grep "Le_API" || echo "")
                if [[ "$cert_info" == *"zerossl"* ]]; then
                    ssl_type="$ssl_type [ZeroSSL]"
                elif [[ "$cert_info" == *"google"* ]]; then
                    ssl_type="$ssl_type [Google]"
                elif [[ "$cert_info" == *"letsencrypt"* ]]; then
                    ssl_type="$ssl_type [Let's Encrypt]"
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
        echo "Usage: $0 logs <domain> [lines]"
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

# Main function
main() {
    case "$1" in
        add)
            check_containers
            add_site "$2"
            ;;
        ssl)
            check_containers
            add_ssl "$2" "$3"
            ;;
        enable)
            check_containers
            enable_site "$2"
            ;;
        disable)
            check_containers
            disable_site "$2"
            ;;
        delete|remove|rm)
            check_containers
            delete_site "$2"
            ;;
        list|ls)
            list_sites
            ;;
        logs)
            view_logs "$2" "$3"
            ;;
        reload)
            check_containers
            reload_nginx
            ;;
        test)
            check_containers
            test_nginx
            ;;
        status)
            check_containers
            show_status
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