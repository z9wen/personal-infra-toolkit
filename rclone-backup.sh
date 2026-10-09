#!/usr/bin/env bash
#
# Sync local site and database backups to an rclone remote.
#
# Configure by editing the defaults below or by exporting the variables, e.g.:
#   BACKUP_BASE=/www/backup RCLONE_REMOTE=r2 ./rclone-backup.sh
#
# Intended for cron: it fails loudly, never reports success after a failed
# step and refuses to run twice at the same time.

set -euo pipefail

BACKUP_BASE="${BACKUP_BASE:-/path/to/backup}"
SITE_BACKUP_DIR="${SITE_BACKUP_DIR:-${BACKUP_BASE}/site}"
DB_BACKUP_DIR="${DB_BACKUP_DIR:-${BACKUP_BASE}/database/mysql/crontab_backup}"
RCLONE_REMOTE="${RCLONE_REMOTE:-your-remote-name}"
REMOTE_BASE_PATH="${REMOTE_BASE_PATH:-remote-path}"
REMOTE_SITE_PATH="${REMOTE_SITE_PATH:-${RCLONE_REMOTE}:${REMOTE_BASE_PATH}/site}"
REMOTE_DB_PATH="${REMOTE_DB_PATH:-${RCLONE_REMOTE}:${REMOTE_BASE_PATH}/database}"
LOCK_FILE="${LOCK_FILE:-/tmp/rclone-backup.lock}"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*"
}

die() {
    log "ERROR: $*" >&2
    exit 1
}

command -v rclone >/dev/null 2>&1 || die "rclone is not installed"

if [[ ${BACKUP_BASE} == /path/to/backup || ${RCLONE_REMOTE} == your-remote-name ]]; then
    die "Set BACKUP_BASE and RCLONE_REMOTE before running"
fi

rclone listremotes | grep -qx "${RCLONE_REMOTE}:" || die "rclone remote '${RCLONE_REMOTE}' is not configured"

exec 9>"${LOCK_FILE}"
flock -n 9 || die "another backup is already running (${LOCK_FILE})"

# Only show progress output when attached to a terminal; keep cron logs clean.
rclone_args=()
[[ -t 1 ]] && rclone_args+=(--progress)

sync_dir() {
    local name=$1 source=$2 destination=$3

    [[ -d ${source} ]] || die "${name} backup directory not found: ${source}"
    log "Backing up ${name}: ${source} -> ${destination}"
    rclone sync "${source}" "${destination}" ${rclone_args[@]+"${rclone_args[@]}"}
    log "${name} backup completed"
}

log "Starting backup process"
sync_dir "site" "${SITE_BACKUP_DIR}" "${REMOTE_SITE_PATH}"
sync_dir "database" "${DB_BACKUP_DIR}" "${REMOTE_DB_PATH}"
log "All backup tasks completed successfully"
