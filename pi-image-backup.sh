#!/bin/bash
#
# pi-image-backup.sh - wrapper around RonR's image-backup for Raspberry Pi
#
# Two modes:
#
#   --incremental (default)
#       Maintains ONE persistent image file on the NAS. On first run it
#       performs a full backup, shrinks the filesystem to its minimum size
#       and then adds INCREMENTAL_RESERVE_MB of free space inside the image
#       for future incremental runs to write into. Every subsequent run
#       performs a true incremental rsync update of that same image.
#       This is the mode intended for routine (cron) backups.
#
#   --backup-img
#       Always creates a brand-new, standalone full-backup image named
#       backup-raspi-YYYY-MM-DD.img in the same NAS location. It is shrunk
#       and given BACKUP_IMG_RESERVE_MB of free space afterwards. Intended
#       for occasional manual full snapshots, not for routine incremental
#       growth. Running it twice on the same day overwrites that day's file.
#
# Cron (as root), routine incremental backup only:
#   0 5 * * 1,4 /usr/local/bin/pi-image-backup.sh --incremental

set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ---------------- Settings ----------------
IMAGE_BACKUP="/usr/local/bin/RonR-RPi-image-utils/image-backup"
NAS_MOUNT="/mnt/nas_Raspi-Backups"
INCREMENTAL_IMG="${NAS_MOUNT}/$(hostname)_imagebackup.img"
LOG="${NAS_MOUNT}/pi-image-backup.log"          #TODO Check if that works
LOCK="/var/lock/pi-image-backup.lock"

# Free space added back AFTER shrinking - image-backup shrinks the fs to its minimum, then grows it again by this amount, so it stays in the final image.
INCREMENTAL_RESERVE_MB=30720    # 30 GB - persistent image, needs long-term growth room
BACKUP_IMG_RESERVE_MB=2048      # 2 GB - one-off dated snapshot, no future growth needed, but we still want some space to work with it if we need it, so that we're still able to
                                # install some needed packages for resizing etc.
# -------------------------------------------

usage() {
    cat <<EOF
Usage: $(basename "$0") [--incremental|--backup-img]

  --incremental   (default) Create/update the persistent image at:
                  ${INCREMENTAL_IMG}
                  First run = full backup, shrunk + ${INCREMENTAL_RESERVE_MB} MB reserve.
                  Later runs = true incremental update, no reserve needed.

  --backup-img    Create a new standalone full backup image named
                  backup-raspi-YYYY-MM-DD.img in ${NAS_MOUNT},
                  shrunk + ${BACKUP_IMG_RESERVE_MB} MB reserve.
EOF
    exit 1
}

log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

do_full_backup() {
    # $1 = target image path, $2 = post-shrink reserve in MB (see settings above)
    local img="$1" reserve_mb="$2"
    local used_mb init_mb
    used_mb=$(df -m --output=used / | tail -1 | tr -d ' ')
    # Temporary size for the initial copy only; shrunk away afterwards.
    init_mb=$((used_mb + 512))
    log "No existing image at ${img} - starting full backup (initial ${init_mb} MB, then shrink + ${reserve_mb} MB reserve)"
    "$IMAGE_BACKUP" -i "${img},${init_mb},${reserve_mb}" >>"$LOG" 2>&1
}

[ "$(id -u)" -eq 0 ] || { echo "Please run as root." >&2; exit 1; }
[ -x "$IMAGE_BACKUP" ] || { log "ERROR: ${IMAGE_BACKUP} not found or not executable"; exit 1; }

MODE="incremental"
case "${1:-}" in
    --incremental) MODE="incremental" ;;
    --backup-img)  MODE="backup-img" ;;
    "") : ;;
    -h|--help) usage ;;
    *) usage ;;
esac

# Only one run at a time
exec 9>"$LOCK"
flock -n 9 || { log "Backup already running - aborting."; exit 1; }

# NAS must be mounted, otherwise we'd write to the SD card itself
if ! mountpoint -q "$NAS_MOUNT"; then
    log "NAS not mounted, attempting mount ..."
    mount "$NAS_MOUNT" >>"$LOG" 2>&1
    if ! mountpoint -q "$NAS_MOUNT"; then
        log "ERROR: could not mount ${NAS_MOUNT} - aborting."
        exit 1
    fi
fi

if [ "$MODE" = "incremental" ]; then

    #we're checking if a incremental backup file already exists.
    if [ -f "$INCREMENTAL_IMG" ]; then
        # File exists -> incremental update only, no new reserve added.
        log "Starting incremental backup: ${INCREMENTAL_IMG}"
        "$IMAGE_BACKUP" "$INCREMENTAL_IMG" >>"$LOG" 2>&1
    else
        # File missing -> first run, full backup with the 30 GB reserve.
        do_full_backup "$INCREMENTAL_IMG" "$INCREMENTAL_RESERVE_MB"
    fi
else
    DATED_IMG="${NAS_MOUNT}/backup-raspi-$(date '+%Y-%m-%d').img"
    do_full_backup "$DATED_IMG" "$BACKUP_IMG_RESERVE_MB"
fi
RC=$?

if [ $RC -eq 0 ]; then
    log "Backup completed successfully (mode: ${MODE})."
else
    log "ERROR: image-backup exited with code ${RC} (mode: ${MODE}; see ${LOG} for details)"
fi
exit $RC