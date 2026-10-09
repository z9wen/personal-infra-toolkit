#!/usr/bin/env bash
#
# Self-contained tests for sql_manage.sh. Database clients are replaced by stub
# executables on PATH; nothing touches a real database or system directory.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/sql_manage.sh"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/test_sql_manage.XXXXXX")"
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
    [[ ! -e "$1" ]] || fail "$2: expected $1 to be removed"
}

assert_contains() {
    case "$1" in
        *"$2"*) ;;
        *) fail "$3: expected output to contain '$2'; got: $1" ;;
    esac
}

assert_not_contains() {
    case "$1" in
        *"$2"*) fail "$3: output must not contain '$2'; got: $1" ;;
        *) ;;
    esac
}

make_stub() {
    local name="$1" body="$2"
    printf '#!/usr/bin/env bash\n%s\n' "$body" >"$WORK_DIR/bin/$name"
    chmod +x "$WORK_DIR/bin/$name"
}

mkdir -p "$WORK_DIR/bin"
export PATH="$WORK_DIR/bin:$PATH"
export STUB_LOG="$WORK_DIR/stub.log"

# Loads sql_manage.sh with default settings into the current (sub)shell.
load_script() {
    export BACKUP_DIR="$1"
    # shellcheck source=../sql_manage.sh
    source "$SCRIPT"
    # shellcheck disable=SC2034 # read by the sourced sql_manage.sh functions
    DB_ENGINE="${2:-mysql}"
    init_settings
}

test_cleanup_keeps_newest_per_database_by_mtime() {
    local dir="$WORK_DIR/retention"
    mkdir -p "$dir"
    # Names deliberately disagree with modification times and sort across groups.
    touch -t 202610080000 "$dir/all-databases_20261008-000000.sql.gz"
    touch -t 202601010000 "$dir/all-databases_20260101-000000.sql.gz"
    touch -t 202601010000 "$dir/app_20260101-000000.sql.gz"
    touch -t 202512010000 "$dir/app_20990101-000000.sql.gz"
    touch -t 202401010000 "$dir/zeta_20240101-000000.sql.gz"
    touch -t 202301010000 "$dir/zeta_20230101-000000.sql"
    touch -t 202605010000 "$dir/my_app_db_20260501-000000.sql.gz"
    touch -t 202604010000 "$dir/my_app_db_20260401-000000.sql.gz"
    touch -t 202301010000 "$dir/notes.txt"

    (
        load_script "$dir"
        cleanup_backups 1 >/dev/null
    ) || fail "cleanup_backups returned non-zero"

    assert_exists "$dir/all-databases_20261008-000000.sql.gz" "newest all-databases kept"
    assert_missing "$dir/all-databases_20260101-000000.sql.gz" "older all-databases removed"
    assert_exists "$dir/app_20260101-000000.sql.gz" "newest app (by mtime) kept"
    assert_missing "$dir/app_20990101-000000.sql.gz" "older app (by mtime) removed"
    assert_exists "$dir/zeta_20240101-000000.sql.gz" "newest zeta kept"
    assert_missing "$dir/zeta_20230101-000000.sql" "older zeta removed"
    assert_exists "$dir/my_app_db_20260501-000000.sql.gz" "newest my_app_db kept"
    assert_missing "$dir/my_app_db_20260401-000000.sql.gz" "older my_app_db removed"
    assert_exists "$dir/notes.txt" "non-backup file untouched"

    local output
    output="$(
        load_script "$dir"
        cleanup_backups 2
    )"
    assert_contains "$output" "Nothing to clean" "second cleanup is a no-op"
}

test_cleanup_rejects_invalid_keep_count() {
    if (
        load_script "$WORK_DIR/invalid"
        cleanup_backups 0
    ) >/dev/null 2>&1; then
        fail "cleanup_backups 0 should fail"
    fi
}

test_failed_restore_is_reported_by_menu() {
    local dir="$WORK_DIR/menu-restore"
    mkdir -p "$dir"
    echo "CREATE TABLE t (id int);" | gzip -c >"$dir/app_20260101-000000.sql.gz"
    # "mysql -e ..." (CREATE DATABASE) succeeds; the restore stream fails.
    make_stub mysql 'for arg in "$@"; do [[ "$arg" == "-e" ]] && exit 0; done
cat >/dev/null
echo "ERROR 1064: syntax error" >&2
exit 1'

    local output
    output="$(
        load_script "$dir" mysql
        printf '1\napp\n\n' | run_menu_action menu_restore_database 2>&1
    )"
    assert_contains "$output" "Operation failed" "menu reports failed restore"
    assert_not_contains "$output" "Restore completed" "menu restore must not claim success"

    if (
        load_script "$dir" mysql
        restore_database app "$dir/app_20260101-000000.sql.gz"
    ) >/dev/null 2>&1; then
        fail "restore_database should fail when the client fails"
    fi

    # The same action when every step succeeds.
    make_stub mysql 'for arg in "$@"; do [[ "$arg" == "-e" ]] && exit 0; done
cat >/dev/null'
    output="$(
        load_script "$dir" mysql
        printf '1\napp\n\n' | run_menu_action menu_restore_database 2>&1
    )"
    assert_contains "$output" "Restore completed" "menu restore success"
    assert_not_contains "$output" "Operation failed" "menu restore success has no failure"
}

test_failed_database_creation_stops_restore() {
    local dir="$WORK_DIR/pg-create"
    mkdir -p "$dir"
    echo "SELECT 1;" >"$dir/app_20260101-000000.sql"
    make_stub psql 'echo "psql $*" >>"$STUB_LOG"; exit 2'
    make_stub createdb 'echo "createdb $*" >>"$STUB_LOG"; exit 0'
    : >"$STUB_LOG"

    local output
    output="$(
        load_script "$dir" postgresql
        printf '1\napp\n\n' | run_menu_action menu_restore_database 2>&1
    )"
    assert_contains "$output" "Operation failed" "existence check failure reported"
    assert_not_contains "$(cat "$STUB_LOG")" "createdb" "createdb not run after failed check"
}

test_postgresql_restore_uses_single_transaction() {
    local dir="$WORK_DIR/pg-restore"
    mkdir -p "$dir"
    echo "CREATE TABLE t (id int);" >"$dir/app_20260101-000000.sql"
    make_stub psql 'echo "psql $*" >>"$STUB_LOG"
case "$*" in *--command=*) echo 1 ;; *) cat >/dev/null ;; esac'
    make_stub createdb 'exit 0'
    : >"$STUB_LOG"

    (
        load_script "$dir" postgresql
        restore_database app "$dir/app_20260101-000000.sql" >/dev/null
    ) || fail "postgresql restore failed"
    assert_contains "$(cat "$STUB_LOG")" "--dbname=app --single-transaction --set=ON_ERROR_STOP=1" "single transaction restore"
}

test_postgresql_restore_all_tolerates_existing_roles() {
    local dir="$WORK_DIR/pg-restore-all"
    mkdir -p "$dir"
    cat >"$dir/all-databases_20260101-000000.sql" <<'SQL'
SET default_transaction_read_only = off;
CREATE ROLE postgres;
ALTER ROLE postgres WITH SUPERUSER INHERIT CREATEROLE CREATEDB LOGIN;
CREATE ROLE app;
\connect template1
CREATE ROLE not_global;
SQL
    gzip "$dir/all-databases_20260101-000000.sql"
    make_stub psql 'echo "psql $*" >>"$STUB_LOG"; cat >"$STUB_LOG.sql"'
    : >"$STUB_LOG"

    (
        load_script "$dir" postgresql
        restore_all_databases "$dir/all-databases_20260101-000000.sql.gz" >/dev/null 2>&1
    ) || fail "postgresql restore-all failed"

    local sql
    sql="$(cat "$STUB_LOG.sql")"
    assert_contains "$sql" 'DO $sql_manage_role$ BEGIN CREATE ROLE postgres; EXCEPTION WHEN duplicate_object' "superuser CREATE ROLE tolerated"
    assert_contains "$sql" 'BEGIN CREATE ROLE app; EXCEPTION' "other CREATE ROLE tolerated"
    assert_contains "$sql" "ALTER ROLE postgres WITH SUPERUSER" "ALTER ROLE kept"
    assert_contains "$sql" $'\nCREATE ROLE not_global;' "statements after \\connect untouched"
    assert_contains "$(cat "$STUB_LOG")" "--dbname=postgres --set=ON_ERROR_STOP=1" "restore-all stops on other errors"
}

test_backup_writes_compressed_file() {
    local dir="$WORK_DIR/backup"
    make_stub mysqldump 'echo "-- dump of ${*: -1}"'
    make_stub mysql 'exit 0'
    (
        load_script "$dir" mysql
        backup_database "my app" >/dev/null
    ) || fail "backup_database failed"

    local files=("$dir"/my_app_*.sql.gz)
    [[ -f "${files[0]}" ]] || fail "backup file not created"
    assert_contains "$(gzip -dc "${files[0]}")" "-- dump of my app" "backup content"

    make_stub mysqldump 'exit 3'
    if (
        load_script "$dir" mysql
        backup_database broken
    ) >/dev/null 2>&1; then
        fail "backup_database should fail when mysqldump fails"
    fi
    local leftovers
    leftovers="$(find "$dir" -name 'broken_*')"
    [[ -z "$leftovers" ]] || fail "failed backup left files behind: $leftovers"
}

test_cleanup_keeps_newest_per_database_by_mtime
test_cleanup_rejects_invalid_keep_count
test_failed_restore_is_reported_by_menu
test_failed_database_creation_stops_restore
test_postgresql_restore_uses_single_transaction
test_postgresql_restore_all_tolerates_existing_roles
test_backup_writes_compressed_file

if ((FAILURES > 0)); then
    echo "sql_manage tests failed: $FAILURES" >&2
    exit 1
fi
echo "sql_manage tests passed"
