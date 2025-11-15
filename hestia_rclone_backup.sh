#!/bin/bash

# ========== Configuration Variables ==========
# HestiaCP backup directory
BACKUP_BASE="/backup"

# rclone remote name (must be configured first using rclone config)
RCLONE_REMOTE="mycloud"

# Remote path
REMOTE_PATH="${RCLONE_REMOTE}:HestiaCP-Backups"

# Number of latest backups to keep (e.g., keep latest 5)
KEEP_BACKUPS=5

# Log file
LOG_FILE="/var/log/hestia-backup-sync.log"

# ========== Function Definitions ==========
time_now() {
    date "+%Y-%m-%d %H:%M:%S"
}

log_msg() {
    echo "$(time_now) $1" | tee -a "$LOG_FILE"
}

# ========== Start Backup Process ==========
log_msg "========== Starting HestiaCP backup sync =========="

# Check if backup directory exists
if [ ! -d "$BACKUP_BASE" ]; then
    log_msg "ERROR: Backup directory $BACKUP_BASE does not exist!"
    exit 1
fi

# Copy backups to remote (without deleting old remote files)
log_msg "Copying backups to remote storage..."
rclone copy "$BACKUP_BASE" "$REMOTE_PATH" \
    --transfers 4 \
    --checkers 8 \
    --stats 1m \
    --log-level INFO \
    -P

if [ $? -eq 0 ]; then
    log_msg "Backup copy completed successfully"
else
    log_msg "ERROR: Backup copy failed!"
    exit 1
fi

# Clean up old remote backups, keeping only the latest N
log_msg "Cleaning up old remote backups (keeping latest $KEEP_BACKUPS)..."

# Get all remote backup files, sort by time, and delete old ones
rclone lsf "$REMOTE_PATH" --recursive --files-only | sort -r | tail -n +$((KEEP_BACKUPS + 1)) | while read file; do
    log_msg "Deleting old backup: $file"
    rclone deletefile "$REMOTE_PATH/$file"
done

log_msg "Old backups cleaned up"

# Display current remote backup list
log_msg "Current remote backups:"
rclone lsf "$REMOTE_PATH" --recursive | tee -a "$LOG_FILE"

log_msg "========== Backup sync completed successfully =========="
