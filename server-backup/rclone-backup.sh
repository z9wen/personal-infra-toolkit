#!/usr/bin/env bash
#
# Daily entry point for cron: build local archives with backup-local.sh,
# upload them with rclone and rotate the uploaded copies per site/database:
#   daily/    the newest KEEP_DAILY archives
#   weekly/   KEEP_WEEKLY copies made on Sundays
#   monthly/  KEEP_MONTHLY copies made on the 1st
#
# Weekly and monthly copies are server-side copies of daily/, so nothing is
# uploaded twice. Settings come from backup.conf next to this script, or from
# the file named by BACKUP_CONFIG (see backup.conf.example).
#
#   SKIP_LOCAL_BACKUP=1        only upload and rotate existing archives
#   BACKUP_DAY_OF_WEEK=7       act as if today were Sunday (1-7)
#   BACKUP_DAY_OF_MONTH=01     act as if today were the 1st

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${BACKUP_CONFIG:-$SCRIPT_DIR/backup.conf}"

# Defaults, overridden by the configuration file
BACKUP_BASE=""
RCLONE_DEST=""
KEEP_DAILY=2
KEEP_WEEKLY=1
KEEP_MONTHLY=1

# shellcheck source=server-backup/backup.conf.example
source "$CONFIG_FILE" || {
    echo "Cannot read $CONFIG_FILE" >&2
    exit 1
}
[ -n "$BACKUP_BASE" ] && [ -n "$RCLONE_DEST" ] || {
    echo "BACKUP_BASE and RCLONE_DEST must be set in $CONFIG_FILE" >&2
    exit 1
}

CATEGORIES="database web config"
TODAY="$(date +%Y%m%d)"
DAY_OF_WEEK="${BACKUP_DAY_OF_WEEK:-$(date +%u)}"
DAY_OF_MONTH="${BACKUP_DAY_OF_MONTH:-$(date +%d)}"
FAILED=""

time_now() {
    date "+%Y-%m-%d %H:%M:%S"
}

# Keep only the newest <keep> archives of each item (<item>-<YYYYMMDD>.tar.gz) under a remote path
prune_remote() {
    local path="$1" keep="$2" files
    files="$(rclone lsf --files-only "$path")" || return 1
    awk -v keep="$keep" '
        /-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]\.tar\.gz$/ {
            item = substr($0, 1, length($0) - 16)
            count[item]++
            name[item, count[item]] = $0
        }
        END {
            for (item in count)
                for (i = 1; i <= count[item] - keep; i++)
                    print name[item, i]
        }' <<<"$(sort <<<"$files")" | while read -r old; do
        rclone deletefile "$path/$old" && echo "$(time_now)   removed $path/$old"
    done
}

# Upload new archives to daily/, then promote today's on Sundays and on the 1st
upload_category() {
    local remote="$RCLONE_DEST/$1"
    # Local keeps as many days as daily/, so this only sends archives that are not uploaded yet
    rclone copy "$BACKUP_BASE/$1" "$remote/daily" --exclude '.*' || return 1
    prune_remote "$remote/daily" "$KEEP_DAILY" || return 1
    if [ "$DAY_OF_WEEK" = "7" ]; then
        rclone copy "$remote/daily" "$remote/weekly" --include "*-$TODAY.tar.gz" || return 1
        prune_remote "$remote/weekly" "$KEEP_WEEKLY" || return 1
    fi
    if [ "$DAY_OF_MONTH" = "01" ]; then
        rclone copy "$remote/daily" "$remote/monthly" --include "*-$TODAY.tar.gz" || return 1
        prune_remote "$remote/monthly" "$KEEP_MONTHLY" || return 1
    fi
}

echo "$(time_now) Starting backup process..."

if [ -z "${SKIP_LOCAL_BACKUP:-}" ]; then
    "$SCRIPT_DIR/backup-local.sh" || FAILED="$FAILED local-backups"
fi

for category in $CATEGORIES; do
    echo "$(time_now) Uploading $category..."
    if upload_category "$category"; then
        echo "$(time_now) $category upload completed"
    else
        echo "$(time_now) $category upload FAILED"
        FAILED="$FAILED $category"
    fi
done

if [ -n "$FAILED" ]; then
    echo "$(time_now) Backup finished with failures:$FAILED"
    exit 1
fi
echo "$(time_now) All backup tasks completed successfully"
