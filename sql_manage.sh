#!/usr/bin/env bash
#
# Simple MySQL / MariaDB backup and restore helper.
# Defaults are local-repo friendly so the script can be demoed safely.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${BACKUP_DIR:-$SCRIPT_DIR/backups/mysql}"
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"
MYSQL_CNF_FILE="${MYSQL_CNF_FILE:-}"
MYSQL_CLIENT="${MYSQL_CLIENT:-mysql}"
MYSQL_DUMP="${MYSQL_DUMP:-mysqldump}"

MYSQL_BASE_ARGS=()
if [[ -n "$MYSQL_CNF_FILE" ]]; then
    MYSQL_BASE_ARGS+=("--defaults-extra-file=$MYSQL_CNF_FILE")
fi
MYSQL_BASE_ARGS+=("--host=$MYSQL_HOST" "--port=$MYSQL_PORT" "--user=$MYSQL_USER")

info() {
    echo "[INFO] $*"
}

warn() {
    echo "[WARN] $*" >&2
}

die() {
    echo "[ERROR] $*" >&2
    exit 1
}

show_help() {
    cat <<'EOF'
MySQL / MariaDB management helper

Usage:
  ./sql_manage.sh help
  ./sql_manage.sh status
  ./sql_manage.sh list
  ./sql_manage.sh backup <database>
  ./sql_manage.sh backup-all
  ./sql_manage.sh restore <database> <backup_file>
  ./sql_manage.sh cleanup <keep_count>

Environment variables:
  BACKUP_DIR       Local backup directory (default: ./backups/mysql)
  MYSQL_HOST       Database host (default: 127.0.0.1)
  MYSQL_PORT       Database port (default: 3306)
  MYSQL_USER       Database user (default: root)
  MYSQL_PASSWORD   Database password
  MYSQL_CNF_FILE   Optional MySQL defaults file for authentication
  MYSQL_CLIENT     mysql binary name/path (default: mysql)
  MYSQL_DUMP       mysqldump binary name/path (default: mysqldump)

Examples:
  ./sql_manage.sh status
  ./sql_manage.sh backup app_db
  ./sql_manage.sh backup-all
  ./sql_manage.sh restore app_db ./backups/mysql/app_db_20260619-010203.sql.gz
  ./sql_manage.sh cleanup 7
EOF
}

require_command() {
    local command_name="$1"
    command -v "$command_name" >/dev/null 2>&1 || die "Required command not found: $command_name"
}

ensure_prerequisites() {
    require_command "$MYSQL_CLIENT"
    require_command "$MYSQL_DUMP"
    require_command gzip
    require_command find
    mkdir -p "$BACKUP_DIR"
}

run_mysql() {
    if [[ -n "$MYSQL_PASSWORD" && -z "$MYSQL_CNF_FILE" ]]; then
        MYSQL_PWD="$MYSQL_PASSWORD" "$MYSQL_CLIENT" "${MYSQL_BASE_ARGS[@]}" "$@"
    else
        "$MYSQL_CLIENT" "${MYSQL_BASE_ARGS[@]}" "$@"
    fi
}

run_mysqldump() {
    if [[ -n "$MYSQL_PASSWORD" && -z "$MYSQL_CNF_FILE" ]]; then
        MYSQL_PWD="$MYSQL_PASSWORD" "$MYSQL_DUMP" "${MYSQL_BASE_ARGS[@]}" "$@"
    else
        "$MYSQL_DUMP" "${MYSQL_BASE_ARGS[@]}" "$@"
    fi
}

show_status() {
    ensure_prerequisites

    info "Backup directory: $BACKUP_DIR"
    info "MySQL host: $MYSQL_HOST"
    info "MySQL port: $MYSQL_PORT"
    info "MySQL user: $MYSQL_USER"

    if [[ -n "$MYSQL_CNF_FILE" ]]; then
        info "Authentication: defaults file ($MYSQL_CNF_FILE)"
    elif [[ -n "$MYSQL_PASSWORD" ]]; then
        info "Authentication: MYSQL_PASSWORD environment variable"
    else
        info "Authentication: relying on mysql client defaults"
    fi

    local version
    version="$(run_mysql --batch --skip-column-names -e "SELECT VERSION();" 2>/dev/null || true)"
    if [[ -n "$version" ]]; then
        info "Database connection OK: $version"
    else
        warn "Database connection test failed. Check credentials or server reachability."
    fi
}

list_backups() {
    ensure_prerequisites

    local found=0
    while IFS= read -r file; do
        found=1
        echo "$file"
    done < <(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name '*.sql' -o -name '*.sql.gz' \) | sort)

    if [[ $found -eq 0 ]]; then
        info "No backup files found in $BACKUP_DIR"
    fi
}

backup_database() {
    local database="${1:-}"
    [[ -n "$database" ]] || die "Usage: ./sql_manage.sh backup <database>"
    ensure_prerequisites

    local timestamp output_file
    timestamp="$(date '+%Y%m%d-%H%M%S')"
    output_file="$BACKUP_DIR/${database}_${timestamp}.sql.gz"

    info "Creating compressed backup for database: $database"
    run_mysqldump \
        --single-transaction \
        --routines \
        --triggers \
        --events \
        --databases "$database" | gzip -c >"$output_file"

    info "Backup written to $output_file"
}

backup_all_databases() {
    ensure_prerequisites

    local timestamp output_file
    timestamp="$(date '+%Y%m%d-%H%M%S')"
    output_file="$BACKUP_DIR/all-databases_${timestamp}.sql.gz"

    info "Creating compressed backup for all databases"
    run_mysqldump \
        --single-transaction \
        --routines \
        --triggers \
        --events \
        --all-databases | gzip -c >"$output_file"

    info "Backup written to $output_file"
}

restore_database() {
    local database="${1:-}"
    local backup_file="${2:-}"
    [[ -n "$database" && -n "$backup_file" ]] || die "Usage: ./sql_manage.sh restore <database> <backup_file>"
    [[ -f "$backup_file" ]] || die "Backup file not found: $backup_file"
    ensure_prerequisites

    local escaped_database
    escaped_database="${database//\`/\`\`}"

    info "Ensuring database exists: $database"
    run_mysql -e "CREATE DATABASE IF NOT EXISTS \`$escaped_database\`;"

    info "Restoring $backup_file into $database"
    case "$backup_file" in
        *.gz)
            gzip -dc "$backup_file" | run_mysql "$database"
            ;;
        *)
            run_mysql "$database" <"$backup_file"
            ;;
    esac

    info "Restore completed for $database"
}

cleanup_backups() {
    local keep_count="${1:-}"
    [[ "$keep_count" =~ ^[0-9]+$ ]] || die "Usage: ./sql_manage.sh cleanup <keep_count>"
    ((keep_count > 0)) || die "keep_count must be greater than zero"
    ensure_prerequisites

    local files=()
    mapfile -t files < <(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name '*.sql' -o -name '*.sql.gz' \) | sort -r)

    if ((${#files[@]} <= keep_count)); then
        info "Nothing to clean. Found ${#files[@]} backup files."
        return 0
    fi

    local file
    for file in "${files[@]:keep_count}"; do
        rm -f "$file"
        info "Removed old backup: $file"
    done
}

main() {
    local command="${1:-help}"

    case "$command" in
        help|-h|--help)
            show_help
            ;;
        status)
            show_status
            ;;
        list)
            list_backups
            ;;
        backup)
            backup_database "${2:-}"
            ;;
        backup-all)
            backup_all_databases
            ;;
        restore)
            restore_database "${2:-}" "${3:-}"
            ;;
        cleanup)
            cleanup_backups "${2:-}"
            ;;
        *)
            die "Unknown command: $command. Run ./sql_manage.sh help"
            ;;
    esac
}

main "$@"
