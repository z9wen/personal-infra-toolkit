#!/usr/bin/env bash
# Offline tests for bbr_optimizer.sh. sysctl, ip, ss and install are stubs on
# PATH that only touch a temp directory; nothing changes the real system.
#
# Each test runs in a fresh bash process via "$0 --run-one <test>".
# Works with bash 3.2 and bash 5.

set -u

SELF="$0"
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="${REPO_ROOT}/bbr_optimizer.sh"
TEST_BASH=${BASH:-bash}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    grep -qF -- "$2" "$1" || {
        echo "--- $1 ---" >&2
        cat "$1" >&2
        fail "expected '$2' in $1"
    }
}

assert_not_contains() {
    if grep -qF -- "$2" "$1"; then
        echo "--- $1 ---" >&2
        cat "$1" >&2
        fail "did not expect '$2' in $1"
    fi
}

# Current value of a key in the fake sysctl state (last write wins).
state_value() {
    awk -v k="$1" 'index($0, k "=") == 1 {v = substr($0, length(k) + 2)} END {print v}' "$SYSCTL_STATE"
}

setup_env() {
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/test_bbr.XXXXXX")
    trap 'rm -rf "$WORK"' EXIT
    export STUB_LOG="$WORK/calls.log" SYSCTL_STATE="$WORK/sysctl.state"
    : >"$STUB_LOG"
    printf '%s\n' 'net.ipv6.conf.all.disable_ipv6=0' 'net.ipv6.conf.default.disable_ipv6=0' >"$SYSCTL_STATE"
    mkdir -p "$WORK/bin"

    cat >"$WORK/bin/sysctl" <<'EOF'
#!/usr/bin/env bash
echo "sysctl $*" >>"$STUB_LOG"
case "$1" in
    -n)
        awk -v k="$2" 'index($0, k "=") == 1 {v = substr($0, length(k) + 2); f = 1}
            END {if (!f) exit 1; print v}' "$SYSCTL_STATE"
        ;;
    -w) printf '%s\n' "$2" >>"$SYSCTL_STATE" ;;
    -p)
        if [[ -n "${SYSCTL_FAIL_P:-}" ]]; then
            echo "sysctl: setting key: Operation not permitted" >&2
            exit 255
        fi
        while IFS= read -r line; do
            case "$line" in '#'* | '') continue ;; esac
            key=${line%%=*}
            value=${line#*=}
            printf '%s=%s\n' "${key// /}" "${value# }" >>"$SYSCTL_STATE"
        done <"$2"
        ;;
esac
EOF
    cat >"$WORK/bin/ip" <<'EOF'
#!/bin/sh
echo "ip $*" >>"$STUB_LOG"
if [ "$1 $2 $3" = "-4 route show" ]; then
    printf '%s' "${IP4_DEFAULT_ROUTE:-}"
fi
EOF
    cat >"$WORK/bin/ss" <<'EOF'
#!/bin/sh
printf '%s' "${SS_OUTPUT:-}"
EOF
    # install -m MODE SRC DST, restricted to the test directory.
    cat >"$WORK/bin/install" <<'EOF'
#!/bin/sh
echo "install $*" >>"$STUB_LOG"
case "$4" in "$TEST_WORK"/*) cp "$3" "$4" ;; *) echo "refusing to write $4" >&2; exit 1 ;; esac
EOF
    chmod +x "$WORK/bin/"*
    export PATH="$WORK/bin:$PATH" TEST_WORK="$WORK"
    unset SSH_CONNECTION SSH_CLIENT SS_OUTPUT IP4_DEFAULT_ROUTE SYSCTL_FAIL_P
    export IP4_DEFAULT_ROUTE='default via 203.0.113.1 dev eth0'

    # shellcheck source=../bbr_optimizer.sh
    source "$SCRIPT"
}

expect_ipv6_disable_refused() {
    local reason=$1
    if set_ipv6_policy 1 >"$WORK/out" 2>&1; then
        fail "disabling IPv6 should be refused ($reason)"
    fi
    assert_contains "$WORK/out" "Refusing to disable IPv6"
    assert_not_contains "$STUB_LOG" "sysctl -p"
    assert_not_contains "$STUB_LOG" "sysctl -w"
    assert_not_contains "$STUB_LOG" "install "
    [[ "$(state_value net.ipv6.conf.all.disable_ipv6)" == 0 ]] || fail "IPv6 runtime value changed"
}

test_refuses_ipv6_ssh_session() {
    setup_env
    export SSH_CONNECTION='2001:db8::10 50022 2001:db8::1 22'
    expect_ipv6_disable_refused "IPv6 SSH_CONNECTION"
    assert_contains "$WORK/out" "2001:db8::10"
}

test_refuses_ipv6_ssh_client_var() {
    setup_env
    export SSH_CLIENT='2001:db8::10 50022 22'
    expect_ipv6_disable_refused "IPv6 SSH_CLIENT"
}

test_refuses_without_ipv4_default_route() {
    setup_env
    export SSH_CONNECTION='198.51.100.7 50022 203.0.113.5 22'
    export IP4_DEFAULT_ROUTE=''
    expect_ipv6_disable_refused "no IPv4 default route"
    assert_contains "$WORK/out" "no IPv4 default route"
}

test_refuses_ipv6_sshd_peer_when_env_stripped() {
    setup_env
    export SS_OUTPUT='0 0 [2001:db8::1]:22 [2001:db8::10]:50022 users:(("sshd",pid=10,fd=4))
'
    expect_ipv6_disable_refused "IPv6 sshd peer from ss"
}

test_allows_ipv4_session_with_route() {
    setup_env
    export SSH_CONNECTION='198.51.100.7 50022 203.0.113.5 22'
    check_ipv6_disable_safe >"$WORK/out" 2>&1 || fail "IPv4 session with IPv4 route should be allowed"
    export SSH_CONNECTION='::ffff:198.51.100.7 50022 ::ffff:203.0.113.5 22'
    check_ipv6_disable_safe >"$WORK/out" 2>&1 || fail "IPv4-mapped session should count as IPv4"
    unset SSH_CONNECTION
    export SS_OUTPUT='0 0 [::ffff:203.0.113.5]:22 [::ffff:198.51.100.7]:50022 users:(("sshd",pid=10,fd=4))
0 0 203.0.113.5:22 198.51.100.8:50023 users:(("sshd-session",pid=11,fd=4))
'
    check_ipv6_disable_safe >"$WORK/out" 2>&1 || fail "IPv4 sshd peers should be allowed"
}

test_policy_apply_without_rollback() {
    setup_env
    local conf="$WORK/sysctl.d/92-test.conf"
    apply_sysctl_policy "$conf" 'IPv6 policy' 0 \
        net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1 >"$WORK/out" 2>&1 \
        || fail "apply_sysctl_policy failed"
    assert_contains "$conf" "net.ipv6.conf.all.disable_ipv6 = 1"
    assert_contains "$conf" "# Managed separately by bbr_optimizer.sh"
    [[ "$(state_value net.ipv6.conf.all.disable_ipv6)" == 1 ]] || fail "value not applied"
}

test_policy_failure_restores_previous_state() {
    setup_env
    local conf="$WORK/92-test.conf"
    printf 'previous policy\n' >"$conf"
    export SYSCTL_FAIL_P=1
    if apply_sysctl_policy "$conf" 'IPv6 policy' 0 net.ipv6.conf.all.disable_ipv6=1 >"$WORK/out" 2>&1; then
        fail "apply should fail when sysctl -p fails"
    fi
    assert_contains "$WORK/out" "Failed to set IPv6 policy"
    assert_contains "$conf" "previous policy"
    assert_contains "$STUB_LOG" "sysctl -w net.ipv6.conf.all.disable_ipv6=0"
}

test_policy_failure_removes_new_file() {
    setup_env
    local conf="$WORK/92-test.conf"
    export SYSCTL_FAIL_P=1
    apply_sysctl_policy "$conf" 'ICMP policy' 0 net.ipv4.icmp_echo_ignore_all=1 >/dev/null 2>&1 \
        && fail "apply should fail"
    [[ ! -e "$conf" ]] || fail "new policy file must be removed when it did not exist before"
}

test_timed_rollback_keep() {
    setup_env
    local conf="$WORK/92-test.conf"
    printf 'keep\n' >"$WORK/in"
    apply_sysctl_policy "$conf" 'IPv6 policy' 2 net.ipv6.conf.all.disable_ipv6=1 <"$WORK/in" >"$WORK/out" 2>&1 \
        || fail "confirmed change should succeed"
    sleep 1
    assert_contains "$conf" "net.ipv6.conf.all.disable_ipv6 = 1"
    [[ "$(state_value net.ipv6.conf.all.disable_ipv6)" == 1 ]] || fail "confirmed value reverted"
}

test_timed_rollback_not_confirmed() {
    setup_env
    local conf="$WORK/92-test.conf"
    printf 'previous policy\n' >"$conf"
    if apply_sysctl_policy "$conf" 'IPv6 policy' 2 net.ipv6.conf.all.disable_ipv6=1 </dev/null >"$WORK/out" 2>&1; then
        fail "unconfirmed change should be reverted"
    fi
    assert_contains "$WORK/out" "IPv6 policy change reverted"
    assert_contains "$conf" "previous policy"
    [[ "$(state_value net.ipv6.conf.all.disable_ipv6)" == 0 ]] || fail "runtime value not reverted"
}

test_watchdog_reverts_when_script_dies() {
    setup_env
    local conf="$WORK/92-test.conf" pid waited=0
    printf 'previous policy\n' >"$conf"
    mkfifo "$WORK/fifo"
    # Hold the FIFO open so the prompt blocks, then kill the "session".
    exec 7<>"$WORK/fifo"
    (apply_sysctl_policy "$conf" 'IPv6 policy' 3 net.ipv6.conf.all.disable_ipv6=1 <"$WORK/fifo" >/dev/null 2>&1) &
    pid=$!
    while ! grep -q 'disable_ipv6 = 1' "$conf" 2>/dev/null; do
        sleep 0.2
        waited=$((waited + 1))
        ((waited < 50)) || fail "policy was never applied"
    done
    kill -9 "$pid"
    wait "$pid" 2>/dev/null || true
    exec 7>&-
    # Watchdog fires after 3s + ROLLBACK_GRACE_SECONDS.
    waited=0
    while ! grep -q 'previous policy' "$conf" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
        ((waited < 15)) || fail "watchdog did not revert the change"
    done
    [[ "$(state_value net.ipv6.conf.all.disable_ipv6)" == 0 ]] || fail "watchdog did not revert runtime value"
}

test_restore_snapshot_rejects_non_backup() {
    setup_env
    mkdir -p "$WORK/not-a-backup"
    if restore_snapshot "$WORK/not-a-backup" >"$WORK/out" 2>&1; then
        fail "a directory without runtime.conf must be rejected"
    fi
    assert_contains "$WORK/out" "Not an optimizer backup"
    assert_not_contains "$STUB_LOG" "sysctl --system"
}

ALL_TESTS=(
    test_refuses_ipv6_ssh_session
    test_refuses_ipv6_ssh_client_var
    test_refuses_without_ipv4_default_route
    test_refuses_ipv6_sshd_peer_when_env_stripped
    test_allows_ipv4_session_with_route
    test_policy_apply_without_rollback
    test_policy_failure_restores_previous_state
    test_policy_failure_removes_new_file
    test_timed_rollback_keep
    test_timed_rollback_not_confirmed
    test_watchdog_reverts_when_script_dies
    test_restore_snapshot_rejects_non_backup
)

if [[ "${1:-}" == "--run-one" ]]; then
    "$2"
    exit 0
fi

failures=0
for t in "${ALL_TESTS[@]}"; do
    if output=$("$TEST_BASH" "$SELF" --run-one "$t" 2>&1); then
        echo "ok - $t"
    else
        echo "not ok - $t"
        printf '%s\n' "$output" | sed 's/^/    /'
        failures=$((failures + 1))
    fi
done

if ((failures)); then
    echo "test_bbr_optimizer: $failures test(s) failed"
    exit 1
fi
echo "test_bbr_optimizer tests passed"
