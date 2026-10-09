#!/usr/bin/env bash
# BBR optimizer

set -Eeuo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

readonly CONFIG_FILE='/etc/sysctl.d/90-bbr-optimizer.conf'
readonly ICMP_CONFIG_FILE='/etc/sysctl.d/91-vps-icmp-policy.conf'
readonly IPV6_CONFIG_FILE='/etc/sysctl.d/92-vps-ipv6-policy.conf'
readonly MODULE_FILE='/etc/modules-load.d/bbr-optimizer.conf'
readonly BACKUP_ROOT='/var/backups/bbr-optimizer'
readonly OLD_CONFIG_FILE='/etc/sysctl.d/90-xray-vision-bbr.conf'
readonly OLD_MODULE_FILE='/etc/modules-load.d/xray-vision-bbr.conf'
readonly OLD_BACKUP_ROOT='/var/backups/xray-vision-bbr'
readonly LEGACY_SYSCTL_FILE='/etc/sysctl.conf'

# Files captured by backup_current_state and put back by restore_snapshot.
# Format: <live path>|<copy name inside the backup dir>|<presence marker name>
readonly -a SNAPSHOT_FILES=(
    "${CONFIG_FILE}|managed.conf|had_managed_config"
    "${OLD_CONFIG_FILE}|old-managed.conf|had_old_managed_config"
    "${MODULE_FILE}|modules.conf|had_module_config"
    "${OLD_MODULE_FILE}|old-modules.conf|had_old_module_config"
    "${LEGACY_SYSCTL_FILE}|sysctl.conf|had_sysctl_conf"
)

# Seconds the operator has to confirm that disabling IPv6 did not cut access
# before it is reverted automatically. 0 disables the timed rollback.
IPV6_ROLLBACK_SECONDS=${BBR_IPV6_ROLLBACK_SECONDS:-60}
# Extra delay before the detached watchdog reverts, so an answer typed at the
# very end of the prompt cannot race with it.
readonly ROLLBACK_GRACE_SECONDS=5

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
    net.ipv4.tcp_recovery
    net.ipv4.tcp_early_retrans
    net.ipv4.tcp_thin_linear_timeouts
    net.ipv4.tcp_mtu_probing
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
                    BBR Optimizer
============================================================

1) Balanced (Recommended)
   - 16 MB socket buffer ceiling
   - 128 KB unsent-data threshold
   - Good balance for general-purpose VPS traffic

2) Low Latency (Moderately Aggressive)
   - 16 MB socket buffer ceiling
   - 32 KB unsent-data threshold
   - Smaller TCP output queue; may reduce peak throughput

3) High Bandwidth
   - 32 MB socket buffer ceiling
   - 256 KB unsent-data threshold
   - Better for high-bandwidth, high-RTT streaming/downloads

4) Manage ICMP Echo Response
5) Manage IPv6
6) View Current Status
7) Restore BBR Backup
0) Exit
============================================================
EOF
}

create_profile() {
    local profile=$1
    local buffer_max notsent_lowat output_limit

    case "${profile}" in
        balanced)
            PROFILE_NAME='Balanced'
            buffer_max=16777216
            notsent_lowat=131072
            output_limit=1048576
            ;;
        latency)
            PROFILE_NAME='Low Latency'
            buffer_max=16777216
            notsent_lowat=32768
            output_limit=262144
            ;;
        bandwidth)
            PROFILE_NAME='High Bandwidth'
            buffer_max=33554432
            notsent_lowat=262144
            output_limit=1048576
            ;;
        *)
            print_error "Unknown profile: ${profile}"
            return 1
            ;;
    esac

    cleanup
    TEMP_CONFIG=$(mktemp "${TMPDIR:-/tmp}/bbr-optimizer.XXXXXX")
    cat >"${TEMP_CONFIG}" <<EOF
# Managed by bbr_optimizer.sh - ${PROFILE_NAME}
# Remove this file and restore a backup through the script to undo the settings.

# BBR and fair queue pacing for TCP
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

# Control local TCP queuing
net.ipv4.tcp_notsent_lowat = ${notsent_lowat}
net.ipv4.tcp_limit_output_bytes = ${output_limit}

# TCP connection behavior
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_moderate_rcvbuf = 1

# Tolerate transient packet loss without abandoning connections too early
net.ipv4.tcp_retries1 = 3
net.ipv4.tcp_retries2 = 12
net.ipv4.tcp_syn_retries = 4
net.ipv4.tcp_synack_retries = 4
EOF

    # These recovery controls are common to all profiles. Keep older BBR-capable
    # kernels usable by writing only the sysctls they actually expose.
    printf '\n# Aggressive loss recovery (enabled when supported by the kernel)\n' >>"${TEMP_CONFIG}"
    append_supported_sysctl net.ipv4.tcp_recovery 1
    append_supported_sysctl net.ipv4.tcp_early_retrans 3
    append_supported_sysctl net.ipv4.tcp_thin_linear_timeouts 1
    append_supported_sysctl net.ipv4.tcp_mtu_probing 1
}

append_supported_sysctl() {
    local key=$1 value=$2 proc_path
    proc_path="/proc/sys/${key//./\/}"
    if [[ -e "${proc_path}" ]]; then
        printf '%s = %s\n' "${key}" "${value}" >>"${TEMP_CONFIG}"
    fi
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
    local backup_dir timestamp key value entry live_path copy_name marker
    timestamp=$(date +%Y%m%d_%H%M%S)
    backup_dir="${BACKUP_ROOT}/${timestamp}_$$"
    if ! mkdir -p "${backup_dir}"; then
        print_error "Unable to create backup directory: ${backup_dir}"
        return 1
    fi

    for entry in "${SNAPSHOT_FILES[@]}"; do
        IFS='|' read -r live_path copy_name marker <<<"${entry}"
        [[ -f "${live_path}" ]] || continue
        if ! cp -a "${live_path}" "${backup_dir}/${copy_name}" \
            || ! touch "${backup_dir}/${marker}"; then
            print_error "Unable to back up ${live_path}"
            return 1
        fi
    done

    if ! : >"${backup_dir}/runtime.conf"; then
        print_error "Unable to write ${backup_dir}/runtime.conf"
        return 1
    fi
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

# Usage: write_policy_file FILE KEY=VALUE...
write_policy_file() {
    local file=$1 entry
    shift
    {
        printf '# Managed separately by bbr_optimizer.sh\n'
        for entry in "$@"; do
            printf '%s = %s\n' "${entry%%=*}" "${entry#*=}"
        done
    } >"${file}"
}

migrate_embedded_icmp_policy() {
    local temporary_icmp managed_config
    local -a settings=()
    managed_config=${CONFIG_FILE}
    [[ -f "${managed_config}" ]] || managed_config=${OLD_CONFIG_FILE}
    [[ -f "${managed_config}" ]] || return 0
    grep -q 'icmp.*echo_ignore_all' "${managed_config}" || return 0

    settings=("net.ipv4.icmp_echo_ignore_all=$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null || echo 0)")
    if [[ -e /proc/sys/net/ipv6/icmp/echo_ignore_all ]]; then
        settings+=("net.ipv6.icmp.echo_ignore_all=$(sysctl -n net.ipv6.icmp.echo_ignore_all 2>/dev/null || echo 0)")
    fi
    temporary_icmp=$(mktemp "${TMPDIR:-/tmp}/vps-icmp-policy.XXXXXX") || return 1
    write_policy_file "${temporary_icmp}" "${settings[@]}"
    # Only strip the embedded keys once the standalone policy file is in place.
    if ! mkdir -p "$(dirname "${ICMP_CONFIG_FILE}")" \
        || ! install -m 0644 "${temporary_icmp}" "${ICMP_CONFIG_FILE}"; then
        rm -f "${temporary_icmp}"
        print_error "Unable to migrate the ICMP policy to ${ICMP_CONFIG_FILE}"
        return 1
    fi
    sed -i '/^[[:space:]]*net\.ipv[46]\.icmp.*echo_ignore_all[[:space:]]*=/d' "${managed_config}"
    rm -f "${temporary_icmp}"
    print_info "Migrated the existing ICMP policy to ${ICMP_CONFIG_FILE}"
}

# Usage: restore_sysctl_policy CONFIG_FILE STATE_DIR
# Reverts a change made by apply_sysctl_policy: puts back the previous policy
# file (or removes it if there was none) and the previous runtime values.
restore_sysctl_policy() {
    local config_file=$1 state_dir=$2 key value
    if [[ -f "${state_dir}/previous.conf" ]]; then
        install -m 0644 "${state_dir}/previous.conf" "${config_file}" || true
    else
        rm -f "${config_file}"
    fi
    if [[ -f "${state_dir}/runtime.conf" ]]; then
        while IFS='=' read -r key value; do
            [[ -n "${key}" ]] || continue
            sysctl -w "${key}=${value}" >/dev/null 2>&1 || true
        done <"${state_dir}/runtime.conf"
    fi
}

# Usage: start_rollback_watchdog CONFIG_FILE STATE_DIR SECONDS
# Starts a detached process that ignores SIGHUP/SIGINT and reverts the policy
# after SECONDS plus a grace period, even if the SSH session (and this script
# with it) is lost. Sets ROLLBACK_WATCHDOG_PID.
start_rollback_watchdog() {
    local config_file=$1 state_dir=$2 seconds=$3
    (
        trap '' HUP INT
        sleep "$((seconds + ROLLBACK_GRACE_SECONDS))"
        restore_sysctl_policy "${config_file}" "${state_dir}"
        rm -rf "${state_dir}"
    ) </dev/null >/dev/null 2>&1 &
    ROLLBACK_WATCHDOG_PID=$!
}

stop_rollback_watchdog() {
    kill "$1" 2>/dev/null || return 1
    wait "$1" 2>/dev/null || true
}

# Usage: confirm_or_rollback CONFIG_FILE STATE_DIR SECONDS LABEL WATCHDOG_PID
# Keeps a just-applied policy only if the operator types "keep" in time;
# otherwise reverts it now (or lets the already-fired watchdog's revert stand).
confirm_or_rollback() {
    local config_file=$1 state_dir=$2 seconds=$3 label=$4 watchdog_pid=$5 answer=''

    print_warning "The ${label} change will be reverted automatically in ${seconds} seconds unless you confirm it."
    print_warning 'Check from a NEW SSH session that the host is still reachable before confirming.'
    read -r -t "${seconds}" -p "Type 'keep' to keep it (anything else reverts now): " answer || true

    if [[ "${answer}" == 'keep' ]] && stop_rollback_watchdog "${watchdog_pid}"; then
        rm -rf "${state_dir}"
        return 0
    fi

    if stop_rollback_watchdog "${watchdog_pid}"; then
        restore_sysctl_policy "${config_file}" "${state_dir}"
        rm -rf "${state_dir}"
    else
        # The watchdog already fired and reverted the change.
        wait "${watchdog_pid}" 2>/dev/null || true
    fi
    print_warning "${label} change reverted"
    return 1
}

# Usage: apply_sysctl_policy CONFIG_FILE LABEL ROLLBACK_SECONDS KEY=VALUE...
# Installs CONFIG_FILE with the given settings and applies it immediately. On
# failure the previous file and runtime values are restored. With
# ROLLBACK_SECONDS > 0 the change must also be confirmed within that time.
apply_sysctl_policy() {
    local config_file=$1 label=$2 rollback_seconds=$3 state_dir entry key apply_output watchdog_pid=''
    shift 3

    state_dir=$(mktemp -d "${TMPDIR:-/tmp}/bbr-optimizer-policy.XXXXXX") || return 1
    if [[ -f "${config_file}" ]] && ! cp -p "${config_file}" "${state_dir}/previous.conf"; then
        print_error "Unable to back up ${config_file}"
        rm -rf "${state_dir}"
        return 1
    fi
    : >"${state_dir}/runtime.conf"
    for entry in "$@"; do
        key=${entry%%=*}
        printf '%s=%s\n' "${key}" "$(sysctl -n "${key}" 2>/dev/null || echo 0)" >>"${state_dir}/runtime.conf"
    done
    write_policy_file "${state_dir}/new.conf" "$@"

    # Arm the watchdog before changing anything, so there is no moment in
    # which a dropped session would leave the change in place.
    if ((rollback_seconds > 0)); then
        start_rollback_watchdog "${config_file}" "${state_dir}" "${rollback_seconds}"
        watchdog_pid=${ROLLBACK_WATCHDOG_PID}
    fi

    if ! mkdir -p "$(dirname "${config_file}")" \
        || ! install -m 0644 "${state_dir}/new.conf" "${config_file}" \
        || ! apply_output=$(sysctl -p "${config_file}" 2>&1); then
        [[ -z "${watchdog_pid}" ]] || stop_rollback_watchdog "${watchdog_pid}" || true
        print_error "Failed to set ${label}: ${apply_output:-file installation failed}"
        restore_sysctl_policy "${config_file}" "${state_dir}"
        rm -rf "${state_dir}"
        return 1
    fi

    if ((rollback_seconds > 0)); then
        confirm_or_rollback "${config_file}" "${state_dir}" "${rollback_seconds}" "${label}" "${watchdog_pid}"
        return
    fi
    rm -rf "${state_dir}"
}

set_icmp_policy() {
    local value=$1 description=enabled
    local -a settings=("net.ipv4.icmp_echo_ignore_all=${value}")
    [[ "${value}" != '1' ]] || description=disabled
    if [[ -e /proc/sys/net/ipv6/icmp/echo_ignore_all ]]; then
        settings+=("net.ipv6.icmp.echo_ignore_all=${value}")
    fi

    apply_sysctl_policy "${ICMP_CONFIG_FILE}" 'ICMP policy' 0 "${settings[@]}" || return 1
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

# Prints the client address of the current SSH session, if known.
ssh_client_address() {
    local connection=${SSH_CONNECTION:-${SSH_CLIENT:-}}
    printf '%s\n' "${connection%% *}"
}

# IPv4-mapped addresses (::ffff:a.b.c.d) are IPv4 connections.
is_ipv6_address() {
    local address=$1
    [[ "${address}" == *:* && "${address}" != ::ffff:*.* && "${address}" != ::FFFF:*.* ]]
}

# Prints peer addresses of established sshd connections. Used when the SSH_*
# variables are missing, e.g. because sudo stripped them.
sshd_peer_addresses() {
    local peer
    command -v ss >/dev/null 2>&1 || return 0
    ss -tnp state established 2>/dev/null | awk '/"sshd/ {print $4}' \
        | while IFS= read -r peer; do
            peer=${peer%:*}
            peer=${peer#\[}
            printf '%s\n' "${peer%]}"
        done
}

# Returns 1 (with an explanation) when disabling IPv6 could lock the operator
# out: the SSH session runs over IPv6, or there is no IPv4 default route.
check_ipv6_disable_safe() {
    local client peer
    client=$(ssh_client_address)
    if [[ -n "${client}" ]]; then
        if is_ipv6_address "${client}"; then
            print_error "Refusing to disable IPv6: this SSH session is connected over IPv6 (${client})."
            print_error 'Disabling IPv6 would cut this session and the setting persists across reboots.'
            return 1
        fi
    else
        while IFS= read -r peer; do
            if is_ipv6_address "${peer}"; then
                print_error "Refusing to disable IPv6: an SSH session is connected over IPv6 (${peer})."
                return 1
            fi
        done < <(sshd_peer_addresses)
    fi

    if [[ -z "$(ip -4 route show default 2>/dev/null)" ]]; then
        print_error 'Refusing to disable IPv6: this host has no IPv4 default route.'
        print_error 'It would lose network access (and remote access) until IPv6 is re-enabled locally.'
        return 1
    fi
}

set_ipv6_policy() {
    local value=$1 description=enabled rollback_seconds=0
    if [[ "${value}" == '1' ]]; then
        description=disabled
        check_ipv6_disable_safe || return 1
        rollback_seconds=${IPV6_ROLLBACK_SECONDS}
        if [[ ! "${rollback_seconds}" =~ ^[0-9]+$ ]]; then
            print_warning "Ignoring invalid BBR_IPV6_ROLLBACK_SECONDS='${rollback_seconds}'; using 60"
            rollback_seconds=60
        fi
    fi

    apply_sysctl_policy "${IPV6_CONFIG_FILE}" 'IPv6 policy' "${rollback_seconds}" \
        "net.ipv6.conf.all.disable_ipv6=${value}" \
        "net.ipv6.conf.default.disable_ipv6=${value}" || return 1
    print_success "IPv6 is now ${description}"
}

manage_ipv6() {
    local all_status default_status choice confirm

    if [[ ! -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ||
        ! -e /proc/sys/net/ipv6/conf/default/disable_ipv6 ]]; then
        print_warning 'This kernel does not expose the IPv6 disable controls'
        return 0
    fi

    all_status=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo unknown)
    default_status=$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo unknown)

    printf '\n============================================================\n'
    printf 'IPv6 Policy\n'
    if [[ "${all_status}" == '1' && "${default_status}" == '1' ]]; then
        printf 'Status: disabled\n'
    else
        printf 'Status: enabled\n'
    fi
    printf '\n1) Disable IPv6 system-wide\n'
    printf '2) Enable IPv6 system-wide\n'
    printf '0) Back\n'
    printf '============================================================\n'
    read -r -p 'Please select [0-2]: ' choice

    case "${choice}" in
        1)
            print_warning 'Disabling IPv6 immediately interrupts IPv6 connections and may affect IPv6-only services'
            print_info 'It is refused for IPv6 SSH sessions or hosts without an IPv4 default route, and reverts automatically unless confirmed'
            read -r -p 'Disable IPv6 system-wide? [y/N]: ' confirm
            [[ "${confirm}" =~ ^[Yy]$ ]] && set_ipv6_policy 1
            ;;
        2)
            read -r -p 'Enable IPv6 system-wide? [y/N]: ' confirm
            [[ "${confirm}" =~ ^[Yy]$ ]] && set_ipv6_policy 0
            ;;
        0) return 0 ;;
        *)
            print_error 'Invalid selection'
            return 1
            ;;
    esac
}

# Puts the files and runtime values recorded in a backup back in place.
# Returns 1 if anything could not be restored.
restore_snapshot() {
    local backup_dir=$1 entry live_path copy_name marker key value failed=0

    # Every backup written by this script (and its xray-vision-bbr predecessor)
    # has runtime.conf; refuse anything else rather than deleting live files.
    if [[ ! -f "${backup_dir}/runtime.conf" ]]; then
        print_error "Not an optimizer backup (runtime.conf missing): ${backup_dir}"
        return 1
    fi

    for entry in "${SNAPSHOT_FILES[@]}"; do
        IFS='|' read -r live_path copy_name marker <<<"${entry}"
        if [[ -f "${backup_dir}/${marker}" ]]; then
            cp -a "${backup_dir}/${copy_name}" "${live_path}" || failed=1
        else
            rm -f "${live_path}" || failed=1
        fi
    done

    sysctl --system >/dev/null 2>&1 || true
    if [[ -s "${backup_dir}/runtime.conf" ]]; then
        while IFS='=' read -r key value; do
            key=${key//[[:space:]]/}
            [[ -n "${key}" && "${key}" != *icmp*echo_ignore_all* ]] || continue
            sysctl -w "${key}=${value# }" >/dev/null 2>&1 || true
        done <"${backup_dir}/runtime.conf"
    fi

    if ((failed)); then
        print_error "Some files could not be restored from ${backup_dir}"
        return 1
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
    migrate_embedded_icmp_policy || return 1
    if ! backup_current_state; then
        print_error 'No changes were made because the backup could not be created'
        return 1
    fi
    if ! remove_legacy_config \
        || ! mkdir -p "$(dirname "${CONFIG_FILE}")" "$(dirname "${MODULE_FILE}")" \
        || ! rm -f "${OLD_CONFIG_FILE}" "${OLD_MODULE_FILE}" \
        || ! install -m 0644 "${TEMP_CONFIG}" "${CONFIG_FILE}" \
        || ! printf 'tcp_bbr\n' >"${MODULE_FILE}"; then
        print_error 'Failed to install the persistent BBR configuration'
        print_warning 'Restoring the pre-change state'
        restore_snapshot "${LAST_BACKUP_DIR}" || true
        return 1
    fi

    if ! apply_output=$(sysctl -p "${CONFIG_FILE}" 2>&1); then
        print_error 'Failed to apply the new sysctl configuration:'
        printf '%s\n' "${apply_output}" >&2
        print_warning 'Restoring the pre-change state'
        restore_snapshot "${LAST_BACKUP_DIR}" || true
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
    local interface_name qdisc_status bbr_module ipv6_all ipv6_default
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
    printf 'TCP retries2:        %s\n' "$(sysctl -n net.ipv4.tcp_retries2 2>/dev/null || echo unknown)"
    printf 'RACK recovery:       %s\n' "$(sysctl -n net.ipv4.tcp_recovery 2>/dev/null || echo unavailable)"
    printf 'Tail loss probe:     %s\n' "$(sysctl -n net.ipv4.tcp_early_retrans 2>/dev/null || echo unavailable)"
    printf 'Thin stream recovery: %s\n' "$(sysctl -n net.ipv4.tcp_thin_linear_timeouts 2>/dev/null || echo unavailable)"
    printf 'TCP MTU probing:     %s\n' "$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo unavailable)"
    printf 'Receive buffer max:  %s bytes\n' "$(sysctl -n net.core.rmem_max 2>/dev/null || echo unknown)"
    printf 'Send buffer max:     %s bytes\n' "$(sysctl -n net.core.wmem_max 2>/dev/null || echo unknown)"
    if [[ "$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null || echo 0)" == '1' ]]; then
        printf 'ICMP echo response:  disabled\n'
    else
        printf 'ICMP echo response:  enabled\n'
    fi
    ipv6_all=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo unavailable)
    ipv6_default=$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo unavailable)
    if [[ "${ipv6_all}" == 'unavailable' || "${ipv6_default}" == 'unavailable' ]]; then
        printf 'IPv6:               unavailable\n'
    elif [[ "${ipv6_all}" == '1' && "${ipv6_default}" == '1' ]]; then
        printf 'IPv6:               disabled\n'
    else
        printf 'IPv6:               enabled\n'
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

    while IFS= read -r backup; do
        [[ -n "${backup}" ]] && backups+=("${backup}")
    done < <(
        {
            [[ ! -d "${BACKUP_ROOT}" ]] || find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d
            [[ ! -d "${OLD_BACKUP_ROOT}" ]] || find "${OLD_BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d
        } | sort -r
    )

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
        if ! restore_snapshot "${backup}"; then
            print_error "Backup restore was incomplete: ${backup}"
            return 1
        fi
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
        read -r -p 'Please select [0-7]: ' choice
        case "${choice}" in
            1) apply_profile balanced || true ;;
            2) apply_profile latency || true ;;
            3) apply_profile bandwidth || true ;;
            4) manage_icmp || true ;;
            5) manage_ipv6 || true ;;
            6) verify_status ;;
            7) restore_backup || true ;;
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
