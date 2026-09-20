#!/bin/sh
#
# check_disk.sh - Checks disk usage and sends an email via curl (SMTP)
# whenever a threshold is exceeded.
#
# Tested with busybox ash (Alpine Linux).

set -eu

########################################################
# Threshold (in %) - edit here whenever needed          #
########################################################
THRESHOLD=80

### ---------- Further configuration ---------- ###

# Recipients, space-separated (any number allowed)
RECIPIENTS="admin1@example.com admin2@example.com"

# Sender address
FROM="alpine-vm@example.com"

# SMTP server. smtps:// = implicit TLS (usually port 465)
# For STARTTLS use e.g. "smtp://mail.example.com:587" instead
# and keep --ssl-reqd below.
SMTP_URL="smtps://mail.example.com:465"
SMTP_USER="smtp-user"
SMTP_PASS="smtp-password"

# Mountpoints to ignore (regex for grep -E)
IGNORE_PATTERN='^Filesystem|tmpfs|devtmpfs|overlay|/dev/loop|udev'

### ------------------------------------ ###

HOST=$(hostname)
TMPFILE=$(mktemp /tmp/disk_alert.XXXXXX)
trap 'rm -f "$TMPFILE"' EXIT

DF_OUTPUT=$(df -hP | grep -vE "$IGNORE_PATTERN")

ALERT=""
OLDIFS=$IFS
IFS='
'
for line in $DF_OUTPUT; do
    USE=$(printf '%s' "$line" | awk '{print $5}' | tr -d '%')
    MOUNT=$(printf '%s' "$line" | awk '{print $6}')
    FS=$(printf '%s' "$line" | awk '{print $1}')

    # only check if USE is a number
    case "$USE" in
        ''|*[!0-9]*) continue ;;
    esac

    if [ "$USE" -ge "$THRESHOLD" ]; then
        ALERT="${ALERT}${FS} on ${MOUNT}: ${USE}%
"
    fi
done
IFS=$OLDIFS

# Nothing to do if no mountpoint is above the threshold
[ -z "$ALERT" ] && exit 0

TO_HEADER=$(printf '%s' "$RECIPIENTS" | tr ' ' ',')
DATE_HDR=$(date -R 2>/dev/null || date)

{
    printf 'From: %s\r\n' "$FROM"
    printf 'To: %s\r\n' "$TO_HEADER"
    printf 'Subject: [%s] Warning: disk usage above %s%%\r\n' "$HOST" "$THRESHOLD"
    printf 'Date: %s\r\n' "$DATE_HDR"
    printf 'Content-Type: text/plain; charset=UTF-8\r\n'
    printf '\r\n'
    printf 'High disk usage was detected on %s:\r\n\r\n' "$HOST"
    printf '%s' "$ALERT" | sed 's/$/\r/'
} > "$TMPFILE"

# Build one --mail-rcpt argument per recipient
set --
for r in $RECIPIENTS; do
    set -- "$@" --mail-rcpt "$r"
done

curl --silent --show-error \
    --url "$SMTP_URL" \
    --ssl-reqd \
    --mail-from "$FROM" \
    "$@" \
    --upload-file "$TMPFILE" \
    --user "${SMTP_USER}:${SMTP_PASS}"