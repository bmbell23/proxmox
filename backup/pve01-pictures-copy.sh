#!/bin/bash
# Copy ALL of boston's media/pictures onto brighton (pve01's 2 TB Hitachi) (#11).
# Runs on pve01 as user `homelab`, from Dagu, out of the root-owned /opt/homelab clone. Needs no root:
# boston is mounted read-only over CIFS and world-readable; /mnt/brighton/pictures belongs to homelab.
#
# A plain copy, not versioned: no --delete, so a photo deleted on boston stays here until someone
# removes it on purpose. Versioned history for pictures would be a restic repo instead (a later ticket).
set -uo pipefail

SRC=/mnt/remote/boston/media/pictures
DEST=${PICTURES_COPY_DEST:-/mnt/brighton/pictures}

# If brighton isn't mounted, /mnt/brighton is a bare dir on pve01's 94G root: refuse rather than fill it.
mountpoint -q /mnt/brighton || { echo "FAILED: /mnt/brighton is not mounted" >&2; exit 1; }
[ -d "$DEST" ] && [ -w "$DEST" ] || { echo "FAILED: $DEST missing or not writable" >&2; exit 1; }

# The boston share is an automount: the first ls wakes it. A share whose disk is missing serves an
# empty dir (#5), so also insist on the two folders every real pictures tree here has.
timeout 30 ls "$SRC" >/dev/null 2>&1 || { echo "FAILED: $SRC is not readable" >&2; exit 1; }
findmnt -no OPTIONS -t cifs /mnt/remote/boston | grep -q '^ro,' || { echo "FAILED: boston is not mounted read-only" >&2; exit 1; }
for d in library immich-storage; do
    [ -d "$SRC/$d" ] || { echo "FAILED: $SRC/$d missing; is boston's disk behind the share?" >&2; exit 1; }
done

echo "Copy started $(date -Is): $SRC/ -> $DEST/"
# -rt, not -a: CIFS owners and modes are fake. --modify-window=1 because NTFS/CIFS mtimes are coarse.
rsync -rt --modify-window=1 --partial --stats "$SRC/" "$DEST/"
rc=$?
# 24 = some files vanished mid-copy (Immich moving uploads): not a failure of the copy.
[ "$rc" -eq 24 ] && { echo "note: some source files vanished during the copy (rsync 24)"; rc=0; }
echo "Copy finished $(date -Is), rsync exit $rc; brighton: $(df -h --output=used,avail /mnt/brighton | tail -1)"
exit "$rc"
