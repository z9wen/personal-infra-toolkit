#!/usr/bin/env bash
#
# Daily local backups, one archive per site and per database:
#   web/web-<site>-<YYYYMMDD>.tar.gz       each directory under WEB_ROOT, nothing excluded
#   database/db-<site>-<YYYYMMDD>.tar.gz   consistent dump of the database behind that site
#   config/config-<YYYYMMDD>.tar.gz        host configuration needed to rebuild the server
#
# db-<site> pairs with web-<site>, so one site can be rolled back or migrated
# on its own. Settings come from backup.conf next to this script, or from the
# file named by BACKUP_CONFIG (see backup.conf.example).
#
# Every item is built under a temporary name and published only when it is
# complete, so a failed run never rotates out a good archive. One failing item
# does not stop the others; the exit status is non-zero if any item failed.

set -u
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${BACKUP_CONFIG:-$SCRIPT_DIR/backup.conf}"

# Defaults, overridden by the configuration file
BACKUP_BASE=""
KEEP_LOCAL=2
WEB_ROOT=""
MYSQL_DEFAULTS=""
MARIADB_SITES=()
DATABASES=()
CONFIG_ROOT="/"
CONFIG_PATHS=()
CONFIG_EXCLUDES=()

# shellcheck source=server-backup/backup.conf.example
source "$CONFIG_FILE" || {
    echo "Cannot read $CONFIG_FILE" >&2
    exit 1
}
[ -n "$BACKUP_BASE" ] || {
    echo "BACKUP_BASE is not set in $CONFIG_FILE" >&2
    exit 1
}

DATE="$(date +%Y%m%d)"
FAILED=""

time_now() {
    date "+%Y-%m-%d %H:%M:%S"
}

# Print the input lines except the last <keep> (input sorted oldest first)
all_but_newest() {
    awk -v keep="$1" '{ line[NR] = $0 } END { for (i = 1; i <= NR - keep; i++) print line[i] }'
}

# Archives of one item in a directory, oldest first. Only <item>-<8 digits>.tar.gz
# belongs to the item, so web-v.example.com never matches web-vdo.example.com.
item_archives() {
    ls -1 "$1" | awk -v p="$2-" \
        'index($0, p) == 1 && substr($0, length(p) + 1) ~ /^[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]\.tar\.gz$/' | sort
}

# Site a MariaDB database belongs to; unmapped databases are named mariadb-<database>
mariadb_site() {
    local pair
    for pair in ${MARIADB_SITES[@]+"${MARIADB_SITES[@]}"}; do
        if [ "${pair%% *}" = "$1" ]; then
            echo "${pair#* }"
            return
        fi
    done
    echo "mariadb-$1"
}

# Consistent copy of a live SQLite database: read-only connection, safe while the app runs in WAL mode
sqlite_backup() {
    python3 -I - "$1" "$2" <<'PY'
import sqlite3, sys
src = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
dst = sqlite3.connect(sys.argv[2])
src.backup(dst)
# The copy inherits WAL mode; switch it back so the backup is a single self-contained file
dst.execute("PRAGMA journal_mode=DELETE")
ok = dst.execute("PRAGMA integrity_check").fetchone()[0]
dst.close()
src.close()
sys.exit(0 if ok == "ok" else 1)
PY
}

# Archive builders: each gets a scratch directory, the archive path to write and its own arguments

# --single-transaction gives a consistent snapshot of InnoDB tables without locking them
archive_mariadb() {
    local work="$1" archive="$2" db="$3"
    local -a status
    mariadb-dump --defaults-extra-file="$MYSQL_DEFAULTS" --single-transaction --quick --routines --triggers \
        --events --hex-blob --no-tablespaces --databases "$db" | gzip >"$work/$db.sql.gz"
    status=("${PIPESTATUS[@]}")
    [ "${status[0]}" -eq 0 ] && [ "${status[1]}" -eq 0 ] || return 1
    # mariadb-dump writes this trailer only after a complete dump
    gzip -dc "$work/$db.sql.gz" | tail -n 1 | grep -q '^-- Dump completed' || return 1
    tar -C "$work" -czf "$archive" .
}

# pg_dump inside the container, with the container's own POSTGRES_USER and POSTGRES_DB
archive_postgres() {
    local work="$1" archive="$2" container="$3"
    # shellcheck disable=SC2016 # expanded inside the container
    docker exec "$container" sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' >"$work/database.dump" || return 1
    [ -s "$work/database.dump" ] || return 1
    docker exec -i "$container" pg_restore --list <"$work/database.dump" >"$work/database.list" || return 1
    tar -C "$work" -czf "$archive" .
}

archive_sqlite() {
    local work="$1" archive="$2" file="$3"
    sqlite_backup "$file" "$work/$(basename "$file")" || return 1
    tar -C "$work" -czf "$archive" .
}

# The application's own backup command, run with BACKUP_ROOT pointing at the scratch directory
archive_script() {
    local work="$1" archive="$2" command="$3"
    BACKUP_ROOT="$work" "$command" >/dev/null || return 1
    tar -C "$work" --exclude='*.lock' -czf "$archive" .
}

# gzip -1: images are already compressed, higher levels only cost CPU
archive_site() {
    local archive="$2" site="$3"
    local -a status
    tar -C "$WEB_ROOT" -cf - "$site" | gzip -1 >"$archive"
    status=("${PIPESTATUS[@]}")
    # tar exits 1 when a file changed while being read (logs, live databases); the archive is still usable
    [ "${status[0]}" -le 1 ] && [ "${status[1]}" -eq 0 ]
}

archive_config() {
    local work="$1" archive="$2" path
    local -a existing=() excludes=()
    for path in ${CONFIG_PATHS[@]+"${CONFIG_PATHS[@]}"}; do
        [ -e "$CONFIG_ROOT/$path" ] && existing+=("$path")
    done
    for path in ${CONFIG_EXCLUDES[@]+"${CONFIG_EXCLUDES[@]}"}; do
        excludes+=(--exclude="$path")
    done
    crontab -l >"$work/crontab.txt" || return 1
    tar -czf "$archive" ${excludes[@]+"${excludes[@]}"} -C "$work" crontab.txt \
        -C "$CONFIG_ROOT" ${existing[@]+"${existing[@]}"} || [ $? -eq 1 ]
}

# Build <dir>/<item>-<DATE>.tar.gz under a temporary name, publish it, then keep the newest KEEP_LOCAL of that item
# usage: publish <dir> <item> <builder> [builder arguments...]
publish() {
    local dir="$1" item="$2" builder="$3"
    shift 3
    local work="$dir/.incomplete-$item"
    local final="$dir/$item-$DATE.tar.gz"
    if mkdir "$work" && "$builder" "$work" "$work.tar.gz" "$@" && [ -s "$work.tar.gz" ]; then
        mv "$work.tar.gz" "$final"
        rm -rf "$work"
        item_archives "$dir" "$item" | all_but_newest "$KEEP_LOCAL" | while read -r old; do
            rm -f -- "${dir:?}/$old"
        done
        echo "$(time_now)   $item ok ($(du -h "$final" | cut -f1))"
    else
        rm -rf "$work" "$work.tar.gz"
        FAILED="$FAILED $item"
        echo "$(time_now)   $item FAILED" >&2
    fi
}

mkdir -p "$BACKUP_BASE"/database "$BACKUP_BASE"/web "$BACKUP_BASE"/config || exit 1
chmod 700 "$BACKUP_BASE" "$BACKUP_BASE"/database "$BACKUP_BASE"/web "$BACKUP_BASE"/config
exec 9>"$BACKUP_BASE/.lock"
flock -n 9 || {
    echo "$(time_now) Another backup is already running" >&2
    exit 1
}
# Leftovers of an interrupted run (safe: the lock guarantees no other run is active)
rm -rf "$BACKUP_BASE"/database/.incomplete-* "$BACKUP_BASE"/web/.incomplete-* "$BACKUP_BASE"/config/.incomplete-*

echo "$(time_now) Database backups..."
if [ -n "$MYSQL_DEFAULTS" ]; then
    if databases="$(mariadb --defaults-extra-file="$MYSQL_DEFAULTS" -N -e 'show databases')"; then
        # Every database is dumped, mapped or not, so a new one is never silently left out
        for db in $(grep -vxE 'information_schema|performance_schema|mysql|sys' <<<"$databases"); do
            publish "$BACKUP_BASE/database" "db-$(mariadb_site "$db")" archive_mariadb "$db"
        done
    else
        FAILED="$FAILED mariadb-list"
        echo "$(time_now)   could not list MariaDB databases" >&2
    fi
fi
for entry in ${DATABASES[@]+"${DATABASES[@]}"}; do
    read -r site type source <<<"$entry"
    publish "$BACKUP_BASE/database" "db-$site" "archive_$type" "$source"
done

echo "$(time_now) Web backups..."
for site in "$WEB_ROOT"/*/; do
    site="$(basename "$site")"
    publish "$BACKUP_BASE/web" "web-$site" archive_site "$site"
done

echo "$(time_now) Config backup..."
publish "$BACKUP_BASE/config" config archive_config

if [ -n "$FAILED" ]; then
    echo "$(time_now) Backups finished with failures:$FAILED" >&2
    exit 1
fi
echo "$(time_now) All local backups completed successfully"
