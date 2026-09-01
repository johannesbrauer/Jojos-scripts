#!/bin/sh

# ==============================================================================
# PocketBase - Auto-Updater for Alpine Linux (diskless/RAM + OpenRC)
#
# Companion script to install-pocketbase.sh.
# Checks GitHub for a newer release than the one currently installed and,
# if found, safely swaps the binary and restarts the OpenRC service, with
# automatic rollback if the new binary fails to come up cleanly.
# Since this host is diskless, a successful update also runs "lbu include"
# on all relevant paths and "lbu commit" automatically - otherwise the new
# binary would be gone again on the next reboot.
#
# E-mail policy (all via external SMTP relay, curl, no extra MTA needed):
#   - ANY fatal error (die()) sends a mail with the full log attached - this
#     includes early failures like "GitHub API unreachable/changed", so the
#     server never silently stops receiving updates for months unnoticed.
#   - A new MAJOR version is never auto-applied; a mail is sent instead, asking
#     for a manual upgrade after reading the changelog. (PocketBase has so far
#     stayed forward-compatible across minor/patch releases, so those ARE
#     auto-applied - only a hypothetical first v1.0.0+ major bump is gated.)
#   - Normal minor/patch updates: one mail when an update is about to be
#     attempted, one on success, one on failure (with rollback + log attached).
#
# Usage:
#   pocketbase-updater-alpine.sh                 run an update check/apply now
#   pocketbase-updater-alpine.sh --install-cron  register a daily 00:00 cron job
#   pocketbase-updater-alpine.sh --check-only    only report whether an update exists (no mail)
#   pocketbase-updater-alpine.sh --test-mail     send a test e-mail and exit
# ==============================================================================

set -eu

# ==============================================================================
# 1) CONFIGURATION - EDIT THESE
# The script always runs as root via cron, so credentials live here, so keep this file secure.
# Restrict this file's permissions: chmod 700.
# ==============================================================================

# --- SMTP / notification settings ---
SMTP_HOST="smtp.example.com"
SMTP_PORT="587"
SMTP_USER="updater@example.com"
SMTP_PASS="CHANGE_ME"
SMTP_FROM="updater@example.com"
SMTP_USE_TLS="starttls"                              # starttls | ssl | none
MAIL_RECIPIENTS="admin@example.com ops@example.com"  # space-separated, any count

# --- Installation-specific paths (must match the installer) ---
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
BIN_DIR="/opt/pocketbase"
BIN="${BIN_DIR}/pocketbase"
BIN_BACKUP="${BIN_DIR}/pocketbase.prev"
DATA_DIR="/var/lib/pocketbase/pb_data"
LOG_DIR="/var/log/pocketbase"
INIT_FILE="/etc/init.d/pocketbase"
CONF_FILE="/etc/conf.d/pocketbase"
SERVICE="pocketbase"
LOG_FILE="${LOG_DIR}/updater.log"
LOCK_DIR="/run/pocketbase-updater.lock"
GITHUB_API="https://api.github.com/repos/pocketbase/pocketbase/releases/latest"
CRON_FILE="/etc/crontabs/root"
CRON_LINE="0 0 * * * ${SCRIPT_PATH} >> ${LOG_FILE} 2>&1"
STARTUP_WAIT_SECONDS=60

# Bind address/port come from the installer's conf.d file, so the healthcheck
# always hits the same address PocketBase actually listens on.
# shellcheck disable=SC1090
[ -f "$CONF_FILE" ] && . "$CONF_FILE"
HC_HOST="${pocketbase_bind:-127.0.0.1}"
[ "$HC_HOST" = "0.0.0.0" ] && HC_HOST="127.0.0.1"
HEALTHCHECK_URL="http://${HC_HOST}:${pocketbase_port:-8090}/api/health"

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
HOST_LABEL="$(hostname -f 2>/dev/null || hostname)"

# ==============================================================================
# 2) FUNCTIONS
# ==============================================================================

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" | tee -a "$LOG_FILE" >/dev/null
}

# send_mail "Subject" "Body text" ["/path/to/attachment.txt"]
send_mail() {
    subject="$1" body="$2" attachment="${3:-}"
    [ -n "$MAIL_RECIPIENTS" ] || return 0

    case "$SMTP_USE_TLS" in
        ssl)  scheme="smtps"; tls_opt="" ;;
        none) scheme="smtp";  tls_opt="" ;;
        *)    scheme="smtp";  tls_opt="--ssl-reqd" ;;
    esac

    to_header="$(printf '%s' "$MAIL_RECIPIENTS" | tr ' ' ',')"
    tmp_mail="$(mktemp)"

    {
        printf 'From: %s\nTo: %s\nSubject: %s\nDate: %s\nMIME-Version: 1.0\n' \
            "$SMTP_FROM" "$to_header" "$subject" "$(date -R 2>/dev/null || date)"

        if [ -n "$attachment" ] && [ -f "$attachment" ]; then
            boundary="pocketbase-updater-$$"
            printf 'Content-Type: multipart/mixed; boundary="%s"\n\n--%s\n' "$boundary" "$boundary"
            printf 'Content-Type: text/plain; charset=utf-8\n\n%s\n\n--%s\n' "$body" "$boundary"
            printf 'Content-Type: text/plain; name="%s"\nContent-Disposition: attachment; filename="%s"\nContent-Transfer-Encoding: base64\n\n' \
                "$(basename "$attachment")" "$(basename "$attachment")"
            base64 "$attachment"
            printf '\n--%s--\n' "$boundary"
        else
            printf 'Content-Type: text/plain; charset=utf-8\n\n%s\n' "$body"
        fi
    } > "$tmp_mail"

    set -- --mail-from "$SMTP_FROM"
    for rcpt in $MAIL_RECIPIENTS; do set -- "$@" --mail-rcpt "$rcpt"; done

    if curl -sS --url "${scheme}://${SMTP_HOST}:${SMTP_PORT}" ${tls_opt:+$tls_opt} \
            --user "${SMTP_USER}:${SMTP_PASS}" "$@" --upload-file "$tmp_mail" \
            >/dev/null 2>>"$LOG_FILE"; then
        log "Notification e-mail sent: $subject"
    else
        log "WARNING: failed to send notification e-mail ('$subject')."
    fi
    rm -f "$tmp_mail"
}

# notify_failure "reason" - logs, mails the failure with the log file attached.
# Used by EVERY fatal exit path (die() and fail_update()) so a broken GitHub
# API, a missing binary, an unsupported arch etc. can never fail silently.
notify_failure() {
    reason="$1"
    log "ERROR: $reason"
    send_mail "PocketBase updater: ERROR - ${reason}" \
"Host: ${HOST_LABEL}

The PocketBase auto-updater failed:
${reason}

This needs attention - if left unresolved (e.g. GitHub changed their API or
release layout), this server will keep failing to update indefinitely
without any further warning until this is fixed.

Full log file on the server: ${LOG_FILE}
(also attached to this e-mail)" \
        "$LOG_FILE"
}

# die "reason" - fatal error before/without an update attempt in progress.
die() {
    notify_failure "$1"
    exit 1
}

# fail_update "reason" - fatal error DURING an update attempt: rolls back to
# the previous binary, restarts the service, then mails via notify_failure.
fail_update() {
    reason="$1"
    log "Restoring previous binary and restarting $SERVICE..."
    rc-service "$SERVICE" stop >/dev/null 2>&1 || true
    if [ -f "$BIN_BACKUP" ]; then
        cp -f "$BIN_BACKUP" "$BIN"
        chmod 755 "$BIN"
    fi
    rc-service "$SERVICE" start >/dev/null 2>&1 || true
    notify_failure "${reason} (previous version ${CURRENT_VERSION} restored and service restarted)"
    exit 1
}

# ver_num "X.Y.Z" -> zero-padded numeric string, for safe integer comparison.
ver_num() { printf '%s' "$1" | awk -F. '{ printf("%05d%05d%05d\n", $1+0, $2+0, $3+0) }'; }

# major_num "X.Y.Z" -> the major version number only, for deciding whether
# an update is minor/patch-level (safe to auto-apply) or a major bump
# (potentially breaking -> manual upgrade only).
major_num() { printf '%s' "$1" | awk -F. '{ printf("%d\n", $1+0) }'; }

# lbu_persist - include all relevant paths and commit. Diskless-specific:
# without this, everything the updater (or --install-cron) just wrote is
# lost on the next reboot. Logs the outcome, never aborts the script.
lbu_persist() {
    for p in "$BIN_DIR" "$DATA_DIR" "$LOG_DIR" "$INIT_FILE" "$CONF_FILE" \
             "$SCRIPT_PATH" "$CRON_FILE"; do
        lbu include "$p" 2>/dev/null || true
    done
    if lbu commit >/dev/null 2>&1; then
        log "lbu commit completed - changes persisted."
        LBU_STATUS="committed"
    else
        log "WARNING: lbu commit failed - changes are NOT persisted yet."
        LBU_STATUS="FAILED (run 'lbu commit' manually)"
    fi
}

# ==============================================================================
# 3) PREREQUISITES
# ==============================================================================

[ "$(id -u)" -eq 0 ] || die "This script must be run as root."

for pkg_cmd in "jq:jq" "curl:curl" "unzip:unzip" "base64:coreutils"; do
    cmd="${pkg_cmd%%:*}"; pkg="${pkg_cmd##*:}"
    command -v "$cmd" >/dev/null 2>&1 || apk add --no-cache "$pkg" >/dev/null \
        || die "Failed to install required package '$pkg' (command '$cmd')."
done

# ==============================================================================
# 4) ONE-OFF MODES
# ==============================================================================

if [ "${1:-}" = "--test-mail" ]; then
    send_mail "PocketBase updater - test e-mail" \
"This is a test e-mail from the PocketBase auto-updater on host ${HOST_LABEL}.
If you received this, the SMTP settings at the top of the script are correct."
    echo "Test e-mail dispatched (check the recipient inbox and $LOG_FILE)."
    exit 0
fi

if [ "${1:-}" = "--install-cron" ]; then
    mkdir -p "$(dirname "$CRON_FILE")"
    touch "$CRON_FILE"
    if grep -Fq "pocketbase-updater-alpine.sh" "$CRON_FILE" 2>/dev/null; then
        echo "Cron entry already present in $CRON_FILE, leaving it as is."
    else
        echo "$CRON_LINE" >> "$CRON_FILE"
        echo "Cron entry added to $CRON_FILE:"
        echo "  $CRON_LINE"
    fi
    rc-update add crond default >/dev/null 2>&1 || true
    rc-service crond start >/dev/null 2>&1 || rc-service crond restart >/dev/null 2>&1 || true
    echo "crond is enabled and (re)started. The updater will run daily at 00:00."

    # Diskless: this script and the cron entry must survive a reboot too.
    lbu_persist
    echo "lbu status: ${LBU_STATUS}"
    exit 0
fi

# ==============================================================================
# 5) MAIN
# ==============================================================================

mkdir "$LOCK_DIR" 2>/dev/null || die "Another instance appears to be running (lock: $LOCK_DIR)."
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM

log "=== PocketBase update check started ==="
[ -x "$BIN" ] || die "PocketBase binary not found at $BIN. Is it installed via the installer script?"

case "$(uname -m)" in
    x86_64|amd64)      PB_ARCH="amd64" ;;
    aarch64|arm64)     PB_ARCH="arm64" ;;
    armv7l|armv6l|arm) PB_ARCH="armv7" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
esac

CURRENT_VERSION="$("$BIN" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
[ -n "$CURRENT_VERSION" ] || die "Could not determine the currently installed version."
log "Currently installed version: $CURRENT_VERSION"

RELEASE_JSON="$(curl -fsSL -H 'Accept: application/vnd.github+json' -H 'User-Agent: pocketbase-alpine-updater' "$GITHUB_API")" \
    || die "Failed to query GitHub API ($GITHUB_API) - it may be down or its format may have changed."

LATEST_TAG="$(printf '%s' "$RELEASE_JSON" | jq -r '.tag_name' 2>/dev/null || true)"
[ -n "$LATEST_TAG" ] && [ "$LATEST_TAG" != "null" ] \
    || die "Could not read tag_name from GitHub API response - the API format may have changed."
LATEST_VERSION="${LATEST_TAG#v}"

ASSET_NAME="pocketbase_${LATEST_VERSION}_linux_${PB_ARCH}.zip"
DOWNLOAD_URL="$(printf '%s' "$RELEASE_JSON" | jq -r --arg n "$ASSET_NAME" '.assets[] | select(.name==$n) | .browser_download_url')"
[ -n "$DOWNLOAD_URL" ] && [ "$DOWNLOAD_URL" != "null" ] \
    || die "Release $LATEST_TAG has no asset named $ASSET_NAME - the release asset naming may have changed."
log "Latest available version:   $LATEST_VERSION"

if [ "$(ver_num "$LATEST_VERSION")" -le "$(ver_num "$CURRENT_VERSION")" ]; then
    log "Already up to date (no action taken)."
    exit 0
fi
log "Update available: $CURRENT_VERSION -> $LATEST_VERSION"

# Minor/patch updates are auto-applied - PocketBase has so far stayed
# forward-compatible across those. Only a MAJOR version bump is gated,
# since there has never been one yet and it could contain breaking changes.
IS_MAJOR_BUMP=0
[ "$(major_num "$LATEST_VERSION")" -gt "$(major_num "$CURRENT_VERSION")" ] && IS_MAJOR_BUMP=1

if [ "${1:-}" = "--check-only" ]; then
    echo "Update available: $CURRENT_VERSION -> $LATEST_VERSION"
    [ "$IS_MAJOR_BUMP" -eq 1 ] && echo "(major version bump - would NOT be auto-applied)"
    exit 0
fi

# --- Major version bump: never auto-update, just alert -----------------------
if [ "$IS_MAJOR_BUMP" -eq 1 ]; then
    log "New major version detected ($CURRENT_VERSION -> $LATEST_VERSION). Skipping auto-update."
    send_mail "PocketBase: NEW MAJOR VERSION available (${CURRENT_VERSION} -> ${LATEST_VERSION})" \
"Host: ${HOST_LABEL}

New major version available: PocketBase ${LATEST_VERSION} (currently installed: ${CURRENT_VERSION}).

Auto updating to a new major version is not intended, since it could contain
breaking changes (e.g. pb_data migrations). This is the first major bump
PocketBase has ever had, so please read the changelog carefully, then
upgrade manually:
  https://github.com/pocketbase/pocketbase/releases

Minor and patch updates (same major version) are applied automatically by
this script."
    exit 0
fi

send_mail "PocketBase: trying to auto-update ${CURRENT_VERSION} -> ${LATEST_VERSION}" \
"Host: ${HOST_LABEL}

Trying to auto update PocketBase ${CURRENT_VERSION} to PocketBase ${LATEST_VERSION}.
You will receive a follow-up e-mail once the update succeeds or fails."

# --- Download, verify, install --------------------------------------------------
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"; rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM

log "Downloading $DOWNLOAD_URL ..."
curl -fsSL "$DOWNLOAD_URL" -o "$TMP_DIR/pocketbase.zip" || fail_update "Download of $DOWNLOAD_URL failed."
unzip -q "$TMP_DIR/pocketbase.zip" -d "$TMP_DIR"        || fail_update "Failed to extract downloaded archive."
[ -f "$TMP_DIR/pocketbase" ] || fail_update "Downloaded archive did not contain a 'pocketbase' binary."
chmod 755 "$TMP_DIR/pocketbase"

NEW_VERSION_RAW="$("$TMP_DIR/pocketbase" --version 2>&1 || true)"
echo "$NEW_VERSION_RAW" | grep -qE "$LATEST_VERSION" \
    || fail_update "Downloaded binary failed sanity check (--version reported: $NEW_VERSION_RAW)."

log "Stopping $SERVICE service..."
rc-service "$SERVICE" stop >/dev/null 2>&1 || log "WARNING: service was not running before update."

log "Backing up current binary to $BIN_BACKUP"
cp -f "$BIN" "$BIN_BACKUP"

log "Installing new binary ($LATEST_VERSION)..."
mv "$TMP_DIR/pocketbase" "$BIN"
chmod 755 "$BIN"
chown pocketbase:pocketbase "$BIN" 2>/dev/null || true

log "Starting $SERVICE service..."
rc-service "$SERVICE" start >/dev/null 2>&1 || true

# --- Health check: verify the update actually came up, else roll back --------
i=0; UP_OK=0
while [ "$i" -lt "$STARTUP_WAIT_SECONDS" ]; do
    if rc-service "$SERVICE" status 2>/dev/null | grep -q started \
        && curl -fsS -o /dev/null "$HEALTHCHECK_URL" 2>/dev/null; then
        UP_OK=1; break
    fi
    sleep 1; i=$((i + 1))
done

if [ "$UP_OK" -eq 1 ]; then
    log "Update successful: $CURRENT_VERSION -> $LATEST_VERSION. Service is up."

    # Diskless: persist the new binary now, or it's gone on the next reboot.
    lbu_persist

    send_mail "PocketBase: successfully auto-updated ${CURRENT_VERSION} -> ${LATEST_VERSION}" \
"Host: ${HOST_LABEL}

Successfully auto updated PocketBase from ${CURRENT_VERSION} to ${LATEST_VERSION}.
The service is up and responding.

lbu persistence: ${LBU_STATUS}"
else
    fail_update "Service did not come up cleanly after update (status/health check failed within ${STARTUP_WAIT_SECONDS}s)."
fi

log "=== PocketBase update check finished ==="