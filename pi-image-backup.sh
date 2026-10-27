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
LOG="${NAS_MOUNT}/pi-image-backup.log"       
LOCK="/var/lock/pi-image-backup.lock"

# Free space added back AFTER shrinking - image-backup shrinks the fs to its minimum, then grows it again by this amount, so it stays in the final image.
INCREMENTAL_RESERVE_MB=30720    # 30 GB - persistent image, needs long-term growth room
BACKUP_IMG_RESERVE_MB=2048      # 2 GB - one-off dated snapshot, no future growth needed, but we still want some space to work with it if we need it, so that we're still able to
                                # install some needed packages for resizing etc.
SNAP_EXCLUDE="--exclude=/snap/*"
SNAP_INCREMENTAL_OPTS="--exclude=/snap/*,--delete-excluded,--delete-before"
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

cleanup_image_mount() {
    local mnt="/tmp/img-backup-mnt" src loop
    local -a loops=()
    mountpoint -q "$mnt" || return 0
    log "Cleaning stale image mount at ${mnt}"
    findmnt -R "$mnt" -o TARGET,SOURCE,FSTYPE >>"$LOG" 2>&1 || true
    while read -r src; do
        case "$src" in
            /dev/loop*p[0-9]*) loops+=("${src%p[0-9]*}") ;;
            /dev/loop*) loops+=("$src") ;;
        esac
    done < <(findmnt -n -R "$mnt" -o SOURCE)
    umount -R "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
    for loop in "${loops[@]}"; do
        losetup -d "$loop" 2>/dev/null || true
    done
    log "NAS after stale-mount cleanup: $(df -h "$NAS_MOUNT" | tail -1)"
}

log_start_context() {
    local reserve_desc img_meta
    if [ "$BACKUP_TYPE" = "full" ]; then
        reserve_desc="${RESERVE_MB} MB"
    else
        reserve_desc="n/a"
    fi
    img_meta=$(stat -c '%y %s bytes' "$IMAGE_BACKUP" 2>/dev/null || true)
    log "Backup type: ${BACKUP_TYPE}; image: ${CURRENT_IMG}; reserve: ${reserve_desc}"
    log "Source root: $(df -h / | tail -1)"
    log "Source inodes: $(df -i / | tail -1)"
    log "NAS: $(df -h "$NAS_MOUNT" | tail -1)"
    log "NAS inodes: $(df -i "$NAS_MOUNT" | tail -1)"
    log "image-backup: ${img_meta}"
    log "image-backup sizing: $(grep -m1 'INISIZE=' "$IMAGE_BACKUP" 2>/dev/null || true)"
    log "Mounted filesystems under /:"
    findmnt -R / -o TARGET,SOURCE,FSTYPE,SIZE,USED,AVAIL >>"$LOG" 2>&1 || true
    log "Snap mount view excluded: /snap/* (actual snap packages remain in /var/lib/snapd/snaps)"
    log "Snap mount view size (allocated / apparent):"
    du -sh /snap >>"$LOG" 2>&1 || true
    du -sh --apparent-size /snap >>"$LOG" 2>&1 || true
    log "Jellyfin backups and journal size:"
    du -sh /var/backups/jellyfin-updater /var/log/journal >>"$LOG" 2>&1 || true
}

log_failure_context() {
    log "Failure diagnostics:"
    log "Source root after failure: $(df -h / | tail -1)"
    log "Source inodes after failure: $(df -i / | tail -1)"
    log "NAS after failure: $(df -h "$NAS_MOUNT" | tail -1)"
    log "NAS inodes after failure: $(df -i "$NAS_MOUNT" | tail -1)"
    if [ -n "${CURRENT_IMG}" ] && [ -e "${CURRENT_IMG}" ]; then
        log "Image file after failure:"
        ls -lh "$CURRENT_IMG" >>"$LOG" 2>&1
        du -h "$CURRENT_IMG" >>"$LOG" 2>&1
        du -h --apparent-size "$CURRENT_IMG" >>"$LOG" 2>&1
    else
        log "Image file does not exist after failure: ${CURRENT_IMG:-<unset>}"
    fi
    log "Top-level source usage (root filesystem):"
    du -x -h -d1 / 2>/dev/null | sort -h | tail -n 20 >>"$LOG" 2>&1
    log "Root filesystem allocated / apparent:"
    du -x -s -h / >>"$LOG" 2>&1
    du -x -s -h --apparent-size / >>"$LOG" 2>&1
    log "Jellyfin backups and journal size after failure:"
    du -sh /var/backups/jellyfin-updater /var/log/journal >>"$LOG" 2>&1 || true
    log "Elapsed: $(( $(date +%s) - START_EPOCH ))s"
}

log_success_context() {
    local allocated apparent
    allocated=$(du -h "$CURRENT_IMG" 2>/dev/null | cut -f1)
    apparent=$(du -h --apparent-size "$CURRENT_IMG" 2>/dev/null | cut -f1)
    log "Image: ${CURRENT_IMG}; allocated: ${allocated}; apparent: ${apparent}"
    log "NAS after success: $(df -h "$NAS_MOUNT" | tail -1)"
    log "Elapsed: $(( $(date +%s) - START_EPOCH ))s"
}

do_full_backup() {
    # $1 = target image path, $2 = post-shrink reserve in MB (see settings above)
    local img="$1" reserve_mb="$2"
    log "Starting full backup to ${img} (image-backup computes the initial size, excludes /snap/*, then shrink + ${reserve_mb} MB reserve)"
    "$IMAGE_BACKUP" -i "${img},,${reserve_mb}" -o "$SNAP_EXCLUDE" >>"$LOG" 2>&1
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

if [ -n "$(pidof -x image-backup 2>/dev/null || true)" ]; then
    log "ERROR: image-backup is already running - aborting."
    exit 1
fi
cleanup_image_mount

BACKUP_TYPE=""
CURRENT_IMG=""
RESERVE_MB=""

if [ "$MODE" = "incremental" ]; then
    CURRENT_IMG="$INCREMENTAL_IMG"
    if [ -f "$INCREMENTAL_IMG" ]; then
        BACKUP_TYPE="incremental"
    else
        BACKUP_TYPE="full"
        RESERVE_MB="$INCREMENTAL_RESERVE_MB"
    fi
else
    BACKUP_TYPE="full"
    CURRENT_IMG="${NAS_MOUNT}/backup-raspi-$(date '+%Y-%m-%d').img"
    RESERVE_MB="$BACKUP_IMG_RESERVE_MB"
fi

START_EPOCH=$(date +%s)
log_start_context

if [ "$BACKUP_TYPE" = "incremental" ]; then
    log "Starting incremental backup: ${CURRENT_IMG} (excluding /snap/*; freeing excluded data first)"
    "$IMAGE_BACKUP" "$CURRENT_IMG" -o "$SNAP_INCREMENTAL_OPTS" >>"$LOG" 2>&1
else
    do_full_backup "$CURRENT_IMG" "$RESERVE_MB"
fi
RC=$?
cleanup_image_mount

if [ $RC -eq 0 ]; then
    log "Backup completed successfully (backup type: ${BACKUP_TYPE}; mode: ${MODE})."
    log_success_context
else
    log_failure_context
    log "ERROR: image-backup exited with code ${RC} (backup type: ${BACKUP_TYPE}; mode: ${MODE}; see ${LOG} for details)"
fi
exit $RC