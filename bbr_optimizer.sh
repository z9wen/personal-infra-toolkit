#!/bin/bash
# bbr_optimizer.sh - BBR Optimization Configuration Script
# Suitable for Gaming + Streaming scenarios

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print colored messages
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        echo "Please use: sudo $0"
        exit 1
    fi
}

# Check kernel version
check_kernel() {
    kernel_version=$(uname -r | cut -d. -f1,2)
    kernel_major=$(echo $kernel_version | cut -d. -f1)
    kernel_minor=$(echo $kernel_version | cut -d. -f2)
    
    print_info "Current kernel version: $(uname -r)"
    
    if [ "$kernel_major" -lt 4 ] || ([ "$kernel_major" -eq 4 ] && [ "$kernel_minor" -lt 9 ]); then
        print_error "BBR requires kernel version >= 4.9"
        print_error "Current kernel: $(uname -r)"
        exit 1
    fi
    
    print_success "Kernel version check passed"
}

# Backup current configuration
backup_config() {
    backup_file="/etc/sysctl.conf.backup.$(date +%Y%m%d_%H%M%S)"
    cp /etc/sysctl.conf "$backup_file"
    print_success "Configuration backed up to: $backup_file"
}

# Display menu
show_menu() {
    clear
    echo "======================================"
    echo "    BBR Optimization Script"
    echo "======================================"
    echo ""
    echo "Select configuration mode:"
    echo ""
    echo "1) Balanced Mode (Recommended)"
    echo "   - tcp_notsent_lowat: 128KB"
    echo "   - Buffer: 24MB"
    echo "   - Best for: Gaming + 4K Video"
    echo ""
    echo "2) Gaming Priority Mode"
    echo "   - tcp_notsent_lowat: 64KB"
    echo "   - Buffer: 16MB"
    echo "   - Best for: Competitive Gaming"
    echo ""
    echo "3) Ultra Low Latency Mode"
    echo "   - tcp_notsent_lowat: 16KB"
    echo "   - Buffer: 8MB"
    echo "   - Best for: Professional Esports"
    echo ""
    echo "4) Streaming Priority Mode"
    echo "   - tcp_notsent_lowat: 256KB"
    echo "   - Buffer: 32MB"
    echo "   - Best for: 4K/8K Video"
    echo ""
    echo "5) View Current Configuration"
    echo "6) Restore Backup"
    echo "0) Exit"
    echo ""
    echo "======================================"
}

# Configuration Mode 1: Balanced
config_balanced() {
    cat > /tmp/bbr_config.conf << 'EOF'
# ==================== BBR Balanced Mode Configuration ====================
# Best for: CS2 Gaming + YouTube/Netflix 4K Video

# BBR Core
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Buffer - 24MB
net.ipv4.tcp_rmem = 4096 131072 25165824
net.ipv4.tcp_wmem = 4096 87380 25165824
net.core.rmem_max = 25165824
net.core.wmem_max = 25165824

# Low Latency Key Parameter
net.ipv4.tcp_notsent_lowat = 131072

# UDP Optimization
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# TCP Basic Optimization
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_moderate_rcvbuf = 1

# Retransmission Strategy
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_retries1 = 3
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_orphan_retries = 2

# Keepalive
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 3
net.ipv4.tcp_keepalive_probes = 3

# Connection Reuse
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 65536

# Port Range
net.ipv4.ip_local_port_range = 1024 65535

# Queue Settings
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_max_syn_backlog = 32768

# Security
net.ipv4.tcp_syncookies = 1

# Forwarding
net.ipv4.ip_forward = 1

# File Limits
fs.file-max = 1048576
fs.inotify.max_user_instances = 8192
EOF
}

# Configuration Mode 2: Gaming Priority
config_gaming() {
    cat > /tmp/bbr_config.conf << 'EOF'
# ==================== BBR Gaming Priority Configuration ====================
# Best for: Competitive Gaming

# BBR Core
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Buffer - 16MB (Lower Latency)
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216

# Low Latency Key Parameter - More Aggressive
net.ipv4.tcp_notsent_lowat = 65536

# UDP Optimization
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# TCP Basic Optimization
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_moderate_rcvbuf = 1

# Retransmission Strategy - Faster
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_retries1 = 3
net.ipv4.tcp_retries2 = 5
net.ipv4.tcp_orphan_retries = 1

# Keepalive - Fast Detection
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 3
net.ipv4.tcp_keepalive_probes = 3

# Connection Reuse
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_max_tw_buckets = 65536

# Port Range
net.ipv4.ip_local_port_range = 1024 65535

# Queue Settings
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_max_syn_backlog = 32768

# Security
net.ipv4.tcp_syncookies = 1

# Forwarding
net.ipv4.ip_forward = 1

# File Limits
fs.file-max = 1048576
fs.inotify.max_user_instances = 8192
EOF
}

# Configuration Mode 3: Ultra Low Latency
config_ultra_low_latency() {
    cat > /tmp/bbr_config.conf << 'EOF'
# ==================== BBR Ultra Low Latency Configuration ====================
# Best for: Professional Esports

# BBR Core
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Buffer - 8MB (Minimum Latency)
net.ipv4.tcp_rmem = 4096 65536 8388608
net.ipv4.tcp_wmem = 4096 32768 8388608
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608

# Low Latency Key Parameter - Extreme
net.ipv4.tcp_notsent_lowat = 16384

# UDP Optimization
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# TCP Basic Optimization
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_moderate_rcvbuf = 1

# Retransmission Strategy - Extremely Fast
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_retries1 = 2
net.ipv4.tcp_retries2 = 5
net.ipv4.tcp_orphan_retries = 1

# Keepalive - Super Fast Detection
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 3
net.ipv4.tcp_keepalive_probes = 3

# Connection Reuse
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_max_tw_buckets = 65536

# Port Range
net.ipv4.ip_local_port_range = 1024 65535

# Queue Settings
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_max_syn_backlog = 32768

# Security
net.ipv4.tcp_syncookies = 1

# Forwarding
net.ipv4.ip_forward = 1

# File Limits
fs.file-max = 1048576
fs.inotify.max_user_instances = 8192
EOF
}

# Configuration Mode 4: Streaming Priority
config_streaming() {
    cat > /tmp/bbr_config.conf << 'EOF'
# ==================== BBR Streaming Priority Configuration ====================
# Best for: 4K/8K Video

# BBR Core
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Buffer - 32MB (High Bandwidth)
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 87380 33554432
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432

# Low Latency Key Parameter - Favor Throughput
net.ipv4.tcp_notsent_lowat = 262144

# UDP Optimization
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# TCP Basic Optimization
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_moderate_rcvbuf = 1

# Retransmission Strategy
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_retries1 = 3
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_orphan_retries = 2

# Keepalive
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 3
net.ipv4.tcp_keepalive_probes = 3

# Connection Reuse
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 65536

# Port Range
net.ipv4.ip_local_port_range = 1024 65535

# Queue Settings
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_max_syn_backlog = 32768

# Security
net.ipv4.tcp_syncookies = 1

# Forwarding
net.ipv4.ip_forward = 1

# File Limits
fs.file-max = 1048576
fs.inotify.max_user_instances = 8192
EOF
}

# Ask about ICMP
ask_icmp() {
    echo ""
    echo "======================================"
    echo "ICMP Ping Response Settings"
    echo "======================================"
    echo ""
    echo "Disable ICMP ping response?"
    echo ""
    echo "If disabled:"
    echo "  ✓ Server won't respond to ping requests"
    echo "  ✓ Increases security, prevents scanning"
    echo "  ✗ Cannot use ping to test server"
    echo ""
    read -p "Disable ICMP? (y/N): " disable_icmp
    
    if [[ "$disable_icmp" =~ ^[Yy]$ ]]; then
        echo "" >> /tmp/bbr_config.conf
        echo "# ICMP Settings - Disable ping response" >> /tmp/bbr_config.conf
        echo "net.ipv4.icmp_echo_ignore_all = 1" >> /tmp/bbr_config.conf
        echo "net.ipv6.icmp.echo_ignore_all = 1" >> /tmp/bbr_config.conf
        print_info "ICMP disable configuration added"
    else
        print_info "ICMP response kept enabled"
    fi
}

# Apply configuration
apply_config() {
    local mode_name=$1
    
    # Ask ICMP settings
    ask_icmp
    
    # Display configuration to be applied
    echo ""
    echo "======================================"
    echo "Configuration to be applied:"
    echo "======================================"
    cat /tmp/bbr_config.conf
    echo "======================================"
    echo ""
    
    read -p "Confirm applying this configuration? (y/N): " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_warning "Configuration cancelled"
        rm -f /tmp/bbr_config.conf
        return
    fi
    
    # Backup
    backup_config
    
    # Remove old BBR configuration (if exists)
    sed -i '/# ==================== BBR/,/fs.inotify.max_user_instances/d' /etc/sysctl.conf
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    sed -i '/net.ipv4.icmp_echo_ignore_all/d' /etc/sysctl.conf
    sed -i '/net.ipv6.icmp.echo_ignore_all/d' /etc/sysctl.conf
    
    # Add new configuration
    cat /tmp/bbr_config.conf >> /etc/sysctl.conf
    
    # Apply configuration
    print_info "Applying configuration..."
    sysctl -p > /dev/null 2>&1
    
    # Load BBR module
    modprobe tcp_bbr
    
    # Verify
    echo ""
    print_success "Configuration applied!"
    echo ""
    echo "======================================"
    echo "Verification Results:"
    echo "======================================"
    echo "Queue Discipline: $(sysctl -n net.core.default_qdisc)"
    echo "Congestion Control: $(sysctl -n net.ipv4.tcp_congestion_control)"
    echo "tcp_notsent_lowat: $(sysctl -n net.ipv4.tcp_notsent_lowat) bytes"
    echo "Max Recv Buffer: $(sysctl -n net.core.rmem_max) bytes ($(echo "scale=2; $(sysctl -n net.core.rmem_max)/1024/1024" | bc) MB)"
    echo "Max Send Buffer: $(sysctl -n net.core.wmem_max) bytes ($(echo "scale=2; $(sysctl -n net.core.wmem_max)/1024/1024" | bc) MB)"
    
    icmp_status=$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null || echo "0")
    if [ "$icmp_status" = "1" ]; then
        echo "ICMP Ping: Disabled"
    else
        echo "ICMP Ping: Enabled"
    fi
    echo "======================================"
    
    rm -f /tmp/bbr_config.conf
    
    echo ""
    print_success "✓ BBR ${mode_name} configuration complete!"
    echo ""
}

# View current configuration
view_current() {
    echo ""
    echo "======================================"
    echo "Current Network Configuration"
    echo "======================================"
    echo "Kernel Version: $(uname -r)"
    echo "Queue Discipline: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo 'Not set')"
    echo "Congestion Control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'Not set')"
    echo "Available Algorithms: $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo 'Unknown')"
    echo ""
    echo "tcp_notsent_lowat: $(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null || echo 'Default') bytes"
    echo "Max Recv Buffer: $(sysctl -n net.core.rmem_max 2>/dev/null || echo 'Unknown') bytes"
    echo "Max Send Buffer: $(sysctl -n net.core.wmem_max 2>/dev/null || echo 'Unknown') bytes"
    echo ""
    
    icmp_status=$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null || echo "0")
    if [ "$icmp_status" = "1" ]; then
        echo "ICMP Ping: Disabled ✗"
    else
        echo "ICMP Ping: Enabled ✓"
    fi
    echo "======================================"
    echo ""
    
    read -p "Press Enter to continue..."
}

# Restore backup
restore_backup() {
    echo ""
    echo "======================================"
    echo "Available Backup Files:"
    echo "======================================"
    
    backup_files=$(ls -t /etc/sysctl.conf.backup.* 2>/dev/null || echo "")
    
    if [ -z "$backup_files" ]; then
        print_warning "No backup files found"
        read -p "Press Enter to continue..."
        return
    fi
    
    select backup in $backup_files "Cancel"; do
        if [ "$backup" = "Cancel" ]; then
            return
        fi
        
        if [ -n "$backup" ]; then
            read -p "Confirm restore backup $backup? (y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                cp "$backup" /etc/sysctl.conf
                sysctl -p > /dev/null 2>&1
                print_success "Backup restored: $backup"
            fi
            break
        fi
    done
    
    read -p "Press Enter to continue..."
}

# Main program
main() {
    check_root
    check_kernel
    
    while true; do
        show_menu
        read -p "Please select [0-6]: " choice
        
        case $choice in
            1)
                config_balanced
                apply_config "Balanced Mode"
                read -p "Press Enter to continue..."
                ;;
            2)
                config_gaming
                apply_config "Gaming Priority"
                read -p "Press Enter to continue..."
                ;;
            3)
                config_ultra_low_latency
                apply_config "Ultra Low Latency"
                read -p "Press Enter to continue..."
                ;;
            4)
                config_streaming
                apply_config "Streaming Priority"
                read -p "Press Enter to continue..."
                ;;
            5)
                view_current
                ;;
            6)
                restore_backup
                ;;
            0)
                print_info "Exiting script"
                exit 0
                ;;
            *)
                print_error "Invalid selection, please try again"
                sleep 2
                ;;
        esac
    done
}

# Run main program
main