#!/bin/bash
# Proxmox configuration backup
# Backs up everything needed to rebuild this server from scratch on new hardware:
#   - /etc/pve/        (all Proxmox config: VMs, storage, network, users, backup jobs)
#   - /etc/network/    (network interfaces)
#   - /etc/fstab       (drive mount points)
#   - /etc/hostname, /etc/hosts
#   - /etc/udev/rules.d/ (automount rules)
#   - crontab -l       (the running user's crontab; scripts themselves live in the dotfiles repo)
# To: /mnt/boston/proxmox-config-backups/ (override with PROXMOX_CONFIG_BACKUP_DEST; a shadow
#     run must use its own directory, since pruning only looks inside $DEST)
# Retains last 30 daily backups, but never prunes the newest successful archive or the
# newest complete one (a root run, nothing skipped), and prunes nothing until one succeeds.
# Runs as brandon (brandon is in www-data group for /etc/pve read access).
# Root-only parts of /etc/pve (/etc/pve/priv, /etc/pve/nodes/*/priv) are skipped and logged
# unless run as root; such an archive is logged as "Scope: partial".
# Exits non-zero on failure so a scheduler (Dagu) can alert.

set -euo pipefail

DEST="${PROXMOX_CONFIG_BACKUP_DEST:-/mnt/boston/proxmox-config-backups}"
KEEP=30
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
ARCHIVE="$DEST/proxmox-config-$TIMESTAMP.tar.gz"
LOG="$DEST/proxmox-config-$TIMESTAMP.log"

log() {
    echo "[$(date +%Y-%m-%d\ %H:%M:%S)] $1" | tee -a "$LOG"
}

if ! mountpoint -q /mnt/boston; then
    echo "ERROR: /mnt/boston not mounted, aborting config backup" >&2
    exit 1
fi

mkdir -p "$DEST"
log "Starting Proxmox config backup → $ARCHIVE"

# Skip whatever under /etc/pve this user can't read (as brandon: /etc/pve/priv and
# /etc/pve/nodes/*/priv, i.e. authkey, ssh keys, API tokens, node certs) instead of guessing paths.
TAR_EXCLUDES=()
while IFS= read -r p; do
    TAR_EXCLUDES+=("--exclude=$p")
    log "Not readable as $(id -un), skipping: $p"
done < <(find /etc/pve -mindepth 1 ! -readable -prune -print 2>> "$LOG")
if [ "${#TAR_EXCLUDES[@]}" -eq 0 ]; then
    SCOPE="complete"
else
    SCOPE="partial (${#TAR_EXCLUDES[@]} path(s) under /etc/pve skipped; run as root for a complete archive)"
fi

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
crontab -l > "$STAGING/crontab-$(id -un).txt" 2>/dev/null || log "WARNING: no crontab for $(id -un)"

FAILED=0
# Write to .partial and rename on success, so a failed run never leaves a half archive behind.
tar -czf "$ARCHIVE.partial" \
    --no-wildcards "${TAR_EXCLUDES[@]}" \
    /etc/pve \
    /etc/network/interfaces \
    /etc/fstab \
    /etc/hostname \
    /etc/hosts \
    /etc/udev/rules.d \
    -C "$STAGING" . \
    2>> "$LOG" || {
    TAR_EXIT=$?
    if [ $TAR_EXIT -eq 1 ]; then
        log "WARNING: tar completed with warnings (files changed during backup - archive is usable)"
    else
        log "ERROR: tar failed with exit code $TAR_EXIT (see tar messages above in $LOG)"
        FAILED=1
    fi
}

if [ "$FAILED" -eq 0 ]; then
    mv "$ARCHIVE.partial" "$ARCHIVE"
    SIZE=$(du -sh "$ARCHIVE" | cut -f1)
    log "Archive created: $ARCHIVE ($SIZE)"
    log "Scope: $SCOPE"
else
    rm -f "$ARCHIVE.partial"
fi

# Prune old backups, keep the newest $KEEP. A run counts as successful when its log says
# "Archive created" and as complete when it also says "Scope: complete". The newest successful
# and the newest complete archive are never removed, however old; and if no archive has ever
# succeeded, nothing is removed at all.
ARCHIVES=()
while IFS= read -r f; do ARCHIVES+=("$f"); done < <(ls -1t "$DEST"/proxmox-config-*.tar.gz 2>/dev/null)
KEEP_SUCCESS=""
KEEP_COMPLETE=""
for f in "${ARCHIVES[@]}"; do
    flog="${f%.tar.gz}.log"
    grep -q "Archive created" "$flog" 2>/dev/null || continue
    [ -n "$KEEP_SUCCESS" ] || KEEP_SUCCESS="$f"
    if [ -z "$KEEP_COMPLETE" ] && grep -q "Scope: complete" "$flog"; then KEEP_COMPLETE="$f"; fi
done
if [ "${#ARCHIVES[@]}" -gt "$KEEP" ]; then
    if [ -z "$KEEP_SUCCESS" ]; then
        log "WARNING: no successful archive on disk, so not pruning anything (${#ARCHIVES[@]} archives)"
    else
        log "Pruning archives beyond the newest $KEEP. Protected: newest successful $(basename "$KEEP_SUCCESS"), newest complete $([ -n "$KEEP_COMPLETE" ] && basename "$KEEP_COMPLETE" || echo "none on disk")"
        for f in "${ARCHIVES[@]:$KEEP}"; do
            if [ "$f" = "$KEEP_SUCCESS" ] || [ "$f" = "$KEEP_COMPLETE" ]; then
                log "  Kept (protected): $(basename "$f")"
                continue
            fi
            rm -f "$f" "${f%.tar.gz}.log"
            log "  Removed: $(basename "$f")"
        done
    fi
fi
# Logs of failed runs have no archive, so the loop above never removes them.
# Logs that still have an archive are kept: they're how a run is known to be successful/complete.
OLD_LOGS=0
while IFS= read -r l; do
    [ -e "${l%.log}.tar.gz" ] && continue
    rm -f "$l"
    OLD_LOGS=$((OLD_LOGS + 1))
done < <(find "$DEST" -maxdepth 1 -name 'proxmox-config-*.log' -mtime +"$KEEP")
if [ "$OLD_LOGS" -gt 0 ]; then
    log "Pruned $OLD_LOGS log(s) of failed runs older than $KEEP days"
fi

log "Done. Backups on disk: $(ls -1 "$DEST"/proxmox-config-*.tar.gz 2>/dev/null | wc -l)"

if [ "$FAILED" -ne 0 ]; then
    log "FAILED: config backup did not produce an archive"
    exit 1
fi
