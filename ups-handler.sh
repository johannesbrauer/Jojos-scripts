#!/bin/bash
# ups-handler.sh - NUT event handler: sends mails and shuts down the host
# Usage: ups-handler.sh {onbatt|online|shutdown|lowbatt}   (DRY_RUN=1 = no real shutdown)

SMTP_URL="smtp://smtp.example.com:587"    # implicit TLS: smtps://host:465
SMTP_USER="ups@example.com"
SMTP_PASS="change-me"
MAIL_FROM="ups@example.com"
MAIL_TO=("admin1@example.com" "admin2@example.com")
UPS="myups@localhost"

HOST=$(hostname)

info() { echo "UPS status: $(timeout 5 upsc $UPS ups.status 2>&1), battery: $(timeout 5 upsc $UPS battery.charge 2>&1) %"; }

mail_send() {   # $1 = subject, $2 = body
  local rcpt=() r
  for r in "${MAIL_TO[@]}"; do rcpt+=(--mail-rcpt "$r"); done
  printf 'From: %s\nTo: %s\nSubject: [%s] %s\nDate: %s\n\n%s\n' \
      "$MAIL_FROM" "$(IFS=,; echo "${MAIL_TO[*]}")" "$HOST" "$1" "$(date -R)" "$2" \
    | sed 's/$/\r/' \
    | curl -sS --ssl-reqd --connect-timeout 10 --max-time 30 --url "$SMTP_URL" \
        --user "$SMTP_USER:$SMTP_PASS" --mail-from "$MAIL_FROM" "${rcpt[@]}" --upload-file - \
    && logger -t ups-handler "mail sent: $1" || logger -t ups-handler "mail FAILED: $1"
}

do_shutdown() {   # $1 = mail text
  exec 9>/run/ups-handler.lock; flock -n 9 || exit 0    # run only once
  mail_send "UPS: shutting down" "$1"$'\n\n'"$(info)"
  [ -z "$DRY_RUN" ] && /sbin/shutdown -h +0 "UPS: power failure"
}

case "$1" in
  onbatt)   mail_send "UPS: power failure" "Power failed, running on battery. Shutdown in 5 minutes if power does not return."$'\n\n'"$(info)" ;;
  online)   mail_send "UPS: power restored" "Power is back."$'\n\n'"$(info)" ;;
  shutdown) do_shutdown "power failed for over 5 minutes now. Now performing shutdown of host $HOST ..." ;;
  lowbatt)  do_shutdown "UPS battery is low. Now performing shutdown of host $HOST ..." ;;
  *)        echo "Usage: $0 {onbatt|online|shutdown|lowbatt}" >&2; exit 1 ;;
esac