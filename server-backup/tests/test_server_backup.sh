#!/usr/bin/env bash
#
# Self-contained tests for server-backup/backup-local.sh and rclone-backup.sh.
#
# mariadb, mariadb-dump, docker, crontab, flock and rclone are stub executables
# on PATH; rclone maps "<remote>:<path>" to a temporary directory. Archives are
# built with the real tar, gzip and python3 (sqlite3), all under a temporary
# directory. No root required. Works with bash 3.2 (macOS) and bash 5.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_SCRIPT="$TEST_DIR/../backup-local.sh"
UPLOAD_SCRIPT="$TEST_DIR/../rclone-backup.sh"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/test_server_backup.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

TODAY="$(date +%Y%m%d)"
FAILURES=0

fail() {
    echo "FAIL: $*" >&2
    FAILURES=$((FAILURES + 1))
}

assert_exists() {
    [[ -e "$1" ]] || fail "$2: expected $1 to exist"
}

assert_missing() {
    [[ ! -e "$1" ]] || fail "$2: expected $1 to be absent"
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
export FAKE_REMOTE="$WORK_DIR/remote"

make_stub flock 'exit 0'
make_stub crontab '[ "${1:-}" = "-l" ] && echo "0 6 * * * /opt/server-backup/rclone-backup.sh"'
make_stub mariadb 'printf "%s\n" information_schema wordpress newdb mysql performance_schema sys'
# The database name is the last argument; FAIL_DUMP makes the dump of that database fail
make_stub mariadb-dump '
for db; do :; done
[ "${FAIL_DUMP:-}" = "$db" ] && exit 2
printf -- "-- dump of %s\nCREATE TABLE t (i int);\n-- Dump completed on 2026-01-01\n" "$db"'
make_stub docker '
[ "$1" = exec ] || exit 1
shift
if [ "$1" = -i ]; then
    cat >/dev/null
    echo "; archive listing"
    exit 0
fi
[ "$1" = missing-db ] && exit 1
echo "PGDMP fake dump of $1"'
# Supports the rclone calls the scripts make: lsf --files-only, copy (with
# --include / --exclude on file names) and deletefile
make_stub rclone '
map() { case "$1" in *:*) echo "$FAKE_REMOTE/${1#*:}" ;; *) echo "$1" ;; esac; }
command="$1"
shift
case "$command" in
    lsf)
        for path; do :; done
        dir="$(map "$path")"
        [ -d "$dir" ] || exit 3
        for file in "$dir"/*; do [ -f "$file" ] && basename "$file"; done
        exit 0
        ;;
    deletefile) rm -f "$(map "$1")" ;;
    copy)
        src="" dst="" include="" exclude=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --include) include="$2"; shift 2 ;;
                --exclude) exclude="$2"; shift 2 ;;
                *) if [ -z "$src" ]; then src="$1"; else dst="$1"; fi; shift ;;
            esac
        done
        src="$(map "$src")" dst="$(map "$dst")"
        mkdir -p "$dst"
        for file in "$src"/* "$src"/.*; do
            [ -f "$file" ] || continue
            name="$(basename "$file")"
            if [ -n "$exclude" ]; then case "$name" in $exclude) continue ;; esac; fi
            if [ -n "$include" ]; then case "$name" in $include) ;; *) continue ;; esac; fi
            cp -p "$file" "$dst/$name"
        done
        ;;
    *) exit 1 ;;
esac'

# Web root, databases and host configuration shared by the local backup tests
WEB="$WORK_DIR/www"
mkdir -p "$WEB/blog.example.com" "$WEB/v.example.com" "$WEB/vdo.example.com" "$WEB/vault.example.com/data"
echo "blog" >"$WEB/blog.example.com/index.html"
echo "v" >"$WEB/v.example.com/index.html"
echo "vdo" >"$WEB/vdo.example.com/index.html"
python3 -I -c '
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("PRAGMA journal_mode=WAL")
db.execute("CREATE TABLE items (id INTEGER)")
db.executemany("INSERT INTO items VALUES (?)", [(i,) for i in range(5)])
db.commit()' "$WEB/vault.example.com/data/db.sqlite3"

# An application backup command: writes its dump and a lock file into BACKUP_ROOT
cat >"$WORK_DIR/app-backup.sh" <<'EOF'
#!/usr/bin/env bash
echo "app dump" >"$BACKUP_ROOT/dump.sql"
: >"$BACKUP_ROOT/.backup.lock"
EOF
chmod +x "$WORK_DIR/app-backup.sh"

ROOT="$WORK_DIR/root"
mkdir -p "$ROOT/etc/app"
echo "setting=1" >"$ROOT/etc/app/app.conf"
echo "password=secret" >"$ROOT/etc/app/backup.cnf"

# Writes a configuration file for a backup base and extra DATABASES entries
write_config() {
    local file="$1" base="$2"
    shift 2
    {
        echo "BACKUP_BASE=\"$base\""
        echo "KEEP_LOCAL=2"
        echo "WEB_ROOT=\"$WEB\""
        echo "MYSQL_DEFAULTS=\"$ROOT/etc/app/backup.cnf\""
        echo 'MARIADB_SITES=("wordpress blog.example.com")'
        echo "DATABASES=("
        local entry
        for entry in "$@"; do
            echo "    \"$entry\""
        done
        echo ")"
        echo "CONFIG_ROOT=\"$ROOT\""
        echo "CONFIG_PATHS=(etc/app etc/missing)"
        echo "CONFIG_EXCLUDES=(etc/app/backup.cnf)"
        echo 'RCLONE_DEST="remote:backup"'
        echo "KEEP_DAILY=2"
        echo "KEEP_WEEKLY=1"
        echo "KEEP_MONTHLY=1"
    } >"$file"
}

test_one_archive_per_site_and_database() {
    local base="$WORK_DIR/one-archive" config="$WORK_DIR/one-archive.conf" output listing
    write_config "$config" "$base" \
        "app.example.com postgres app-db" \
        "vault.example.com sqlite $WEB/vault.example.com/data/db.sqlite3" \
        "api.example.com script $WORK_DIR/app-backup.sh"

    output="$(BACKUP_CONFIG="$config" "$LOCAL_SCRIPT" 2>&1)" || fail "local backup failed: $output"
    assert_contains "$output" "All local backups completed successfully" "success reported"

    local db="$base/database"
    assert_exists "$db/db-blog.example.com-$TODAY.tar.gz" "mapped MariaDB database named after its site"
    assert_exists "$db/db-mariadb-newdb-$TODAY.tar.gz" "unmapped MariaDB database still backed up"
    assert_missing "$db/db-mariadb-mysql-$TODAY.tar.gz" "system database skipped"
    listing="$(tar -tzf "$db/db-blog.example.com-$TODAY.tar.gz")"
    assert_contains "$listing" "wordpress.sql.gz" "MariaDB dump inside its archive"

    listing="$(tar -tzf "$db/db-app.example.com-$TODAY.tar.gz")"
    assert_contains "$listing" "database.dump" "PostgreSQL dump archived"
    assert_contains "$listing" "database.list" "PostgreSQL dump listing archived"

    listing="$(tar -tzf "$db/db-api.example.com-$TODAY.tar.gz")"
    assert_contains "$listing" "dump.sql" "application backup archived"
    assert_not_contains "$listing" ".backup.lock" "application lock file left out"

    local restored="$WORK_DIR/restored-sqlite" result
    mkdir -p "$restored"
    tar -xzf "$db/db-vault.example.com-$TODAY.tar.gz" -C "$restored"
    result="$(python3 -I -c '
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
print(db.execute("PRAGMA journal_mode").fetchone()[0], db.execute("SELECT COUNT(*) FROM items").fetchone()[0])' \
        "$restored/db.sqlite3")"
    [[ "$result" == "delete 5" ]] || fail "SQLite backup should be a single file with all rows; got: $result"

    local site
    for site in blog.example.com v.example.com vdo.example.com vault.example.com; do
        assert_exists "$base/web/web-$site-$TODAY.tar.gz" "web archive for $site"
    done
    listing="$(tar -tzf "$base/web/web-blog.example.com-$TODAY.tar.gz")"
    assert_contains "$listing" "blog.example.com/index.html" "site files archived under the site directory"

    listing="$(tar -tzf "$base/config/config-$TODAY.tar.gz")"
    assert_contains "$listing" "crontab.txt" "crontab archived"
    assert_contains "$listing" "etc/app/app.conf" "configured path archived"
    assert_not_contains "$listing" "backup.cnf" "credentials excluded"

    [[ -z "$(find "$base" -name '.incomplete-*')" ]] || fail "temporary files left behind"
}

test_local_rotation_is_per_item() {
    local base="$WORK_DIR/rotation" config="$WORK_DIR/rotation.conf" output
    write_config "$config" "$base"
    mkdir -p "$base/web"
    touch "$base/web/web-v.example.com-20200101.tar.gz" \
        "$base/web/web-v.example.com-20200102.tar.gz" \
        "$base/web/web-v.example.com-20200103.tar.gz" \
        "$base/web/web-v.example.com-manual.tar.gz" \
        "$base/web/web-vdo.example.com-20200101.tar.gz"

    output="$(BACKUP_CONFIG="$config" "$LOCAL_SCRIPT" 2>&1)" || fail "local backup failed: $output"

    assert_exists "$base/web/web-v.example.com-$TODAY.tar.gz" "today's archive kept"
    assert_exists "$base/web/web-v.example.com-20200103.tar.gz" "previous archive kept"
    assert_missing "$base/web/web-v.example.com-20200102.tar.gz" "older archive rotated out"
    assert_missing "$base/web/web-v.example.com-20200101.tar.gz" "oldest archive rotated out"
    assert_exists "$base/web/web-v.example.com-manual.tar.gz" "file without a date untouched"
    assert_exists "$base/web/web-vdo.example.com-20200101.tar.gz" "similarly named site counted separately"
}

test_failed_item_keeps_previous_archive() {
    local base="$WORK_DIR/failure" config="$WORK_DIR/failure.conf" output status=0
    write_config "$config" "$base" "broken.example.com postgres missing-db"
    mkdir -p "$base/database"
    touch "$base/database/db-broken.example.com-20200101.tar.gz" \
        "$base/database/db-blog.example.com-20200101.tar.gz"

    output="$(FAIL_DUMP=wordpress BACKUP_CONFIG="$config" "$LOCAL_SCRIPT" 2>&1)" || status=$?
    [[ "$status" -ne 0 ]] || fail "a failed item must make the run fail"
    assert_contains "$output" "db-broken.example.com FAILED" "failed PostgreSQL item reported"
    assert_contains "$output" "db-blog.example.com FAILED" "failed MariaDB item reported"
    assert_exists "$base/database/db-broken.example.com-20200101.tar.gz" "previous archive kept after failure"
    assert_exists "$base/database/db-blog.example.com-20200101.tar.gz" "previous MariaDB archive kept after failure"
    assert_missing "$base/database/db-broken.example.com-$TODAY.tar.gz" "no archive published for a failed item"
    assert_exists "$base/database/db-mariadb-newdb-$TODAY.tar.gz" "other databases still backed up"
    assert_exists "$base/web/web-blog.example.com-$TODAY.tar.gz" "sites still backed up"
    [[ -z "$(find "$base" -name '.incomplete-*')" ]] || fail "failed item left temporary files behind"
}

test_upload_rotation_and_promotion() {
    local base="$WORK_DIR/upload" config="$WORK_DIR/upload.conf" output remote="$FAKE_REMOTE/backup"
    write_config "$config" "$base"
    mkdir -p "$base/database" "$base/web" "$base/config" "$remote/database/daily" "$remote/database/weekly"
    touch "$base/database/db-a.example.com-20200101.tar.gz" "$base/database/db-a.example.com-$TODAY.tar.gz" \
        "$base/web/web-a.example.com-$TODAY.tar.gz" "$base/config/config-$TODAY.tar.gz" \
        "$base/database/.incomplete-db-x.tar.gz"
    touch "$remote/database/daily/db-a.example.com-20191231.tar.gz" \
        "$remote/database/weekly/db-a.example.com-20200105.tar.gz"

    output="$(SKIP_LOCAL_BACKUP=1 BACKUP_DAY_OF_WEEK=3 BACKUP_DAY_OF_MONTH=15 BACKUP_CONFIG="$config" \
        "$UPLOAD_SCRIPT" 2>&1)" || fail "upload failed: $output"
    assert_contains "$output" "All backup tasks completed successfully" "upload success reported"
    assert_exists "$remote/database/daily/db-a.example.com-$TODAY.tar.gz" "today's archive uploaded"
    assert_exists "$remote/database/daily/db-a.example.com-20200101.tar.gz" "previous archive uploaded"
    assert_missing "$remote/database/daily/db-a.example.com-20191231.tar.gz" "daily keeps the newest two"
    assert_missing "$remote/database/daily/.incomplete-db-x.tar.gz" "hidden files not uploaded"
    assert_exists "$remote/database/weekly/db-a.example.com-20200105.tar.gz" "weekly untouched on a weekday"
    assert_missing "$remote/database/monthly" "no monthly copy outside the 1st"

    output="$(SKIP_LOCAL_BACKUP=1 BACKUP_DAY_OF_WEEK=7 BACKUP_DAY_OF_MONTH=01 BACKUP_CONFIG="$config" \
        "$UPLOAD_SCRIPT" 2>&1)" || fail "upload failed: $output"
    assert_exists "$remote/database/weekly/db-a.example.com-$TODAY.tar.gz" "Sunday copy made"
    assert_missing "$remote/database/weekly/db-a.example.com-20200105.tar.gz" "previous weekly copy replaced"
    assert_missing "$remote/database/weekly/db-a.example.com-20200101.tar.gz" "only today's archives promoted"
    assert_exists "$remote/database/monthly/db-a.example.com-$TODAY.tar.gz" "1st-of-month copy made"
    assert_exists "$remote/web/weekly/web-a.example.com-$TODAY.tar.gz" "web archives promoted too"
    assert_exists "$remote/config/monthly/config-$TODAY.tar.gz" "config archive promoted too"
}

test_missing_config_is_rejected() {
    local output status=0
    output="$(BACKUP_CONFIG="$WORK_DIR/absent.conf" "$LOCAL_SCRIPT" 2>&1)" || status=$?
    [[ "$status" -ne 0 ]] || fail "backup-local.sh must fail without a configuration file"
    assert_contains "$output" "Cannot read" "missing configuration reported"
    status=0
    output="$(BACKUP_CONFIG="$WORK_DIR/absent.conf" "$UPLOAD_SCRIPT" 2>&1)" || status=$?
    [[ "$status" -ne 0 ]] || fail "rclone-backup.sh must fail without a configuration file"
}

test_one_archive_per_site_and_database
test_local_rotation_is_per_item
test_failed_item_keeps_previous_archive
test_upload_rotation_and_promotion
test_missing_config_is_rejected

if ((FAILURES > 0)); then
    echo "server-backup tests failed: $FAILURES" >&2
    exit 1
fi
echo "server-backup tests passed"
