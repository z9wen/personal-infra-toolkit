#!/bin/bash
#
# Upload HestiaCP backup archives to an rclone remote and keep the newest
# KEEP_BACKUPS archives per HestiaCP user on the remote.
#
# Only HestiaCP archives (<user>.<YYYY-MM-DD_HH-MM-SS>.tar) in the top level of
# BACKUP_BASE are handled. Age is taken from the timestamp in the archive name,
# so the result does not depend on remote modification times. Only the newest
# KEEP_BACKUPS local archives per user are uploaded, so archives removed from the
# remote by retention are not uploaded again on the next run. Other files on the
# remote are never deleted.
#
# Every setting below can be overridden through the environment.

set -euo pipefail

# ========== Configuration Variables ==========
# HestiaCP backup directory
BACKUP_BASE="${BACKUP_BASE:-/backup}"

# rclone remote name (must be configured first using rclone config)
RCLONE_REMOTE="${RCLONE_REMOTE:-mycloud}"

# Remote path
REMOTE_PATH="${REMOTE_PATH:-${RCLONE_REMOTE}:HestiaCP-Backups}"

# Number of latest backups to keep per HestiaCP user (e.g., keep latest 5)
KEEP_BACKUPS="${KEEP_BACKUPS:-5}"

# Log file
LOG_FILE="${LOG_FILE:-/var/log/hestia-backup-sync.log}"

# HestiaCP archive name: <user>.<YYYY-MM-DD_HH-MM-SS>.tar
ARCHIVE_PATTERN='^(.+)\.([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2})\.tar$'

FILES_FROM=""

# ========== Function Definitions ==========
time_now() {
    date "+%Y-%m-%d %H:%M:%S"
}

log_msg() {
    echo "$(time_now) $1" | tee -a "$LOG_FILE"
}

cleanup() {
    if [[ -n "$FILES_FROM" ]]; then
        rm -f -- "$FILES_FROM"
    fi
}

# Reads archive names on stdin and prints "keep<TAB>name" or "drop<TAB>name"
# for every HestiaCP archive: the newest $1 archives of each user are kept.
# Names that are not HestiaCP archives are ignored.
classify_archives() {
    local keep_count="$1" name tab=$'\t'

    while IFS= read -r name; do
        if [[ "$name" =~ $ARCHIVE_PATTERN ]]; then
            printf '%s\t%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$name"
        fi
    done | sort -t "$tab" -k1,1 -k2,2r | awk -F '\t' -v keep="$keep_count" '
        $1 != user { user = $1; count = 0 }
        { count++; print (count <= keep ? "keep" : "drop") "\t" $3 }
    '
}

list_local_archives() {
    local path
    for path in "$BACKUP_BASE"/*.tar; do
        [[ -f "$path" ]] && printf '%s\n' "${path##*/}"
    done
    return 0
}

upload_backups() {
    local upload_list

    upload_list="$(list_local_archives | classify_archives "$KEEP_BACKUPS" | awk -F '\t' '$1 == "keep" { print $2 }')"
    if [[ -z "$upload_list" ]]; then
        log_msg "WARNING: No HestiaCP backup archives found in $BACKUP_BASE"
        return 0
    fi

    FILES_FROM="$(mktemp "${TMPDIR:-/tmp}/hestia-backup-sync.XXXXXX")" || return 1
    printf '%s\n' "$upload_list" >"$FILES_FROM" || return 1

    # Copy backups to remote (without deleting old remote files)
    log_msg "Copying the newest $KEEP_BACKUPS backups per user to remote storage..."
    rclone copy "$BACKUP_BASE" "$REMOTE_PATH" \
        --files-from "$FILES_FROM" \
        --transfers 4 \
        --checkers 8 \
        --stats 1m \
        --log-level INFO \
        --log-file "$LOG_FILE"
}

# Clean up old remote backups, keeping only the latest N per user.
prune_remote_backups() {
    local remote_files status name failures=0

    log_msg "Cleaning up old remote backups (keeping latest $KEEP_BACKUPS per user)..."
    if ! remote_files="$(rclone lsf "$REMOTE_PATH" --files-only)"; then
        log_msg "ERROR: Could not list remote backups in $REMOTE_PATH"
        return 1
    fi

    while IFS=$'\t' read -r status name; do
        [[ "$status" == "drop" ]] || continue

        log_msg "Deleting old backup: $name"
        if ! rclone deletefile "$REMOTE_PATH/$name"; then
            log_msg "ERROR: Could not delete $REMOTE_PATH/$name"
            failures=$((failures + 1))
        fi
    done < <(printf '%s\n' "$remote_files" | classify_archives "$KEEP_BACKUPS")

    if ((failures > 0)); then
        log_msg "ERROR: $failures old backup(s) could not be deleted"
        return 1
    fi
    log_msg "Old backups cleaned up"
}

main() {
    # ========== Start Backup Process ==========
    log_msg "========== Starting HestiaCP backup sync =========="

    if [[ ! "$KEEP_BACKUPS" =~ ^[1-9][0-9]*$ ]]; then
        log_msg "ERROR: KEEP_BACKUPS must be a positive integer (got: $KEEP_BACKUPS)"
        exit 1
    fi

    # Check if backup directory exists
    if [[ ! -d "$BACKUP_BASE" ]]; then
        log_msg "ERROR: Backup directory $BACKUP_BASE does not exist!"
        exit 1
    fi

    trap cleanup EXIT
    if upload_backups; then
        log_msg "Backup copy completed successfully"
    else
        log_msg "ERROR: Backup copy failed!"
        exit 1
    fi

    if ! prune_remote_backups; then
        log_msg "========== Backup sync completed with errors =========="
        exit 1
    fi

    # Display current remote backup list
    log_msg "Current remote backups:"
    rclone lsf "$REMOTE_PATH" --recursive | tee -a "$LOG_FILE" || log_msg "WARNING: Could not list remote backups"

    log_msg "========== Backup sync completed successfully =========="
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
