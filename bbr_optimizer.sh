#!/usr/bin/env bash
# Xray VLESS + XTLS Vision BBR optimizer

set -Eeuo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

readonly CONFIG_FILE='/etc/sysctl.d/90-xray-vision-bbr.conf'
readonly ICMP_CONFIG_FILE='/etc/sysctl.d/91-vps-icmp-policy.conf'
readonly MODULE_FILE='/etc/modules-load.d/xray-vision-bbr.conf'
readonly BACKUP_ROOT='/var/backups/xray-vision-bbr'
readonly LEGACY_SYSCTL_FILE='/etc/sysctl.conf'

TEMP_CONFIG=
LAST_BACKUP_DIR=
PROFILE_NAME=

readonly -a MANAGED_KEYS=(
    net.core.default_qdisc
    net.ipv4.tcp_congestion_control
    net.core.rmem_max
    net.core.wmem_max
    net.ipv4.tcp_rmem
    net.ipv4.tcp_wmem
    net.core.rmem_default
    net.core.wmem_default
    net.ipv4.udp_rmem_min
    net.ipv4.udp_wmem_min
    net.ipv4.tcp_notsent_lowat
    net.ipv4.tcp_limit_output_bytes
    net.ipv4.tcp_slow_start_after_idle
    net.ipv4.tcp_fastopen
    net.ipv4.tcp_moderate_rcvbuf
    net.ipv4.tcp_retries1
    net.ipv4.tcp_retries2
    net.ipv4.tcp_syn_retries
    net.ipv4.tcp_synack_retries
)

print_info() {
    printf '%b[INFO]%b %s\n' "${BLUE}" "${NC}" "$1"
}

print_success() {
    printf '%b[SUCCESS]%b %s\n' "${GREEN}" "${NC}" "$1"
}

print_warning() {
    printf '%b[WARNING]%b %s\n' "${YELLOW}" "${NC}" "$1"
}

print_error() {
    printf '%b[ERROR]%b %s\n' "${RED}" "${NC}" "$1" >&2
}

cleanup() {
    [[ -z "${TEMP_CONFIG}" || ! -f "${TEMP_CONFIG}" ]] || rm -f "${TEMP_CONFIG}"
}

check_root() {
    if [[ ${EUID} -ne 0 ]]; then
        print_error 'This script must be run as root'
        printf 'Please use: sudo %s\n' "$0"
        exit 1
    fi
}

check_linux() {
    if [[ "$(uname -s)" != 'Linux' ]]; then
        print_error 'This script only supports Linux'
        exit 1
    fi
}

check_kernel() {
    local kernel_release kernel_major kernel_minor
    kernel_release=$(uname -r)
    kernel_major=${kernel_release%%.*}
    kernel_minor=${kernel_release#*.}
    kernel_minor=${kernel_minor%%.*}

    print_info "Current kernel: ${kernel_release}"
    if ((kernel_major < 4 || (kernel_major == 4 && kernel_minor < 9))); then
        print_error 'TCP BBR requires Linux kernel 4.9 or newer'
        exit 1
    fi
}

check_commands() {
    local command_name
    for command_name in sysctl modprobe ip awk sed grep mktemp install; do
        if ! command -v "${command_name}" >/dev/null 2>&1; then
            print_error "Required command not found: ${command_name}"
            exit 1
        fi
    done
}

prepare_bbr() {
    local available_algorithms
    if ! modprobe tcp_bbr 2>/dev/null; then
        print_error 'Unable to load tcp_bbr; the current kernel may not include CONFIG_TCP_CONG_BBR'
        return 1
    fi

    available_algorithms=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    if [[ " ${available_algorithms} " != *' bbr '* ]]; then
        print_error "BBR is unavailable. Available algorithms: ${available_algorithms:-unknown}"
        return 1
    fi
    print_success "BBR is available: ${available_algorithms}"
}

show_menu() {
    clear 2>/dev/null || true
    cat <<'EOF'
============================================================
        Xray Vision TCP BBR Optimizer
============================================================

1) Vision Balanced (Recommended)
   - 16 MB socket buffer ceiling
   - 128 KB unsent-data threshold
   - Good balance for CN2 GIA, browsing and streaming

2) Vision Low Latency (Moderately Aggressive)
   - 16 MB socket buffer ceiling
   - 32 KB unsent-data threshold
   - Smaller TCP output queue; may reduce peak throughput

3) Vision High Bandwidth
   - 32 MB socket buffer ceiling
   - 256 KB unsent-data threshold
   - Better for high-bandwidth, high-RTT streaming/downloads

4) Manage ICMP Echo Response
5) View Current Status
6) Restore BBR Backup
0) Exit

Notes:
- Linux TCP BBR applies to VLESS Vision's TCP transport.
- Hysteria2 uses QUIC/UDP and its own congestion controller.
- ICMP echo response is managed separately from BBR profiles.
- This script does not change IP forwarding or unrelated file limits.
============================================================
EOF
}

create_profile() {
    local profile=$1
    local buffer_max notsent_lowat output_limit

    case "${profile}" in
    balanced)
        PROFILE_NAME='Vision Balanced'
        buffer_max=16777216
        notsent_lowat=131072
        output_limit=1048576
        ;;
    latency)
        PROFILE_NAME='Vision Low Latency'
        buffer_max=16777216
        notsent_lowat=32768
        output_limit=262144
        ;;
    bandwidth)
        PROFILE_NAME='Vision High Bandwidth'
        buffer_max=33554432
        notsent_lowat=262144
        output_limit=1048576
        ;;
    *)
        print_error "Unknown profile: ${profile}"
        return 1
        ;;
    esac

    [[ -z "${TEMP_CONFIG}" || ! -f "${TEMP_CONFIG}" ]] || rm -f "${TEMP_CONFIG}"
    TEMP_CONFIG=$(mktemp /tmp/xray-vision-bbr.XXXXXX.conf)
    cat >"${TEMP_CONFIG}" <<EOF
# Managed by bbr_optimizer.sh - ${PROFILE_NAME}
# Remove this file and restore a backup through the script to undo the settings.

# BBR and fair queue pacing for VLESS Vision TCP
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Socket buffer ceilings; memory is allocated on demand, not reserved up front
net.core.rmem_max = ${buffer_max}
net.core.wmem_max = ${buffer_max}
net.ipv4.tcp_rmem = 4096 131072 ${buffer_max}
net.ipv4.tcp_wmem = 4096 65536 ${buffer_max}

# Also provide reasonable defaults for QUIC/UDP services such as Hysteria2
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# Control local TCP queuing without using unsafe retransmission timeouts
net.ipv4.tcp_notsent_lowat = ${notsent_lowat}
net.ipv4.tcp_limit_output_bytes = ${output_limit}

# Long-lived proxy connection behavior
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_moderate_rcvbuf = 1

# Moderately aggressive failure detection; retries2=8 preserves RFC minimum
net.ipv4.tcp_retries1 = 3
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
EOF

}

validate_profile() {
    local key value proc_path
    while IFS='=' read -r key value; do
        key=${key//[[:space:]]/}
        [[ -n "${key}" && "${key}" != \#* ]] || continue
        proc_path="/proc/sys/${key//./\/}"
        if [[ ! -e "${proc_path}" ]]; then
            print_error "The current kernel does not expose sysctl key: ${key}"
            return 1
        fi
    done <"${TEMP_CONFIG}"
}

backup_current_state() {
    local backup_dir timestamp key value
    timestamp=$(date +%Y%m%d_%H%M%S)
    backup_dir="${BACKUP_ROOT}/${timestamp}_$$"
    mkdir -p "${backup_dir}"

    if [[ -f "${CONFIG_FILE}" ]]; then
        cp -a "${CONFIG_FILE}" "${backup_dir}/managed.conf"
        touch "${backup_dir}/had_managed_config"
    fi
    if [[ -f "${MODULE_FILE}" ]]; then
        cp -a "${MODULE_FILE}" "${backup_dir}/modules.conf"
        touch "${backup_dir}/had_module_config"
    fi
    if [[ -f "${LEGACY_SYSCTL_FILE}" ]]; then
        cp -a "${LEGACY_SYSCTL_FILE}" "${backup_dir}/sysctl.conf"
        touch "${backup_dir}/had_sysctl_conf"
    fi

    : >"${backup_dir}/runtime.conf"
    for key in "${MANAGED_KEYS[@]}"; do
        if value=$(sysctl -n "${key}" 2>/dev/null); then
            printf '%s = %s\n' "${key}" "${value}" >>"${backup_dir}/runtime.conf"
        fi
    done

    LAST_BACKUP_DIR=${backup_dir}
    print_success "Backup created: ${backup_dir}"
}

remove_legacy_config() {
    [[ -f "${LEGACY_SYSCTL_FILE}" ]] || return 0
    if grep -q '^# ==================== BBR .* Configuration' "${LEGACY_SYSCTL_FILE}"; then
        sed -i '/^# ==================== BBR .* Configuration/,/^fs\.inotify\.max_user_instances[[:space:]]*=/d' "${LEGACY_SYSCTL_FILE}"
        sed -i '/^[[:space:]]*net\.ipv[46]\.icmp.*echo_ignore_all[[:space:]]*=/d' "${LEGACY_SYSCTL_FILE}"
        print_info 'Removed the legacy optimizer block from /etc/sysctl.conf'
    fi
}

migrate_embedded_icmp_policy() {
    local ipv4_value ipv6_value temporary_icmp
    [[ -f "${CONFIG_FILE}" ]] || return 0
    grep -q 'icmp.*echo_ignore_all' "${CONFIG_FILE}" || return 0

    ipv4_value=$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null || echo 0)
    ipv6_value=$(sysctl -n net.ipv6.icmp.echo_ignore_all 2>/dev/null || echo 0)
    temporary_icmp=$(mktemp /tmp/vps-icmp-policy.XXXXXX.conf)
    {
        printf '# Managed separately by bbr_optimizer.sh\n'
        printf 'net.ipv4.icmp_echo_ignore_all = %s\n' "${ipv4_value}"
        if [[ -e /proc/sys/net/ipv6/icmp/echo_ignore_all ]]; then
            printf 'net.ipv6.icmp.echo_ignore_all = %s\n' "${ipv6_value}"
        fi
    } >"${temporary_icmp}"
    mkdir -p "$(dirname "${ICMP_CONFIG_FILE}")"
    install -m 0644 "${temporary_icmp}" "${ICMP_CONFIG_FILE}"
    sed -i '/^[[:space:]]*net\.ipv[46]\.icmp.*echo_ignore_all[[:space:]]*=/d' "${CONFIG_FILE}"
    rm -f "${temporary_icmp}"
    print_info "Migrated the existing ICMP policy to ${ICMP_CONFIG_FILE}"
}

set_icmp_policy() {
    local value=$1 description old_ipv4 old_ipv6 temporary_icmp old_config apply_output
    if [[ "${value}" == '1' ]]; then
        description='disabled'
    else
        description='enabled'
    fi

    old_ipv4=$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null || echo 0)
    old_ipv6=$(sysctl -n net.ipv6.icmp.echo_ignore_all 2>/dev/null || echo 0)
    temporary_icmp=$(mktemp /tmp/vps-icmp-policy.XXXXXX.conf)
    old_config=$(mktemp /tmp/vps-icmp-policy-backup.XXXXXX.conf)

    if [[ -f "${ICMP_CONFIG_FILE}" ]]; then
        cp -a "${ICMP_CONFIG_FILE}" "${old_config}"
    else
        : >"${old_config}"
    fi

    {
        printf '# Managed separately by bbr_optimizer.sh\n'
        printf 'net.ipv4.icmp_echo_ignore_all = %s\n' "${value}"
        if [[ -e /proc/sys/net/ipv6/icmp/echo_ignore_all ]]; then
            printf 'net.ipv6.icmp.echo_ignore_all = %s\n' "${value}"
        fi
    } >"${temporary_icmp}"

    if ! install -m 0644 "${temporary_icmp}" "${ICMP_CONFIG_FILE}" ||
        ! apply_output=$(sysctl -p "${ICMP_CONFIG_FILE}" 2>&1); then
        print_error "Failed to set ICMP policy: ${apply_output:-file installation failed}"
        if [[ -s "${old_config}" ]]; then
            install -m 0644 "${old_config}" "${ICMP_CONFIG_FILE}"
        else
            rm -f "${ICMP_CONFIG_FILE}"
        fi
        sysctl -w "net.ipv4.icmp_echo_ignore_all=${old_ipv4}" >/dev/null 2>&1 || true
        if [[ -e /proc/sys/net/ipv6/icmp/echo_ignore_all ]]; then
            sysctl -w "net.ipv6.icmp.echo_ignore_all=${old_ipv6}" >/dev/null 2>&1 || true
        fi
        rm -f "${temporary_icmp}" "${old_config}"
        return 1
    fi

    rm -f "${temporary_icmp}" "${old_config}"
    print_success "ICMP echo response is now ${description}"
}

manage_icmp() {
    local ipv4_status ipv6_status choice confirm
    migrate_embedded_icmp_policy
    ipv4_status=$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null || echo 0)
    ipv6_status=$(sysctl -n net.ipv6.icmp.echo_ignore_all 2>/dev/null || echo unavailable)

    printf '\n============================================================\n'
    printf 'ICMP Echo Response Policy\n'
    printf 'IPv4: %s\n' "$([[ "${ipv4_status}" == '1' ]] && echo disabled || echo enabled)"
    if [[ "${ipv6_status}" != 'unavailable' ]]; then
        printf 'IPv6: %s\n' "$([[ "${ipv6_status}" == '1' ]] && echo disabled || echo enabled)"
    fi
    printf '\n1) Disable ICMP echo response\n'
    printf '2) Enable ICMP echo response\n'
    printf '0) Back\n'
    printf '============================================================\n'
    read -r -p 'Please select [0-2]: ' choice

    case "${choice}" in
    1)
        print_warning 'This hides ordinary ping responses but does not prevent port scanning'
        read -r -p 'Disable ICMP echo response? [y/N]: ' confirm
        [[ "${confirm}" =~ ^[Yy]$ ]] && set_icmp_policy 1
        ;;
    2)
        read -r -p 'Enable ICMP echo response? [y/N]: ' confirm
        [[ "${confirm}" =~ ^[Yy]$ ]] && set_icmp_policy 0
        ;;
    0) return 0 ;;
    *)
        print_error 'Invalid selection'
        return 1
        ;;
    esac
}

restore_snapshot() {
    local backup_dir=$1

    if [[ -f "${backup_dir}/had_managed_config" ]]; then
        cp -a "${backup_dir}/managed.conf" "${CONFIG_FILE}"
    else
        rm -f "${CONFIG_FILE}"
    fi

    if [[ -f "${backup_dir}/had_module_config" ]]; then
        cp -a "${backup_dir}/modules.conf" "${MODULE_FILE}"
    else
        rm -f "${MODULE_FILE}"
    fi

    if [[ -f "${backup_dir}/had_sysctl_conf" ]]; then
        cp -a "${backup_dir}/sysctl.conf" "${LEGACY_SYSCTL_FILE}"
    else
        rm -f "${LEGACY_SYSCTL_FILE}"
    fi

    sysctl --system >/dev/null 2>&1 || true
    if [[ -s "${backup_dir}/runtime.conf" ]]; then
        while IFS='=' read -r key value; do
            key=${key//[[:space:]]/}
            [[ -n "${key}" && "${key}" != *icmp*echo_ignore_all* ]] || continue
            sysctl -w "${key}=${value# }" >/dev/null 2>&1 || true
        done <"${backup_dir}/runtime.conf"
    fi
}

apply_profile() {
    local profile=$1 profile_name confirm apply_output

    create_profile "${profile}" || return 1
    profile_name=${PROFILE_NAME}
    validate_profile || return 1

    printf '\nConfiguration to be installed at %s:\n\n' "${CONFIG_FILE}"
    sed -n '1,240p' "${TEMP_CONFIG}"
    printf '\n'
    read -r -p "Apply ${profile_name}? [y/N]: " confirm
    if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
        print_warning 'Configuration cancelled'
        return 0
    fi

    prepare_bbr || return 1
    migrate_embedded_icmp_policy
    backup_current_state
    if ! remove_legacy_config ||
        ! mkdir -p "$(dirname "${CONFIG_FILE}")" "$(dirname "${MODULE_FILE}")" ||
        ! install -m 0644 "${TEMP_CONFIG}" "${CONFIG_FILE}" ||
        ! printf 'tcp_bbr\n' >"${MODULE_FILE}"; then
        print_error 'Failed to install the persistent BBR configuration'
        print_warning 'Restoring the pre-change state'
        restore_snapshot "${LAST_BACKUP_DIR}"
        return 1
    fi

    if ! apply_output=$(sysctl -p "${CONFIG_FILE}" 2>&1); then
        print_error 'Failed to apply the new sysctl configuration:'
        printf '%s\n' "${apply_output}" >&2
        print_warning 'Restoring the pre-change state'
        restore_snapshot "${LAST_BACKUP_DIR}"
        return 1
    fi

    print_success "${profile_name} applied"
    verify_status
}

get_default_interface() {
    local interface_name
    interface_name=$(ip -4 route show default 2>/dev/null | awk '/default/ {for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')
    if [[ -z "${interface_name}" ]]; then
        interface_name=$(ip -6 route show default 2>/dev/null | awk '/default/ {for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')
    fi
    printf '%s\n' "${interface_name}"
}

verify_status() {
    local interface_name qdisc_status bbr_module
    interface_name=$(get_default_interface)
    bbr_module=
    if command -v lsmod >/dev/null 2>&1; then
        bbr_module=$(lsmod 2>/dev/null | awk '$1 == "tcp_bbr" {print $1; exit}' || true)
    fi

    printf '\n============================================================\n'
    printf 'Kernel:              %s\n' "$(uname -r)"
    printf 'BBR module:          %s\n' "${bbr_module:-built-in or not shown}"
    printf 'Available CC:        %s\n' "$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo unknown)"
    printf 'Configured CC:       %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
    printf 'Default qdisc:       %s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
    printf 'tcp_notsent_lowat:   %s bytes\n' "$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null || echo unknown)"
    printf 'tcp output limit:    %s bytes\n' "$(sysctl -n net.ipv4.tcp_limit_output_bytes 2>/dev/null || echo unknown)"
    printf 'Receive buffer max:  %s bytes\n' "$(sysctl -n net.core.rmem_max 2>/dev/null || echo unknown)"
    printf 'Send buffer max:     %s bytes\n' "$(sysctl -n net.core.wmem_max 2>/dev/null || echo unknown)"
    if [[ "$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null || echo 0)" == '1' ]]; then
        printf 'ICMP echo response:  disabled\n'
    else
        printf 'ICMP echo response:  enabled\n'
    fi

    if [[ -n "${interface_name}" ]] && command -v tc >/dev/null 2>&1; then
        qdisc_status=$(tc qdisc show dev "${interface_name}" 2>/dev/null || true)
        printf 'Active qdisc (%s):\n%s\n' "${interface_name}" "${qdisc_status:-unknown}"
        if [[ "${qdisc_status}" != *'qdisc fq '* ]]; then
            print_warning 'The active interface has not adopted fq yet; a reboot may be required'
        fi
    fi
    printf '============================================================\n\n'
}

restore_backup() {
    local -a backups=()
    local backup selection confirm

    if [[ -d "${BACKUP_ROOT}" ]]; then
        while IFS= read -r backup; do
            backups+=("${backup}")
        done < <(find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d | sort -r)
    fi

    if ((${#backups[@]} == 0)); then
        print_warning 'No optimizer backups found'
        return 0
    fi

    printf '\nAvailable backups:\n'
    for selection in "${!backups[@]}"; do
        printf '%d) %s\n' "$((selection + 1))" "${backups[selection]}"
    done
    printf '0) Cancel\n'
    read -r -p 'Select backup: ' selection
    if [[ "${selection}" == '0' ]]; then
        return 0
    fi
    if [[ ! "${selection}" =~ ^[0-9]+$ ]] || ((selection < 1 || selection > ${#backups[@]})); then
        print_error 'Invalid backup selection'
        return 1
    fi

    backup=${backups[selection - 1]}
    read -r -p "Restore ${backup}? [y/N]: " confirm
    if [[ "${confirm}" =~ ^[Yy]$ ]]; then
        restore_snapshot "${backup}"
        print_success "Backup restored: ${backup}"
        verify_status
    fi
}

main() {
    local choice
    trap cleanup EXIT
    check_root
    check_linux
    check_kernel
    check_commands

    while true; do
        show_menu
        read -r -p 'Please select [0-6]: ' choice
        case "${choice}" in
        1) apply_profile balanced || true ;;
        2) apply_profile latency || true ;;
        3) apply_profile bandwidth || true ;;
        4) manage_icmp || true ;;
        5) verify_status ;;
        6) restore_backup || true ;;
        0)
            print_info 'Exiting script'
            return 0
            ;;
        *)
            print_error 'Invalid selection'
            sleep 1
            ;;
        esac
        read -r -p 'Press Enter to continue...'
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
