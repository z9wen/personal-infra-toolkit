#!/bin/bash

# Configuration variables - Update these according to your setup
BACKUP_BASE="/path/to/backup"
SITE_BACKUP_DIR="${BACKUP_BASE}/site"
DB_BACKUP_DIR="${BACKUP_BASE}/database/mysql/crontab_backup"
RCLONE_REMOTE="your-remote-name"
REMOTE_SITE_PATH="${RCLONE_REMOTE}:remote-path/site"
REMOTE_DB_PATH="${RCLONE_REMOTE}:remote-path/database"

# Get current timestamp
time_now() {
    date "+%Y-%m-%d %H:%M:%S"
}

echo "$(time_now) Starting backup process..."

# Sync website files
echo "$(time_now) Backing up site files..."
rclone sync "${SITE_BACKUP_DIR}" "${REMOTE_SITE_PATH}" -P
echo "$(time_now) Site backup completed"

# Sync database files
echo "$(time_now) Backing up database files..."
rclone sync "${DB_BACKUP_DIR}" "${REMOTE_DB_PATH}" -P
echo "$(time_now) Database backup completed"

echo "$(time_now) All backup tasks completed successfully"