#!/bin/bash
# ups-handler.sh - NUT event handler: sends mails, triggers NUT shutdown sequence
# Usage: ups-handler.sh {onbatt|online|shutdown|halt}   (DRY_RUN=1: mail only, no shutdown)

SMTP_URL="smtp://smtp.example.com:587"    # implicit TLS: smtps://host:465
SMTP_USER="ups@example.com"
SMTP_PASS="change-me"
MAIL_FROM="ups@example.com"
MAIL_TO=("admin1@example.com" "admin2@example.com")
UPS="myups@localhost"

HOST=$(hostname)

status() { timeout 5 upsc "$UPS" ups.status 2>&1; }
info()   { echo "UPS status: $(status), battery: $(timeout 5 upsc "$UPS" battery.charge 2>&1) %"; }

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

case "$1" in
  onbatt)   mail_send "UPS: power failure" "Power failed, running on battery. Shutdown in 5 minutes if power does not return."$'\n\n'"$(info)" ;;
  online)   mail_send "UPS: power restored" "Power is back."$'\n\n'"$(info)" ;;
  shutdown) # timer expired (called by upssched): ask upsmon for a forced shutdown
            [ -n "$DRY_RUN" ] || /usr/sbin/upsmon -c fsd ;;
  halt)     # called by upsmon as SHUTDOWNCMD (timer case and low-battery case)
            exec 9>/run/ups-handler.lock; flock -n 9 || exit 0   # run only once
            case "$(status)" in
              *LB*) msg="UPS battery is low. Now performing shutdown of host $HOST ..." ;;
              *OB*) msg="power failed for over 5 minutes now. Now performing shutdown of host $HOST ..." ;;
              *)    msg="NUT requested a shutdown. Now performing shutdown of host $HOST ..." ;;
            esac
            mail_send "UPS: shutting down" "$msg"$'\n\n'"$(info)"
            [ -n "$DRY_RUN" ] || /sbin/shutdown -h +0 "UPS: power failure" ;;
  *)        echo "Usage: $0 {onbatt|online|shutdown|halt}" >&2; exit 1 ;;
esac