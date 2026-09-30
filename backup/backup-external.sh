#!/bin/bash

# Backup script for External Drive
# Backs up large media files to /mnt/external/ (2TB external HDD)
# This runs separately because the external drive may not always be connected.
# Exits non-zero on failure so a scheduler (Dagu) can alert. A missing drive counts as a
# failure unless BACKUP_EXTERNAL_OPTIONAL=1.

set -euo pipefail

# Cron can run with a minimal PATH, so set a predictable one.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Set variables
BACKUP_ROOT="/mnt/external"
LOG_DIR="${BACKUP_LOG_DIR:-${HOME:-/tmp}/.local/state/backups}"
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
LOGFILE=""
ENABLE_HEALTH_CHECK="${BACKUP_HEALTH_CHECK:-1}"
EXCLUDED_PICTURES_SUBPATH="${BACKUP_PICTURES_EXCLUDE_SUBPATH:-thumbs/defc20ec-b70a-49b2-9938-70a4831be653/b4/4c/}"

# Create log directory
if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
    LOG_DIR="/tmp/backups-${USER:-$(id -u)}"
    mkdir -p "$LOG_DIR"
fi

# Create log file
LOGFILE="$LOG_DIR/backup-external-$TIMESTAMP.log"

# Acquire lock if flock is available to prevent concurrent runs of this script
if command -v flock >/dev/null 2>&1; then
    # Fixed name: under `ssh proxmox 'bash -s' < script`, $0 is just "bash".
    LOCK_FILE="/tmp/backup-external.lock"
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        echo "[$(date +%Y-%m-%d\ %H:%M:%S)] ERROR: Another backup-external.sh run is already in progress."
        exit 1
    fi
fi

# Log function
log() {
    echo "[$(date +%Y-%m-%d\ %H:%M:%S)] $1" | tee -a "$LOGFILE"
}

# mountpoint passes on a dead-but-mounted ntfs-3g/FUSE disk (sdc from 2026-05-30 on), and a
# plain `timeout ls` can hang with it if ls is stuck in the kernel. So ls runs in the background
# and we stop waiting after 10 s, whether or not it can be killed.
probe_mount() {
    local dir="$1" pid i
    ls "$dir" >/dev/null 2>&1 &
    pid=$!
    for i in $(seq 1 20); do
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid"
            return
        fi
        sleep 0.5
    done
    kill -9 "$pid" 2>/dev/null || true
    return 124
}

# Preflight check that confirms the mounted destination accepts basic writes.
preflight_health_check() {
    local probe_dir="$BACKUP_ROOT/.backup-healthcheck"
    local probe_file="$probe_dir/probe-$$"

    if ! mkdir -p "$probe_dir" 2>/dev/null; then
        log "FAILED: Cannot create health-check directory: $probe_dir"
        return 1
    fi

    if ! : > "$probe_file" 2>/dev/null; then
        log "FAILED: Destination is not writable (health-check write failed): $BACKUP_ROOT"
        return 1
    fi

    if ! rm -f "$probe_file" 2>/dev/null; then
        log "FAILED: Destination cleanup failed during health-check: $probe_file"
        return 1
    fi

    log "Preflight health-check passed for destination: $BACKUP_ROOT"
    return 0
}

# Rsync function
run_rsync() {
    local source="$1"
    local dest="$2"
    local description="$3"
    shift 3
    local extra_rsync_opts=("$@")

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
    if [ "${#extra_rsync_opts[@]}" -gt 0 ]; then
        rsync_opts+=("${extra_rsync_opts[@]}")
        log "  Extra rsync options: ${extra_rsync_opts[*]}"
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
log "External Drive Backup started"
log "========================================="

# Check if dry run is enabled
if [ "${BACKUP_DRY_RUN:-0}" = "1" ]; then
    log "DRY RUN enabled (no files will be changed)"
fi

# Check if external drive is mounted
if ! mountpoint -q "$BACKUP_ROOT"; then
    if [ "${BACKUP_EXTERNAL_OPTIONAL:-0}" = "1" ]; then
        log "WARNING: External drive not mounted at $BACKUP_ROOT"
        log "Skipping external backup (BACKUP_EXTERNAL_OPTIONAL=1)"
        exit 0
    fi
    log "FAILED: External drive not mounted at $BACKUP_ROOT, nothing backed up"
    exit 1
fi

if probe_mount "$BACKUP_ROOT"; then
    :
else
    rc=$?
    if [ "$rc" -eq 124 ]; then
        log "FAILED: $BACKUP_ROOT is mounted but ls hung for 10 s (dead disk?)"
    else
        log "FAILED: $BACKUP_ROOT is mounted but can't be listed (ls exit $rc; dead disk?)"
    fi
    exit 1
fi

if [ "$ENABLE_HEALTH_CHECK" = "1" ]; then
    log ""
    log "Running preflight health-check..."
    if ! preflight_health_check; then
        log "FAILED: Aborting before rsync due to health-check failure"
        exit 1
    fi
fi

# Create backup directories
mkdir -p "$BACKUP_ROOT/media/pictures"
mkdir -p "$BACKUP_ROOT/media/videos"

log ""
log "Backup scope includes only:"
log "  - /mnt/boston/media/pictures"
log "  - /mnt/boston/media/videos"
log "Not included by this script: /mnt/boston/media/quarantine"
log "Quarantine is never scanned/read by this backup job"

PICTURES_EXTRA_OPTS=()
if [ -n "$EXCLUDED_PICTURES_SUBPATH" ]; then
    PICTURES_EXTRA_OPTS=(--exclude="$EXCLUDED_PICTURES_SUBPATH")
    log "Excluded pictures subpath: /mnt/boston/media/pictures/$EXCLUDED_PICTURES_SUBPATH"
fi

# Run backups
BACKUP_RESULTS=()

# Backup pictures
log ""
log "--- Backup 1/2: /mnt/boston/media/pictures ---"
if run_rsync \
    "/mnt/boston/media/pictures/" \
    "$BACKUP_ROOT/media/pictures/" \
    "/mnt/boston/media/pictures" \
    "${PICTURES_EXTRA_OPTS[@]}"; then
    BACKUP_RESULTS+=("/mnt/boston/media/pictures: SUCCESS")
else
    BACKUP_RESULTS+=("/mnt/boston/media/pictures: FAILED")
fi

log ""
log "--- Backup 2/2: /mnt/boston/media/videos ---"
if run_rsync \
    "/mnt/boston/media/videos/" \
    "$BACKUP_ROOT/media/videos/" \
    "/mnt/boston/media/videos"; then
    BACKUP_RESULTS+=("/mnt/boston/media/videos: SUCCESS")
else
    BACKUP_RESULTS+=("/mnt/boston/media/videos: FAILED")
fi

log ""
log "========================================="
log "External Backup Summary"
log "========================================="
for result in "${BACKUP_RESULTS[@]}"; do
    log "$result"
done
log "========================================="

log ""
log "External drive usage:"
df -h "$BACKUP_ROOT" | tee -a "$LOGFILE"

log ""
log "External backup completed at $(date)"
log "Full log: $LOGFILE"

if printf '%s\n' "${BACKUP_RESULTS[@]}" | grep -q "FAILED"; then
    exit 1
fi

exit 0
