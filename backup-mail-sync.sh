#!/bin/sh
# imapsync-mail-sync.sh
#
# After a reboot, copies mails that arrived on the backup mail server while the
# host mail server was down into the mailboxes of the host mail server (imapsync).
#
# - Nothing is ever deleted. imapsync skips mails that already exist on the host server.
# - Notification mails are sent with curl through an external SMTP server, so they
#   go out even if the host mail server never comes up.
#
# Requirements: imapsync, curl, nc (BusyBox is fine)
# Permissions:  chmod 700 (this file contains passwords)

# ------------------------- Configuration -------------------------
# Backup mail server (source, IMAP over SSL, port 993)
BACKUP_SERVER="imap.backup-server.example"

# Host mail server (destination, IMAP over SSL)
HOST_SERVER="127.0.0.1"
HOST_PORT=993

# Notification mails (sent via curl, independent of the host mail server)
SMTP_URL="smtps://smtp.backup-server.example:465"   # or smtp://...:587 for STARTTLS
MAIL_FROM="sender@example.com"                      # also used as SMTP login
MAIL_PASSWORD="CHANGE_ME"
MAIL_TO="recipient1@example.com recipient2@example.com"   # one or more, separated by spaces or commas

# One mailbox per line: login;backup-server-password;host-server-password
# The host-server password can be omitted if it is identical.
# Passwords must not contain a single quote; the backup-server password also no ';'.
ACCOUNTS='
user1@example.com;BACKUP_PW;HOST_PW
user2@example.com;BACKUP_PW;HOST_PW
'

# Seconds to wait after boot before doing anything (gives the network time to come up)
STARTUP_DELAY=120

LOG_DIR="/var/log/imapsync"
# -----------------------------------------------------------------

mkdir -p "$LOG_DIR"
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

# send_mail SUBJECT BODY
# Sends to every address in MAIL_TO. Retries for up to ~2 minutes, because the
# network may not be up yet right after boot.
send_mail() {
    subject="$1"
    body="$2"

    # Recipients may be separated by spaces and/or commas
    recipients=$(printf '%s' "$MAIL_TO" | tr ',' ' ')
    to_header=$(echo $recipients | sed 's/ /, /g')

    # Build one --mail-rcpt option per recipient (uses the function's own $@)
    set --
    for rcpt in $recipients; do
        set -- "$@" --mail-rcpt "$rcpt"
    done

    {
        echo "From: $MAIL_FROM"
        echo "To: $to_header"
        echo "Subject: $subject"
        echo "Date: $(date -R)"
        echo "Message-ID: <$(date +%s).$$@$(hostname)>"
        echo "MIME-Version: 1.0"
        echo "Content-Type: text/plain; charset=UTF-8"
        echo
        printf '%s\n' "$body"
    } | awk '{ printf "%s\r\n", $0 }' > "$TMP/mail.txt"

    attempt=1
    while [ "$attempt" -le 12 ]; do
        # --mail-rcpt-allowfails: one rejected address does not block the others
        if curl -sS --ssl-reqd --url "$SMTP_URL" \
                --user "$MAIL_FROM:$MAIL_PASSWORD" \
                --mail-from "$MAIL_FROM" --mail-rcpt-allowfails "$@" \
                -T "$TMP/mail.txt" >> "$LOG_DIR/mail.log" 2>&1; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 10
    done
    echo "$(date '+%F %T') Could not send mail: $subject" >> "$LOG_DIR/mail.log"
    return 1
}

# Initial delay after boot
sleep "$STARTUP_DELAY"

account_list=$(printf '%s\n' "$ACCOUNTS" | cut -d';' -f1 | sed '/^$/d;/^#/d')

# Start notification (does not depend on the host mail server)
send_mail "trying to sync mails from backup mail server to host mail server after reboot" \
"Reboot detected, waiting for the host mail server (started at $(date '+%F %T')).

Accounts:
$account_list"

# Wait for the host mail server (max. 5 minutes)
waited=0
until echo | nc -w 3 "$HOST_SERVER" "$HOST_PORT" >/dev/null 2>&1; do
    if [ "$waited" -ge 300 ]; then
        send_mail "host mail server not reachable - sync aborted" \
"The host mail server ($HOST_SERVER:$HOST_PORT) did not come up within 5 minutes after boot.
Nothing was synced. Checked at $(date '+%F %T')."
        exit 1
    fi
    sleep 5
    waited=$((waited + 5))
done
sleep 5   # give the server a moment to finish starting

total_ok=0
total_err=0
report=""

while IFS=';' read -r user pw1 pw2; do
    [ -z "$user" ] && continue
    case "$user" in \#*) continue ;; esac
    [ -z "$pw2" ] && pw2="$pw1"

    out="$LOG_DIR/$user.log"

    # </dev/null is required, otherwise imapsync would consume the account list.
    # Certificate verification on the host server is off because it is usually
    # reached via 127.0.0.1, which would not match the certificate name.
    imapsync \
        --host1 "$BACKUP_SERVER" --ssl1 --user1 "$user" --password1 "$pw1" \
        --host2 "$HOST_SERVER" --port2 "$HOST_PORT" --ssl2 --sslargs2 SSL_verify_mode=0 \
        --user2 "$user" --password2 "$pw2" \
        --automap --addheader --nofoldersizes --nofoldersizesatend --nolog \
        </dev/null > "$out" 2>&1

    # Newly transferred mails
    ok=$(sed -n 's/^Messages transferred *: *\([0-9][0-9]*\).*/\1/p' "$out" | tail -1)
    ok=${ok:-0}

    # Mails that really failed (could not be fetched from the backup server or
    # could not be stored on the host server). Skipped/already existing mails
    # are NOT counted.
    bad=$(grep -c -E '^- msg .*(could not be fetched|could not append)' "$out")

    # Total number of errors imapsync detected (login, connection, folders, ...)
    det=$(sed -n 's/^Detected \([0-9][0-9]*\) errors.*/\1/p' "$out" | tail -1)

    total_ok=$((total_ok + ok))
    total_err=$((total_err + bad))

    line="$user: $ok synced, $bad failed"
    if [ -z "$det" ]; then
        line="$line  [imapsync did not finish - see $out]"
    elif [ $((det - bad)) -gt 0 ]; then
        line="$line  [+$((det - bad)) other errors, e.g. login/connection/folder - see $out]"
    fi
    grep -q 'Maximum number of errors' "$out" && line="$line  [aborted: too many errors]"
    report="$report
$line"
done <<EOF
$ACCOUNTS
EOF

send_mail "$total_ok mails successfully synced / $total_err mails not synced (errors)" \
"Sync finished at $(date '+%F %T').
$report"