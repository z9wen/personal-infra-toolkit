#!/usr/bin/env bash
#
# Self-contained tests for the hestiash scripts. HestiaCP commands, systemctl
# and rclone are stub executables; acme.sh, HestiaCP and backup directories are
# temporary directories. Nothing touches the real system.

set -euo pipefail

HESTIASH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/test_hestia_scripts.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

FAILURES=0

fail() {
    echo "FAIL: $*" >&2
    FAILURES=$((FAILURES + 1))
}

assert_exists() {
    [[ -e "$1" ]] || fail "$2: expected $1 to exist"
}

assert_missing() {
    [[ ! -e "$1" ]] || fail "$2: expected $1 not to exist"
}

assert_contains() {
    case "$1" in
        *"$2"*) ;;
        *) fail "$3: expected '$2' in: $1" ;;
    esac
}

assert_not_contains() {
    case "$1" in
        *"$2"*) fail "$3: unexpected '$2' in: $1" ;;
        *) ;;
    esac
}

make_stub() {
    local path="$1" body="$2"
    mkdir -p "$(dirname "$path")"
    printf '#!/usr/bin/env bash\n%s\n' "$body" >"$path"
    chmod +x "$path"
}

# Creates an acme.sh certificate directory with distinguishable file contents.
make_acme_cert() {
    local acme_home="$1" dir_name="$2"
    local name="${dir_name%_ecc}"
    mkdir -p "$acme_home/$dir_name"
    echo "cert for $name" >"$acme_home/$dir_name/$name.cer"
    echo "key for $name" >"$acme_home/$dir_name/$name.key"
    echo "ca for $name" >"$acme_home/$dir_name/ca.cer"
    printf 'cert for %s\nca for %s\n' "$name" "$name" >"$acme_home/$dir_name/fullchain.cer"
}

mkdir -p "$WORK_DIR/bin"
export PATH="$WORK_DIR/bin:$PATH"
export STUB_LOG="$WORK_DIR/stub.log"
export TMPDIR="$WORK_DIR/tmp"
mkdir -p "$TMPDIR"

make_stub "$WORK_DIR/bin/systemctl" 'echo "systemctl $*" >>"$STUB_LOG"
[[ "${SYSTEMCTL_FAIL:-}" == "$1" ]] && exit 1
exit 0'

# HestiaCP SSL commands: record the call, require <ssl_dir>/<domain>.crt and .key,
# refuse staging inside conf/web/<domain>/ssl (HestiaCP empties it) and store the
# certificate in the user data directory like HestiaCP does.
HESTIA_SSL_STUB='name="${0##*/}"
user="$1" domain="$2" ssl_dir="$3"
echo "$name $user $domain $ssl_dir" >>"$STUB_LOG"
[[ -z "${HESTIA_FAIL:-}" ]] || { echo "Error: simulated failure"; exit 1; }
case "$ssl_dir" in */conf/web/*) echo "Error: staged in HestiaCP ssl dir"; exit 4 ;; esac
[[ -f "$ssl_dir/$domain.crt" && -f "$ssl_dir/$domain.key" ]] || { echo "Error: ssl files missing"; exit 2; }
mkdir -p "$HESTIA/data/users/$user/ssl"
cp "$ssl_dir/$domain.crt" "$HESTIA/data/users/$user/ssl/$domain.crt"
cp "$ssl_dir/$domain.key" "$HESTIA/data/users/$user/ssl/$domain.key"
if [[ -f "$ssl_dir/$domain.ca" ]]; then cp "$ssl_dir/$domain.ca" "$HESTIA/data/users/$user/ssl/$domain.ca"; fi'

setup_hestia() {
    export HESTIA="$1"
    make_stub "$HESTIA/bin/v-add-web-domain-ssl" "$HESTIA_SSL_STUB"
    make_stub "$HESTIA/bin/v-update-web-domain-ssl" "$HESTIA_SSL_STUB"
    make_stub "$HESTIA/bin/v-delete-web-domain-ssl" 'echo "v-delete-web-domain-ssl $*" >>"$STUB_LOG"'
}

# ---------------------------------------------------------------- sync-cert

SYNC_CERT="$HESTIASH_DIR/sync-cert-to-hestia.sh"

test_sync_cert_single_domain_stages_outside_hestia() {
    local root="$WORK_DIR/sync-single" output status=0
    export ACME_HOME="$root/acme"
    setup_hestia "$root/hestia"
    make_acme_cert "$ACME_HOME" "sub.example.com_ecc"
    : >"$STUB_LOG"

    output="$(bash "$SYNC_CERT" sub.example.com admin 2>&1)" || status=$?
    ((status == 0)) || fail "single domain sync exited $status: $output"
    assert_contains "$output" "Success! SSL enabled for sub.example.com" "single domain success"
    assert_contains "$(cat "$STUB_LOG")" "v-add-web-domain-ssl admin sub.example.com $TMPDIR/sync-cert-to-hestia." "staged in a temp dir"
    assert_not_contains "$(cat "$STUB_LOG")" "v-delete-web-domain-ssl" "SSL is never deleted"
    assert_contains "$(cat "$HESTIA/data/users/admin/ssl/sub.example.com.crt")" "cert for sub.example.com" "certificate installed"
    [[ -z "$(ls -A "$TMPDIR")" ]] || fail "staging directory was not cleaned up: $(ls -A "$TMPDIR")"

    # Re-sync: SSL is enabled now, so the certificate is updated in place.
    : >"$STUB_LOG"
    status=0
    output="$(bash "$SYNC_CERT" sub.example.com 2>&1)" || status=$?
    ((status == 0)) || fail "re-sync exited $status: $output"
    assert_contains "$(cat "$STUB_LOG")" "v-update-web-domain-ssl admin sub.example.com" "re-sync updates in place"
    assert_not_contains "$(cat "$STUB_LOG")" "v-add-web-domain-ssl" "re-sync does not re-add"
}

test_sync_cert_wildcard_directory_is_found() {
    local root="$WORK_DIR/sync-wildcard" output status=0
    export ACME_HOME="$root/acme"
    setup_hestia "$root/hestia"
    make_acme_cert "$ACME_HOME" "*.example.com_ecc"
    make_acme_cert "$ACME_HOME" "example.com_ecc"
    : >"$STUB_LOG"

    output="$(bash "$SYNC_CERT" '*' sub.example.com admin 2>&1)" || status=$?
    ((status == 0)) || fail "wildcard sync exited $status: $output"
    assert_contains "$output" "Certificate source: $ACME_HOME/*.example.com_ecc" "wildcard directory used"
    assert_contains "$(cat "$HESTIA/data/users/admin/ssl/sub.example.com.crt")" "cert for *.example.com" "wildcard certificate installed"

    rm -rf "$HESTIA/data"
    status=0
    output="$(bash "$SYNC_CERT" --wildcard sub.example.com 2>&1)" || status=$?
    ((status == 0)) || fail "--wildcard sync exited $status: $output"
    assert_contains "$output" "Certificate source: $ACME_HOME/*.example.com_ecc" "--wildcard directory used"
}

test_sync_cert_unquoted_star_expansion_is_detected() {
    local root="$WORK_DIR/sync-glob" output status=0
    export ACME_HOME="$root/acme"
    setup_hestia "$root/hestia"
    make_acme_cert "$ACME_HOME" "*.example.com_ecc"
    mkdir -p "$root/cwd"
    touch "$root/cwd/a.txt" "$root/cwd/b.txt"

    # What the shell passes for: sync-cert-to-hestia * sub.example.com admin
    output="$(cd "$root/cwd" && bash "$SYNC_CERT" a.txt b.txt sub.example.com admin 2>&1)" || status=$?
    ((status == 0)) || fail "expanded * sync exited $status: $output"
    assert_contains "$output" "Mode: Wildcard Certificate" "expanded * means wildcard mode"
    assert_contains "$(cat "$HESTIA/data/users/admin/ssl/sub.example.com.crt")" "cert for *.example.com" "expanded * installs wildcard"
}

test_sync_cert_failures_exit_non_zero() {
    local root="$WORK_DIR/sync-fail" output status=0
    export ACME_HOME="$root/acme"
    setup_hestia "$root/hestia"
    make_acme_cert "$ACME_HOME" "sub.example.com_ecc"

    output="$(HESTIA_FAIL=1 bash "$SYNC_CERT" sub.example.com 2>&1)" || status=$?
    ((status != 0)) || fail "failed HestiaCP command must exit non-zero"
    assert_not_contains "$output" "Success!" "no success after failure"

    status=0
    output="$(bash "$SYNC_CERT" missing.example.com 2>&1)" || status=$?
    ((status != 0)) || fail "missing certificate must exit non-zero"
    assert_contains "$output" "Certificate not found" "missing certificate message"

    status=0
    output="$(bash "$SYNC_CERT" '../etc' 2>&1)" || status=$?
    ((status != 0)) || fail "invalid domain must exit non-zero"
}

# ---------------------------------------------------------------- auto-sync

AUTO_SYNC="$HESTIASH_DIR/auto-sync-renewed-certs.sh"

test_auto_sync_updates_hestia_and_keeps_nginx_reload() {
    local root="$WORK_DIR/auto" output status=0
    export ACME_DIR="$root/acme"
    export HESTIA_HOME_DIR="$root/home"
    export HESTIA_USER="admin"
    export PANEL_DOMAIN="panel.example.com"
    export PANEL_SSL_DIR="$root/panel-ssl"
    export LOG_FILE="$root/auto.log"
    setup_hestia "$root/hestia"
    mkdir -p "$PANEL_SSL_DIR"

    # app.example.com sorts before the panel domain, so a reset of the reload
    # flag by the panel sync would be visible.
    make_acme_cert "$ACME_DIR" "app.example.com_ecc"
    make_acme_cert "$ACME_DIR" "panel.example.com_ecc"
    make_acme_cert "$ACME_DIR" "nossl.example.com_ecc"
    make_acme_cert "$ACME_DIR" "*.example.com_ecc"
    mkdir -p "$HESTIA_HOME_DIR/admin/conf/web/app.example.com/ssl" \
        "$HESTIA_HOME_DIR/admin/conf/web/nossl.example.com" \
        "$HESTIA/data/users/admin/ssl"
    echo "old cert" >"$HESTIA/data/users/admin/ssl/app.example.com.crt"
    touch -t 202001010000 "$HESTIA/data/users/admin/ssl/app.example.com.crt"
    : >"$STUB_LOG"

    output="$(bash "$AUTO_SYNC" 2>&1)" || status=$?
    ((status == 0)) || fail "auto-sync exited $status: $output"
    local calls
    calls="$(cat "$STUB_LOG")"
    assert_contains "$calls" "v-update-web-domain-ssl admin app.example.com $TMPDIR/acme-auto-sync." "web domain updated through HestiaCP"
    assert_not_contains "$calls" "nossl.example.com" "domain without SSL skipped"
    assert_contains "$calls" "systemctl restart hestia" "panel restarted"
    assert_contains "$calls" "systemctl reload nginx" "nginx reload kept after panel sync"
    assert_contains "$(cat "$HESTIA/data/users/admin/ssl/app.example.com.crt")" "cert for app.example.com" "HestiaCP data updated"
    assert_contains "$(cat "$PANEL_SSL_DIR/certificate.crt")" "ca for panel.example.com" "panel fullchain installed"
    [[ -z "$(ls -A "$TMPDIR")" ]] || fail "auto-sync left staging directories: $(ls -A "$TMPDIR")"

    # Second run: everything is up to date.
    : >"$STUB_LOG"
    status=0
    output="$(bash "$AUTO_SYNC" 2>&1)" || status=$?
    ((status == 0)) || fail "second auto-sync exited $status: $output"
    assert_not_contains "$(cat "$STUB_LOG")" "v-update-web-domain-ssl" "no update when up to date"
    assert_not_contains "$(cat "$STUB_LOG")" "systemctl" "no restarts when up to date"

    # A failing HestiaCP update makes the run fail.
    touch -t 202001010000 "$HESTIA/data/users/admin/ssl/app.example.com.crt"
    status=0
    output="$(HESTIA_FAIL=1 bash "$AUTO_SYNC" 2>&1)" || status=$?
    ((status != 0)) || fail "auto-sync must exit non-zero when HestiaCP fails"
    assert_contains "$output" "completed with 1 error(s)" "failure summary"
}

# ---------------------------------------------------------------- rclone backup

BACKUP_SCRIPT="$HESTIASH_DIR/hestia_rclone_backup.sh"

# rclone stub backed by a local directory; "fake:<path>" maps to $FAKE_REMOTE/<path>.
make_stub "$WORK_DIR/bin/rclone" 'echo "rclone $*" >>"$STUB_LOG"
map() { echo "$FAKE_REMOTE/${1#fake:}"; }
command="$1"
shift
case "$command" in
    copy)
        src="$1" dst="$(map "$2")" files_from=""
        shift 2
        while (($# > 0)); do
            case "$1" in
                --files-from) files_from="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        [[ -n "$files_from" ]] || exit 9
        mkdir -p "$dst"
        while IFS= read -r file; do cp "$src/$file" "$dst/$file"; done <"$files_from"
        ;;
    lsf)
        dir="$(map "$1")"
        [[ -d "$dir" ]] || exit 3
        for path in "$dir"/*; do [[ -f "$path" ]] && echo "${path##*/}"; done
        exit 0
        ;;
    deletefile)
        [[ -z "${RCLONE_FAIL_DELETE:-}" ]] || exit 1
        rm "$(map "$1")"
        ;;
    *) exit 8 ;;
esac'

test_backup_retention_is_per_user() {
    local root="$WORK_DIR/backup" output status=0
    export FAKE_REMOTE="$root/remote"
    export BACKUP_BASE="$root/local"
    export REMOTE_PATH="fake:bk"
    export KEEP_BACKUPS=2
    export LOG_FILE="$root/backup.log"
    mkdir -p "$BACKUP_BASE" "$FAKE_REMOTE/bk"

    touch "$BACKUP_BASE/admin.2026-10-01_05-00-00.tar" \
        "$BACKUP_BASE/admin.2026-10-05_05-00-00.tar" \
        "$BACKUP_BASE/admin.2026-10-08_05-00-00.tar" \
        "$BACKUP_BASE/user2.2026-09-01_05-00-00.tar" \
        "$BACKUP_BASE/user2.2026-09-02_05-00-00.tar" \
        "$BACKUP_BASE/notes.txt"
    touch "$FAKE_REMOTE/bk/admin.2026-09-01_05-00-00.tar" \
        "$FAKE_REMOTE/bk/admin.2026-09-15_05-00-00.tar" \
        "$FAKE_REMOTE/bk/user2.2026-08-01_05-00-00.tar" \
        "$FAKE_REMOTE/bk/other.log"
    : >"$STUB_LOG"

    output="$(bash "$BACKUP_SCRIPT" 2>&1)" || status=$?
    ((status == 0)) || fail "backup sync exited $status: $output"
    local remote="$FAKE_REMOTE/bk"
    assert_exists "$remote/admin.2026-10-08_05-00-00.tar" "newest admin backup kept"
    assert_exists "$remote/admin.2026-10-05_05-00-00.tar" "second newest admin backup kept"
    assert_missing "$remote/admin.2026-10-01_05-00-00.tar" "old local admin backup not uploaded"
    assert_missing "$remote/admin.2026-09-15_05-00-00.tar" "old remote admin backup deleted"
    assert_missing "$remote/admin.2026-09-01_05-00-00.tar" "oldest remote admin backup deleted"
    assert_exists "$remote/user2.2026-09-02_05-00-00.tar" "newest user2 backup kept"
    assert_exists "$remote/user2.2026-09-01_05-00-00.tar" "second user2 backup kept"
    assert_missing "$remote/user2.2026-08-01_05-00-00.tar" "old user2 backup deleted"
    assert_exists "$remote/other.log" "non-HestiaCP remote file untouched"
    assert_missing "$remote/notes.txt" "non-archive local file not uploaded"
    assert_not_contains "$(cat "$STUB_LOG")" " -P" "no progress output"
    assert_contains "$output" "Backup sync completed successfully" "success message"

    # A second run neither re-uploads deleted archives nor deletes anything.
    : >"$STUB_LOG"
    status=0
    output="$(bash "$BACKUP_SCRIPT" 2>&1)" || status=$?
    ((status == 0)) || fail "second backup sync exited $status: $output"
    assert_not_contains "$(cat "$STUB_LOG")" "deletefile" "nothing to delete on second run"
    assert_missing "$remote/admin.2026-10-01_05-00-00.tar" "retention-deleted archive not re-uploaded"

    # Failed deletes are reported as a failure.
    touch "$remote/admin.2026-01-01_05-00-00.tar"
    status=0
    output="$(RCLONE_FAIL_DELETE=1 bash "$BACKUP_SCRIPT" 2>&1)" || status=$?
    ((status != 0)) || fail "failed remote delete must exit non-zero"
    assert_not_contains "$output" "Backup sync completed successfully" "no success after failed delete"
}

test_backup_classify_archives() {
    local result
    result="$(
        # shellcheck source=../hestia_rclone_backup.sh
        source "$BACKUP_SCRIPT"
        printf '%s\n' \
            "user2.2026-01-02_00-00-00.tar" \
            "admin.2026-01-01_00-00-00.tar" \
            "admin.2026-01-03_00-00-00.tar" \
            "user2.2026-01-01_00-00-00.tar" \
            "first.last.2026-01-01_00-00-00.tar" \
            "random.tar" | classify_archives 1
    )"
    local expected
    expected="$(printf '%s\t%s\n' \
        keep admin.2026-01-03_00-00-00.tar \
        drop admin.2026-01-01_00-00-00.tar \
        keep first.last.2026-01-01_00-00-00.tar \
        keep user2.2026-01-02_00-00-00.tar \
        drop user2.2026-01-01_00-00-00.tar)"
    [[ "$result" == "$expected" ]] || fail "classify_archives: expected
$expected
got
$result"
}

test_sync_cert_single_domain_stages_outside_hestia
test_sync_cert_wildcard_directory_is_found
test_sync_cert_unquoted_star_expansion_is_detected
test_sync_cert_failures_exit_non_zero
test_auto_sync_updates_hestia_and_keeps_nginx_reload
test_backup_retention_is_per_user
test_backup_classify_archives

if ((FAILURES > 0)); then
    echo "hestia scripts tests failed: $FAILURES" >&2
    exit 1
fi
echo "hestia scripts tests passed"
