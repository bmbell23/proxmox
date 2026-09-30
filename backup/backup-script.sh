#!/bin/bash

# Backup script for ProxMox
# Backs up:
#   1. /mnt/boston/docker-backups/
#   2. /mnt/boston/documents/
#   3. /mnt/boston/media/audiobooks/
#   4. /mnt/boston/media/books/
#   5. /mnt/boston/media/games/
#   6. /mnt/boston/media/audiobookshelf/
#   7. /mnt/boston/media/music/
#   8. /mnt/boston/media/other/
# To: /mnt/backups/ (sdc1 - 1TB SSD)
# Exits non-zero on any failure, with the reason in the log, so a scheduler (Dagu) can alert.

set -euo pipefail

# Cron can run with a minimal PATH, so set a predictable one.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

BACKUP_ROOT="/mnt/backups"
LOG_DIR="${BACKUP_LOG_DIR:-${HOME:-/tmp}/.local/state/backups}"
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
LOGFILE=""

if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
    LOG_DIR="/tmp/backups-${USER:-$(id -u)}"
    mkdir -p "$LOG_DIR"
fi

LOGFILE="$LOG_DIR/backup-$TIMESTAMP.log"

if command -v flock >/dev/null 2>&1; then
    # Fixed name: under `ssh proxmox 'bash -s' < script`, $0 is just "bash".
    LOCK_FILE="/tmp/backup-script.lock"
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        echo "[$(date +%Y-%m-%d\ %H:%M:%S)] ERROR: Another backup-script.sh run is already in progress."
        exit 1
    fi
fi

log() {
    echo "[$(date +%Y-%m-%d\ %H:%M:%S)] $1" | tee -a "$LOGFILE"
}

# set -e would otherwise exit without saying why (e.g. mkdir on a drive giving I/O errors).
trap 'rc=$?; log "FAILED: \"$BASH_COMMAND\" exited $rc (line $LINENO), aborting"; exit $rc' ERR

# Preflight check that confirms the mounted destination accepts basic writes.
preflight_health_check() {
    local probe_file="$BACKUP_ROOT/.backup-healthcheck-$$"
    local err

    if ! err=$(: 2>&1 > "$probe_file"); then
        log "FAILED: Destination is not writable (health-check write failed): $BACKUP_ROOT: $err"
        return 1
    fi
    if ! err=$(rm -f "$probe_file" 2>&1); then
        log "FAILED: Destination cleanup failed during health-check: $probe_file: $err"
        return 1
    fi
    log "Preflight health-check passed for destination: $BACKUP_ROOT"
}

run_rsync() {
    local source="$1"
    local dest="$2"
    local description="$3"

    log "Starting backup: $description"
    log "  Source: $source"
    log "  Destination: $dest"

    if [ ! -d "$source" ]; then
        log "FAILED: Source directory does not exist: $source"
        return 1
    fi

    local rsync_opts=(-avh --delete --stats)
    if [ "${BACKUP_DRY_RUN:-0}" = "1" ]; then
        rsync_opts+=(--dry-run)
    fi

    if rsync "${rsync_opts[@]}" "$source" "$dest" >> "$LOGFILE" 2>&1; then
        log "SUCCESS: Backed up: $description"
        return 0
    else
        log "FAILED: Backup failed: $description"
        return 1
    fi
}

log "========================================="
log "Backup started"
log "========================================="

if [ "${BACKUP_DRY_RUN:-0}" = "1" ]; then
    log "DRY RUN enabled (no files will be changed)"
fi

if ! mountpoint -q "$BACKUP_ROOT"; then
    log "ERROR: Backup drive not mounted at $BACKUP_ROOT"
    exit 1
fi

if ! preflight_health_check; then
    log "FAILED: Aborting before rsync due to health-check failure"
    exit 1
fi

mkdir -p "$BACKUP_ROOT/docker-backups"
mkdir -p "$BACKUP_ROOT/documents"
mkdir -p "$BACKUP_ROOT/media/audiobooks"
mkdir -p "$BACKUP_ROOT/media/books"
mkdir -p "$BACKUP_ROOT/media/games"
mkdir -p "$BACKUP_ROOT/media/audiobookshelf"
mkdir -p "$BACKUP_ROOT/media/music"
mkdir -p "$BACKUP_ROOT/media/other"

BACKUP_RESULTS=()

log ""
log "--- Backup 1/8: /mnt/boston/docker-backups ---"
if run_rsync \
    "/mnt/boston/docker-backups/" \
    "$BACKUP_ROOT/docker-backups/" \
    "/mnt/boston/docker-backups"; then
    BACKUP_RESULTS+=("/mnt/boston/docker-backups: SUCCESS")
else
    BACKUP_RESULTS+=("/mnt/boston/docker-backups: FAILED")
fi

log ""
log "--- Backup 2/8: /mnt/boston/documents ---"
if run_rsync \
    "/mnt/boston/documents/" \
    "$BACKUP_ROOT/documents/" \
    "/mnt/boston/documents"; then
    BACKUP_RESULTS+=("/mnt/boston/documents: SUCCESS")
else
    BACKUP_RESULTS+=("/mnt/boston/documents: FAILED")
fi

log ""
log "--- Backup 3/8: /mnt/boston/media/audiobooks ---"
if run_rsync \
    "/mnt/boston/media/audiobooks/" \
    "$BACKUP_ROOT/media/audiobooks/" \
    "/mnt/boston/media/audiobooks"; then
    BACKUP_RESULTS+=("/mnt/boston/media/audiobooks: SUCCESS")
else
    BACKUP_RESULTS+=("/mnt/boston/media/audiobooks: FAILED")
fi

log ""
log "--- Backup 4/8: /mnt/boston/media/books ---"
if run_rsync \
    "/mnt/boston/media/books/" \
    "$BACKUP_ROOT/media/books/" \
    "/mnt/boston/media/books"; then
    BACKUP_RESULTS+=("/mnt/boston/media/books: SUCCESS")
else
    BACKUP_RESULTS+=("/mnt/boston/media/books: FAILED")
fi

log ""
log "--- Backup 5/8: /mnt/boston/media/games ---"
if run_rsync \
    "/mnt/boston/media/games/" \
    "$BACKUP_ROOT/media/games/" \
    "/mnt/boston/media/games"; then
    BACKUP_RESULTS+=("/mnt/boston/media/games: SUCCESS")
else
    BACKUP_RESULTS+=("/mnt/boston/media/games: FAILED")
fi

log ""
log "--- Backup 6/8: /mnt/boston/media/audiobookshelf ---"
if run_rsync \
    "/mnt/boston/media/audiobookshelf/" \
    "$BACKUP_ROOT/media/audiobookshelf/" \
    "/mnt/boston/media/audiobookshelf"; then
    BACKUP_RESULTS+=("/mnt/boston/media/audiobookshelf: SUCCESS")
else
    BACKUP_RESULTS+=("/mnt/boston/media/audiobookshelf: FAILED")
fi

log ""
log "--- Backup 7/8: /mnt/boston/media/music ---"
if run_rsync \
    "/mnt/boston/media/music/" \
    "$BACKUP_ROOT/media/music/" \
    "/mnt/boston/media/music"; then
    BACKUP_RESULTS+=("/mnt/boston/media/music: SUCCESS")
else
    BACKUP_RESULTS+=("/mnt/boston/media/music: FAILED")
fi

log ""
log "--- Backup 8/8: /mnt/boston/media/other ---"
if run_rsync \
    "/mnt/boston/media/other/" \
    "$BACKUP_ROOT/media/other/" \
    "/mnt/boston/media/other"; then
    BACKUP_RESULTS+=("/mnt/boston/media/other: SUCCESS")
else
    BACKUP_RESULTS+=("/mnt/boston/media/other: FAILED")
fi

log ""
log "========================================="
log "Backup Summary"
log "========================================="
for result in "${BACKUP_RESULTS[@]}"; do
    log "$result"
done
log "========================================="

log ""
log "Backup drive usage:"
df -h "$BACKUP_ROOT" | tee -a "$LOGFILE"

log ""
log "Backup completed at $(date)"
log "Full log: $LOGFILE"

if printf '%s\n' "${BACKUP_RESULTS[@]}" | grep -q "FAILED"; then
    exit 1
fi

exit 0
