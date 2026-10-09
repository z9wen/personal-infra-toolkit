#!/usr/bin/env bash
#
# MySQL / MariaDB and PostgreSQL backup and restore helper.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_ENGINE="${DB_ENGINE:-mysql}"

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
MySQL / MariaDB and PostgreSQL management helper

Usage:
  ./sql_manage.sh
  ./sql_manage.sh menu

Automation / advanced usage:
  ./sql_manage.sh [--engine mysql|postgresql] help
  ./sql_manage.sh [--engine mysql|postgresql] status
  ./sql_manage.sh [--engine mysql|postgresql] databases
  ./sql_manage.sh [--engine mysql|postgresql] list
  ./sql_manage.sh [--engine mysql|postgresql] backup <database>
  ./sql_manage.sh [--engine mysql|postgresql] backup-all
  ./sql_manage.sh [--engine mysql|postgresql] restore <database> <backup_file>
  ./sql_manage.sh [--engine mysql|postgresql] restore-all <backup_file>
  ./sql_manage.sh [--engine mysql|postgresql] cleanup <keep_count>

General environment variables:
  DB_ENGINE         mysql or postgresql (default: mysql)
  BACKUP_DIR        Backup directory (default: ./backups/<engine>)

MySQL / MariaDB environment variables:
  MYSQL_HOST        Database host (default: 127.0.0.1)
  MYSQL_PORT        Database port (default: 3306)
  MYSQL_USER        Database user (default: root)
  MYSQL_PASSWORD    Database password
  MYSQL_CNF_FILE    Optional defaults file; preferred over MYSQL_PASSWORD
  MYSQL_CLIENT      mysql binary name/path (default: mysql)
  MYSQL_DUMP        mysqldump binary name/path (default: mysqldump)

PostgreSQL environment variables:
  PGHOST            Database host (default: 127.0.0.1)
  PGPORT            Database port (default: 5432)
  PGUSER            Database user (default: postgres)
  PGPASSWORD        Database password
  PGPASSFILE        Optional PostgreSQL password file
  PSQL              psql binary name/path (default: psql)
  PG_DUMP           pg_dump binary name/path (default: pg_dump)
  PG_DUMPALL        pg_dumpall binary name/path (default: pg_dumpall)
  CREATEDB          createdb binary name/path (default: createdb)

Examples:
  ./sql_manage.sh status
  ./sql_manage.sh backup app_db
  ./sql_manage.sh restore app_db ./backups/mysql/app_db_20260717-010203.sql.gz

  ./sql_manage.sh --engine postgresql status
  ./sql_manage.sh --engine postgresql backup app_db
  DB_ENGINE=postgresql ./sql_manage.sh backup-all
  DB_ENGINE=postgresql PGPASSFILE=~/.pgpass ./sql_manage.sh databases

Notes:
  Running without arguments opens the interactive management menu.
  backup-all for PostgreSQL uses pg_dumpall and may contain role definitions.
  Backup files are created with user-only permissions (umask 077).
  cleanup keeps the <keep_count> newest files (by modification time) for each
  database name prefix, e.g. app_db_*.sql.gz and all-databases_*.sql.gz are
  retained independently.
  PostgreSQL single-database restores run in one transaction (--single-transaction)
  and roll back completely on the first error.
  PostgreSQL restore-all is meant for a fresh cluster: roles that already exist
  (such as the connecting superuser) are kept and updated by the following
  ALTER ROLE, but an existing database or object still stops the restore.
  MySQL restores stop at the first error, but DDL statements auto-commit, so a
  failed MySQL restore can leave a partially restored database behind.
EOF
}

normalize_engine() {
    local engine
    engine="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$engine" in
        mysql | mariadb)
            echo "mysql"
            ;;
        postgres | postgresql | pgsql | pg)
            echo "postgresql"
            ;;
        *)
            die "Unsupported database engine: $1 (use mysql or postgresql)"
            ;;
    esac
}

parse_global_options() {
    while (($# > 0)); do
        case "$1" in
            --engine)
                (($# >= 2)) || die "--engine requires mysql or postgresql"
                DB_ENGINE="$2"
                shift 2
                ;;
            --engine=*)
                DB_ENGINE="${1#*=}"
                shift
                ;;
            --)
                shift
                break
                ;;
            *)
                break
                ;;
        esac
    done

    DB_ENGINE="$(normalize_engine "$DB_ENGINE")"
    REMAINING_ARGS=("$@")
    REMAINING_COUNT=$#
}

require_command() {
    local command_name="$1"
    command -v "$command_name" >/dev/null 2>&1 || die "Required command not found: $command_name"
}

ensure_backup_directory() {
    mkdir -p "$BACKUP_DIR" || die "Cannot create backup directory: $BACKUP_DIR"
    chmod 700 "$BACKUP_DIR" 2>/dev/null || true
}

require_common_backup_tools() {
    require_command gzip
    ensure_backup_directory
}

require_mysql_client() {
    if [[ -n "$MYSQL_CNF_FILE" ]]; then
        [[ -r "$MYSQL_CNF_FILE" ]] || die "MYSQL_CNF_FILE is not readable: $MYSQL_CNF_FILE"
    fi
    require_command "$MYSQL_CLIENT"
}

require_mysql_dump() {
    require_mysql_client
    require_command "$MYSQL_DUMP"
}

require_postgresql_client() {
    if [[ -n "$PGPASSFILE" ]]; then
        [[ -r "$PGPASSFILE" ]] || die "PGPASSFILE is not readable: $PGPASSFILE"
    fi
    require_command "$PSQL"
}

require_postgresql_dump() {
    require_postgresql_client
    require_command "$PG_DUMP"
}

build_connection_settings() {
    MYSQL_BASE_ARGS=()
    if [[ -n "$MYSQL_CNF_FILE" ]]; then
        MYSQL_BASE_ARGS+=("--defaults-extra-file=$MYSQL_CNF_FILE")
    fi
    MYSQL_BASE_ARGS+=("--host=$MYSQL_HOST" "--port=$MYSQL_PORT" "--user=$MYSQL_USER")

    PG_BASE_ARGS=("--host=$PGHOST" "--port=$PGPORT" "--username=$PGUSER")
    PG_ENV=(env)
    if [[ -n "$PGPASSWORD" ]]; then
        PG_ENV+=("PGPASSWORD=$PGPASSWORD")
    fi
    if [[ -n "$PGPASSFILE" ]]; then
        PG_ENV+=("PGPASSFILE=$PGPASSFILE")
    fi
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

run_psql() {
    "${PG_ENV[@]}" "$PSQL" "${PG_BASE_ARGS[@]}" "$@"
}

run_pg_dump() {
    "${PG_ENV[@]}" "$PG_DUMP" "${PG_BASE_ARGS[@]}" "$@"
}

run_pg_dumpall() {
    "${PG_ENV[@]}" "$PG_DUMPALL" "${PG_BASE_ARGS[@]}"
}

run_createdb() {
    "${PG_ENV[@]}" "$CREATEDB" "${PG_BASE_ARGS[@]}" "$@"
}

show_authentication_status() {
    case "$DB_ENGINE" in
        mysql)
            if [[ -n "$MYSQL_CNF_FILE" ]]; then
                info "Authentication: defaults file ($MYSQL_CNF_FILE)"
            elif [[ -n "$MYSQL_PASSWORD" ]]; then
                info "Authentication: MYSQL_PASSWORD environment variable"
            else
                info "Authentication: relying on MySQL client defaults"
            fi
            ;;
        postgresql)
            if [[ -n "$PGPASSFILE" ]]; then
                info "Authentication: password file ($PGPASSFILE)"
            elif [[ -n "$PGPASSWORD" ]]; then
                info "Authentication: PGPASSWORD environment variable"
            else
                info "Authentication: relying on PostgreSQL client defaults"
            fi
            ;;
    esac
}

show_status() {
    info "Database engine: $DB_ENGINE"
    info "Backup directory: $BACKUP_DIR"

    local version=""
    case "$DB_ENGINE" in
        mysql)
            require_mysql_client
            info "Database endpoint: $MYSQL_USER@$MYSQL_HOST:$MYSQL_PORT"
            show_authentication_status
            version="$(run_mysql --batch --skip-column-names -e "SELECT VERSION();" 2>/dev/null || true)"
            ;;
        postgresql)
            require_postgresql_client
            info "Database endpoint: $PGUSER@$PGHOST:$PGPORT"
            show_authentication_status
            version="$(run_psql --dbname=postgres --tuples-only --no-align --command="SELECT version();" 2>/dev/null || true)"
            ;;
    esac

    if [[ -n "$version" ]]; then
        info "Database connection OK: $version"
    else
        warn "Database connection test failed. Check credentials or server reachability."
        return 1
    fi
}

list_databases() {
    case "$DB_ENGINE" in
        mysql)
            require_mysql_client
            run_mysql --batch --skip-column-names -e "SHOW DATABASES;"
            ;;
        postgresql)
            require_postgresql_client
            run_psql \
                --dbname=postgres \
                --tuples-only \
                --no-align \
                --command="SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;"
            ;;
    esac
}

list_backups() {
    ensure_backup_directory

    local found=0
    while IFS= read -r file; do
        found=1
        echo "$file"
    done < <(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name '*.sql' -o -name '*.sql.gz' \) | sort)

    if [[ $found -eq 0 ]]; then
        info "No backup files found in $BACKUP_DIR"
    fi
}

safe_filename_component() {
    local value="$1"
    value="${value//[^a-zA-Z0-9_.-]/_}"
    [[ -n "$value" ]] || value="database"
    printf '%s' "$value"
}

finalize_backup() {
    local temporary_file="$1"
    local output_file="$2"

    [[ -s "$temporary_file" ]] || {
        rm -f "$temporary_file"
        die "Backup command produced an empty file"
    }
    gzip -t "$temporary_file" || {
        rm -f "$temporary_file"
        die "Compressed backup validation failed"
    }
    chmod 600 "$temporary_file" || die "Cannot set permissions on $temporary_file"
    mv "$temporary_file" "$output_file" || die "Cannot move backup into place: $output_file"
    info "Backup written to $output_file"
}

backup_database() {
    local database="${1:-}"
    [[ -n "$database" ]] || die "Usage: ./sql_manage.sh [--engine ENGINE] backup <database>"
    require_common_backup_tools

    local timestamp safe_database output_file temporary_file
    timestamp="$(date '+%Y%m%d-%H%M%S')"
    safe_database="$(safe_filename_component "$database")"
    output_file="$BACKUP_DIR/${safe_database}_${timestamp}.sql.gz"
    temporary_file="${output_file}.tmp.$$"

    info "Creating compressed $DB_ENGINE backup for database: $database"
    case "$DB_ENGINE" in
        mysql)
            require_mysql_dump
            if ! run_mysqldump \
                --single-transaction \
                --routines \
                --triggers \
                --events \
                -- "$database" | gzip -c >"$temporary_file"; then
                rm -f "$temporary_file"
                die "MySQL backup failed for database: $database"
            fi
            ;;
        postgresql)
            require_postgresql_dump
            if ! run_pg_dump \
                --format=plain \
                --no-owner \
                --no-privileges \
                --dbname="$database" | gzip -c >"$temporary_file"; then
                rm -f "$temporary_file"
                die "PostgreSQL backup failed for database: $database"
            fi
            ;;
    esac

    finalize_backup "$temporary_file" "$output_file"
}

backup_all_databases() {
    require_common_backup_tools

    local timestamp output_file temporary_file
    timestamp="$(date '+%Y%m%d-%H%M%S')"
    output_file="$BACKUP_DIR/all-databases_${timestamp}.sql.gz"
    temporary_file="${output_file}.tmp.$$"

    info "Creating compressed $DB_ENGINE backup for all databases"
    case "$DB_ENGINE" in
        mysql)
            require_mysql_dump
            if ! run_mysqldump \
                --single-transaction \
                --routines \
                --triggers \
                --events \
                --all-databases | gzip -c >"$temporary_file"; then
                rm -f "$temporary_file"
                die "MySQL backup-all failed"
            fi
            ;;
        postgresql)
            require_postgresql_client
            require_command "$PG_DUMPALL"
            if ! run_pg_dumpall | gzip -c >"$temporary_file"; then
                rm -f "$temporary_file"
                die "PostgreSQL backup-all failed"
            fi
            ;;
    esac

    finalize_backup "$temporary_file" "$output_file"
}

ensure_mysql_database() {
    local database="$1"
    local escaped_database="${database//\`/\`\`}"
    run_mysql -e "CREATE DATABASE IF NOT EXISTS \`$escaped_database\`;" || {
        warn "Could not create MySQL database: $database"
        return 1
    }
}

ensure_postgresql_database() {
    local database="$1"
    local escaped_database="${database//\'/\'\'}"
    local exists

    require_command "$CREATEDB"
    exists="$(run_psql \
        --dbname=postgres \
        --tuples-only \
        --no-align \
        --command="SELECT 1 FROM pg_database WHERE datname = '$escaped_database';")" || {
        warn "Could not check whether PostgreSQL database exists: $database"
        return 1
    }

    if [[ "$exists" != "1" ]]; then
        info "Creating PostgreSQL database: $database"
        run_createdb -- "$database" || {
            warn "Could not create PostgreSQL database: $database"
            return 1
        }
    fi
}

stream_backup_to_command() {
    local backup_file="$1"
    shift

    case "$backup_file" in
        *.gz)
            gzip -t "$backup_file" || die "Invalid or corrupted gzip backup: $backup_file"
            # pipefail (set at the top of the script) makes a gzip or client failure fail the pipeline.
            gzip -dc "$backup_file" | "$@"
            ;;
        *)
            "$@" <"$backup_file"
            ;;
    esac
}

restore_database() {
    local database="${1:-}"
    local backup_file="${2:-}"
    [[ -n "$database" && -n "$backup_file" ]] || die "Usage: ./sql_manage.sh [--engine ENGINE] restore <database> <backup_file>"
    [[ -r "$backup_file" ]] || die "Backup file is not readable: $backup_file"

    info "Restoring $backup_file into $DB_ENGINE database: $database"
    case "$DB_ENGINE" in
        mysql)
            require_mysql_client
            ensure_mysql_database "$database" || return 1
            # The mysql client stops at the first error (no --force). DDL auto-commits,
            # so MySQL cannot roll a failed restore back the way PostgreSQL can.
            stream_backup_to_command "$backup_file" run_mysql "$database" || {
                warn "MySQL restore failed for $database; the database may be partially restored"
                return 1
            }
            ;;
        postgresql)
            require_postgresql_client
            ensure_postgresql_database "$database" || return 1
            stream_backup_to_command "$backup_file" run_psql \
                --dbname="$database" \
                --single-transaction \
                --set=ON_ERROR_STOP=1 || {
                warn "PostgreSQL restore failed for $database; the transaction was rolled back"
                return 1
            }
            ;;
    esac

    info "Restore completed for $database"
}

# pg_dumpall emits "CREATE ROLE name;" followed by "ALTER ROLE name WITH ...;" for
# every role, expecting the CREATE to fail harmlessly for roles that already exist
# (always the case for the connecting superuser). With ON_ERROR_STOP=1 that error
# would abort the restore, so each CREATE ROLE in the global section (before the
# first \connect) is wrapped in a DO block that ignores duplicate_object only.
tolerate_existing_pg_roles() {
    awk '
        !in_databases && /^\\connect / { in_databases = 1 }
        !in_databases && /^CREATE ROLE [^;]+;$/ && index($0, "$sql_manage_role$") == 0 {
            print "DO $sql_manage_role$ BEGIN " $0 " EXCEPTION WHEN duplicate_object THEN RAISE NOTICE '"'"'role already exists, keeping it'"'"'; END $sql_manage_role$;"
            next
        }
        { print }
    '
}

restore_postgresql_cluster() {
    tolerate_existing_pg_roles | run_psql --dbname=postgres --set=ON_ERROR_STOP=1
}

restore_all_databases() {
    local backup_file="${1:-}"
    [[ -n "$backup_file" ]] || die "Usage: ./sql_manage.sh [--engine ENGINE] restore-all <backup_file>"
    [[ -r "$backup_file" ]] || die "Backup file is not readable: $backup_file"

    warn "This operation can modify multiple databases and database users."
    info "Restoring complete $DB_ENGINE backup: $backup_file"
    case "$DB_ENGINE" in
        mysql)
            require_mysql_client
            stream_backup_to_command "$backup_file" run_mysql || {
                warn "MySQL full restore failed; databases may be partially restored"
                return 1
            }
            ;;
        postgresql)
            require_postgresql_client
            stream_backup_to_command "$backup_file" restore_postgresql_cluster || {
                warn "PostgreSQL full restore failed; databases may be partially restored"
                return 1
            }
            ;;
    esac

    info "Full restore completed"
}

# Retention group of a backup file: its name without the extension and the
# trailing _<timestamp>, e.g. app_db_20260717-010203.sql.gz -> app_db.
backup_group_name() {
    local name="${1##*/}"
    name="${name%.gz}"
    name="${name%.sql}"
    case "$name" in
        *_*) name="${name%_*}" ;;
    esac
    printf '%s' "$name"
}

cleanup_backups() {
    local keep_count="${1:-}"
    [[ "$keep_count" =~ ^[0-9]+$ ]] || die "Usage: ./sql_manage.sh [--engine ENGINE] cleanup <keep_count>"
    ((keep_count > 0)) || die "keep_count must be greater than zero"
    ensure_backup_directory

    local stat_mtime=(stat -c %Y)
    if ! stat -c %Y / >/dev/null 2>&1; then
        stat_mtime=(stat -f %m) # BSD/macOS stat
    fi

    local tab=$'\t'
    local file group mtime total=0 removed=0 failed=0 kept_in_group=0 current_group=""
    while IFS="$tab" read -r group mtime file; do
        total=$((total + 1))
        if [[ "$group" != "$current_group" ]]; then
            current_group="$group"
            kept_in_group=0
        fi
        if ((kept_in_group < keep_count)); then
            kept_in_group=$((kept_in_group + 1))
            continue
        fi
        if rm -f -- "$file"; then
            removed=$((removed + 1))
            info "Removed old backup: $file"
        else
            failed=1
            warn "Could not remove old backup: $file"
        fi
    done < <(
        find "$BACKUP_DIR" -maxdepth 1 -type f \( -name '*.sql' -o -name '*.sql.gz' \) | while IFS= read -r file; do
            mtime="$("${stat_mtime[@]}" "$file")" || continue
            printf '%s\t%s\t%s\n' "$(backup_group_name "$file")" "$mtime" "$file"
        done | sort -t "$tab" -k1,1 -k2,2nr -k3,3r
    )

    if ((removed == 0 && failed == 0)); then
        info "Nothing to clean. Found $total backup files; keeping up to $keep_count per database."
    fi
    ((failed == 0))
}

pause_for_menu() {
    echo
    read -r -p "Press Enter to return to the menu..." _
}

prompt_with_default() {
    local prompt="$1"
    local current_value="$2"
    local result_variable="$3"
    local input

    read -r -p "$prompt [$current_value]: " input
    printf -v "$result_variable" '%s' "${input:-$current_value}"
}

set_database_engine() {
    DB_ENGINE="$(normalize_engine "$1")"
    if [[ "$BACKUP_DIR_CUSTOM" -eq 0 ]]; then
        BACKUP_DIR="$SCRIPT_DIR/backups/$DB_ENGINE"
    fi
    build_connection_settings
}

configure_mysql_connection() {
    local auth_choice input

    echo
    echo "Configure MySQL / MariaDB connection"
    prompt_with_default "Host" "$MYSQL_HOST" MYSQL_HOST
    prompt_with_default "Port" "$MYSQL_PORT" MYSQL_PORT
    prompt_with_default "User" "$MYSQL_USER" MYSQL_USER
    prompt_with_default "Backup directory" "$BACKUP_DIR" BACKUP_DIR
    BACKUP_DIR_CUSTOM=1

    echo
    echo "Authentication method"
    echo "1. Password"
    echo "2. MySQL defaults file"
    echo "3. Use client defaults"
    read -r -p "Select [1-3, default: 3]: " auth_choice
    case "${auth_choice:-3}" in
        1)
            read -r -s -p "Database password: " input
            echo
            MYSQL_PASSWORD="$input"
            MYSQL_CNF_FILE=""
            ;;
        2)
            prompt_with_default "Defaults file" "${MYSQL_CNF_FILE:-$HOME/.my.cnf}" MYSQL_CNF_FILE
            MYSQL_PASSWORD=""
            ;;
        3)
            MYSQL_PASSWORD=""
            MYSQL_CNF_FILE=""
            ;;
        *)
            warn "Invalid choice; authentication settings were not changed"
            ;;
    esac
    build_connection_settings
}

configure_postgresql_connection() {
    local auth_choice input

    echo
    echo "Configure PostgreSQL connection"
    prompt_with_default "Host" "$PGHOST" PGHOST
    prompt_with_default "Port" "$PGPORT" PGPORT
    prompt_with_default "User" "$PGUSER" PGUSER
    prompt_with_default "Backup directory" "$BACKUP_DIR" BACKUP_DIR
    BACKUP_DIR_CUSTOM=1

    echo
    echo "Authentication method"
    echo "1. Password"
    echo "2. .pgpass file"
    echo "3. Use client defaults"
    read -r -p "Select [1-3, default: 3]: " auth_choice
    case "${auth_choice:-3}" in
        1)
            read -r -s -p "Database password: " input
            echo
            PGPASSWORD="$input"
            PGPASSFILE=""
            ;;
        2)
            prompt_with_default ".pgpass file" "${PGPASSFILE:-$HOME/.pgpass}" PGPASSFILE
            PGPASSWORD=""
            ;;
        3)
            PGPASSWORD=""
            PGPASSFILE=""
            ;;
        *)
            warn "Invalid choice; authentication settings were not changed"
            ;;
    esac
    build_connection_settings
}

configure_connection() {
    case "$DB_ENGINE" in
        mysql)
            configure_mysql_connection
            ;;
        postgresql)
            configure_postgresql_connection
            ;;
    esac
}

# Run a menu action in a subshell so a failing action (or die) cannot end the
# menu. Calling it inside "if !" or "||" would disable set -e for everything the
# action runs, so errexit is switched off only around the subshell, which turns
# it back on for the action itself.
run_menu_action() {
    local status=0 restore_errexit=0
    [[ $- == *e* ]] && restore_errexit=1
    set +e
    (
        set -e
        "$@"
    )
    status=$?
    ((restore_errexit == 0)) || set -e

    if ((status != 0)); then
        warn "Operation failed; check the error above"
    fi
    pause_for_menu
}

choose_backup_file() {
    local files=()
    local file choice

    ensure_backup_directory
    while IFS= read -r file; do
        files+=("$file")
    done < <(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name '*.sql' -o -name '*.sql.gz' \) | sort -r)

    if ((${#files[@]} == 0)); then
        warn "No backup files are available in: $BACKUP_DIR"
        return 1
    fi

    echo
    echo "Available backups"
    local index
    for index in "${!files[@]}"; do
        printf '%d. %s\n' "$((index + 1))" "${files[$index]}"
    done
    read -r -p "Select a backup number: " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || {
        warn "Enter a valid number"
        return 1
    }
    ((choice >= 1 && choice <= ${#files[@]})) || {
        warn "Backup number is out of range"
        return 1
    }

    SELECTED_BACKUP_FILE="${files[$((choice - 1))]}"
}

menu_backup_database() {
    local database
    echo
    list_databases || true
    echo
    read -r -p "Database to back up: " database
    [[ -n "$database" ]] || {
        warn "Database name cannot be empty"
        return 1
    }
    backup_database "$database"
}

menu_restore_database() {
    local database
    choose_backup_file || return 1
    read -r -p "Target database name: " database
    [[ -n "$database" ]] || {
        warn "Database name cannot be empty"
        return 1
    }
    restore_database "$database" "$SELECTED_BACKUP_FILE"
}

menu_restore_all_databases() {
    local confirmation
    choose_backup_file || return 1
    warn "A full restore can overwrite multiple databases and database users."
    read -r -p "Type YES to continue: " confirmation
    [[ "$confirmation" == "YES" ]] || {
        info "Full restore cancelled"
        return 0
    }
    restore_all_databases "$SELECTED_BACKUP_FILE"
}

menu_cleanup_backups() {
    local keep_count
    read -r -p "Number of newest backups to keep: " keep_count
    cleanup_backups "$keep_count"
}

database_management_menu() {
    local choice endpoint

    while true; do
        case "$DB_ENGINE" in
            mysql)
                endpoint="$MYSQL_USER@$MYSQL_HOST:$MYSQL_PORT"
                ;;
            postgresql)
                endpoint="$PGUSER@$PGHOST:$PGPORT"
                ;;
        esac

        echo
        echo "============= SQL Management ============="
        echo "Engine: $DB_ENGINE"
        echo "Connection: $endpoint"
        echo "Backups: $BACKUP_DIR"
        echo "--------------------------------------------"
        echo "1. Configure database connection"
        echo "2. Check connection status"
        echo "3. List databases"
        echo "4. List backup files"
        echo "5. Back up one database"
        echo "6. Back up all databases"
        echo "7. Restore one database"
        echo "8. Restore all databases"
        echo "9. Clean up old backups"
        echo "0. Return to engine selection"
        echo "============================================"
        read -r -p "Select: " choice

        case "$choice" in
            1)
                configure_connection
                ;;
            2)
                run_menu_action show_status
                ;;
            3)
                run_menu_action list_databases
                ;;
            4)
                run_menu_action list_backups
                ;;
            5)
                run_menu_action menu_backup_database
                ;;
            6)
                run_menu_action backup_all_databases
                ;;
            7)
                run_menu_action menu_restore_database
                ;;
            8)
                run_menu_action menu_restore_all_databases
                ;;
            9)
                run_menu_action menu_cleanup_backups
                ;;
            0)
                return 0
                ;;
            *)
                warn "Invalid choice"
                ;;
        esac
    done
}

interactive_menu() {
    local choice

    while true; do
        echo
        echo "============= Database Engine ============="
        echo "1. MySQL / MariaDB"
        echo "2. PostgreSQL"
        echo "0. Exit"
        echo "==========================================="
        read -r -p "Select: " choice

        case "$choice" in
            1)
                set_database_engine mysql
                database_management_menu
                ;;
            2)
                set_database_engine postgresql
                database_management_menu
                ;;
            0)
                info "Exited"
                return 0
                ;;
            *)
                warn "Invalid choice"
                ;;
        esac
    done
}

init_settings() {
    BACKUP_DIR_CUSTOM=0
    if [[ -n "${BACKUP_DIR:-}" ]]; then
        BACKUP_DIR_CUSTOM=1
    fi
    BACKUP_DIR="${BACKUP_DIR:-$SCRIPT_DIR/backups/$DB_ENGINE}"
    MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
    MYSQL_PORT="${MYSQL_PORT:-3306}"
    MYSQL_USER="${MYSQL_USER:-root}"
    MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"
    MYSQL_CNF_FILE="${MYSQL_CNF_FILE:-}"
    MYSQL_CLIENT="${MYSQL_CLIENT:-mysql}"
    MYSQL_DUMP="${MYSQL_DUMP:-mysqldump}"

    PGHOST="${PGHOST:-127.0.0.1}"
    PGPORT="${PGPORT:-5432}"
    PGUSER="${PGUSER:-postgres}"
    PGPASSWORD="${PGPASSWORD:-}"
    PGPASSFILE="${PGPASSFILE:-}"
    PSQL="${PSQL:-psql}"
    PG_DUMP="${PG_DUMP:-pg_dump}"
    PG_DUMPALL="${PG_DUMPALL:-pg_dumpall}"
    CREATEDB="${CREATEDB:-createdb}"

    build_connection_settings
    SELECTED_BACKUP_FILE=""
}

main() {
    parse_global_options "$@"
    if ((REMAINING_COUNT > 0)); then
        set -- "${REMAINING_ARGS[@]}"
    else
        set --
    fi

    init_settings

    local command="${1:-menu}"
    case "$command" in
        menu)
            interactive_menu
            ;;
        help | -h | --help)
            show_help
            ;;
        status)
            show_status
            ;;
        databases)
            list_databases
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
        restore-all)
            restore_all_databases "${2:-}"
            ;;
        cleanup)
            cleanup_backups "${2:-}"
            ;;
        *)
            die "Unknown command: $command. Run ./sql_manage.sh help"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
