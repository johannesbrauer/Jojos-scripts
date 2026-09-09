#!/usr/bin/env bash
#
# jellyfin-updater.sh — Updater for the portable Jellyfin Linux build
# (the "generic amd64/arm64/armhf tar.gz" release from repo.jellyfin.org).
#
# Auto-detects the install path, data directory and CPU architecture (via
# the systemd service), creates a backup, updates to the latest stable
# version (version number via the GitHub API), health-checks the new
# service and automatically rolls back on failure.
#
# NOTE: this is meant for the manual "portable" tar.gz installation only.
# Jellyfin instances installed via apt/dnf are detected and rejected —
# use the respective package manager for those instead.
#
# Usage:
#   sudo ./jellyfin-updater.sh                          # one-off update
#   sudo ./jellyfin-updater.sh --install-cron ["CRON"]  # set up a cronjob
#   sudo ./jellyfin-updater.sh --help
#
set -uo pipefail

# ────────────────────────────── Configuration ──────────────────────────────
SERVICE_NAME="jellyfin"                     # name of the systemd service
DATA_DIR_OVERRIDE=""                        # empty = auto-detect from ExecStart
BACKUP_DIR="/var/backups/jellyfin-updater"
KEEP_BACKUPS=5
LOG_FILE="/var/log/jellyfin-updater.log"

HEALTH_PORT="8096"
HEALTH_URL_PATH="/System/Info/Public"       # unauthenticated endpoint
HEALTH_RETRIES=10
HEALTH_DELAY=3

# Email (leave MAIL_TO empty to disable emails)
MAIL_TO=""
MAIL_FROM="jellyfin-updater@$(hostname -f 2>/dev/null || hostname)"
SMTP_URL=""                                # e.g. smtp://mail.example.com:587 or smtps://mail.example.com:465
SMTP_USER=""
SMTP_PASS=""
# ────────────────────────────────────────────────────────────────────────────

SCRIPT_PATH="$(readlink -f "$0")"
TMP_DIR=""
ROLLBACK_READY=false

log() {
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') $*"
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
  echo "$line" | tee -a "$LOG_FILE"
}

cleanup() { [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

send_mail() {
  local subject="$1" body="$2"
  [ -z "$MAIL_TO" ] && return 0
  local boundary="jfupdater-$$" msg
  msg="$(mktemp)"
  {
    echo "From: $MAIL_FROM"
    echo "To: $MAIL_TO"
    echo "Subject: $subject"
    echo "MIME-Version: 1.0"
    echo "Content-Type: multipart/mixed; boundary=\"$boundary\""
    echo
    echo "--$boundary"
    echo "Content-Type: text/plain; charset=UTF-8"
    echo
    echo "$body"
    echo
    echo "Log file: $LOG_FILE"
    if [ -f "$LOG_FILE" ]; then
      echo "--$boundary"
      echo "Content-Type: text/plain; name=\"$(basename "$LOG_FILE")\""
      echo "Content-Transfer-Encoding: base64"
      echo "Content-Disposition: attachment; filename=\"$(basename "$LOG_FILE")\""
      echo
      base64 "$LOG_FILE"
    fi
    echo "--$boundary--"
  } >"$msg"
  local opts=(-s --url "$SMTP_URL" --mail-from "$MAIL_FROM" --mail-rcpt "$MAIL_TO" --upload-file "$msg")
  [[ "$SMTP_URL" == smtp://* ]] && opts+=(--ssl-reqd)
  [ -n "$SMTP_USER" ] && opts+=(--user "$SMTP_USER:$SMTP_PASS")
  curl "${opts[@]}" || log "WARNING: failed to send email"
  rm -f "$msg"
}

die() {
  log "ERROR: $*"
  if $ROLLBACK_READY; then
    rollback "$*"
  else
    send_mail "Failed to update to ver ${LATEST_VER:-?}, reason: $*" \
"Trying to update from ver ${CURRENT_VER:-?} to ver ${LATEST_VER:-?}
Failed to update to ver ${LATEST_VER:-?}, reason: $*"
  fi
  exit 1
}

require_root() { [ "$(id -u)" -eq 0 ] || { echo "Please run as root." >&2; exit 1; }; }

# ────────────────────────── Architecture & install ──────────────────────────
detect_arch() {
  case "$(uname -m)" in
    x86_64)        echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv6l) echo "armhf" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

# ExecStart line of the systemd service, with line continuations joined
unit_exec_line() {
  systemctl cat "$SERVICE_NAME" 2>/dev/null \
    | sed ':a;N;$!ba;s/\\\n[ \t]*/ /g' \
    | sed -n 's/^ExecStart=//p' | head -n1
}

# Determines the binary, install directory and data directory. Supports
# both an ExecStart pointing directly at the binary, and the official
# wrapper-script pattern (jellyfin.sh with -d/-C/-c/-l flags, see
# jellyfin.org/docs).
# We need a hell of Regex here, If that breaks I'm fucked :)
find_installation() {
  local exec_line target invocation
  exec_line="$(unit_exec_line)"
  [ -z "$exec_line" ] && die "Could not determine ExecStart of service '$SERVICE_NAME'"
  target="$(awk '{print $1}' <<<"$exec_line")"
  [ -f "$target" ] || die "ExecStart target '$target' does not exist"

  if file "$target" | grep -qi 'ELF'; then
    invocation="$exec_line"
  else
    # Wrapper script: load simple VAR=value assignments, then resolve the
    # line that actually invokes the jellyfin binary.
    local vars joined raw
    vars="$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=[^$`;&|]*$' "$target")"
    eval "$vars" 2>/dev/null
    joined="$(sed ':a;N;$!ba;s/\\\n[ \t]*/ /g' "$target")"
    raw="$(grep -m1 -E '(^|[[:space:]])[^[:space:]]*/jellyfin([[:space:]]|$)' <<<"$joined")"
    [ -z "$raw" ] && die "Could not find the jellyfin binary in wrapper script '$target'"
    eval "invocation=\"$raw\"" 2>/dev/null
  fi

  BIN_PATH="$(awk '{print $1}' <<<"$invocation")"
  [ -x "$BIN_PATH" ] || die "Detected jellyfin binary '$BIN_PATH' is not executable"
  INSTALL_DIR="$(dirname "$BIN_PATH")"

  DATA_DIR="$(sed -nE 's/.*(^|[[:space:]])-d ([^[:space:]]+).*/\2/p;s/.*--datadir[= ]([^[:space:]]+).*/\1/p' <<<"$invocation" | tail -n1)"
  [ -n "$DATA_DIR_OVERRIDE" ] && DATA_DIR="$DATA_DIR_OVERRIDE"
  [ -z "$DATA_DIR" ] && DATA_DIR="/var/lib/jellyfin"

  # Safety net: don't touch installations managed by a package manager
  if command -v dpkg >/dev/null 2>&1 && dpkg -S "$BIN_PATH" >/dev/null 2>&1; then
    die "'$BIN_PATH' is managed by dpkg – please update via apt instead"
  fi
  if command -v rpm >/dev/null 2>&1 && rpm -qf "$BIN_PATH" >/dev/null 2>&1; then
    die "'$BIN_PATH' is managed by rpm – please update via dnf/yum instead"
  fi

  log "Detected: binary=$BIN_PATH install_dir=$INSTALL_DIR data_dir=$DATA_DIR"
}

# ─────────────────────────── Versions & download ────────────────────────────
current_version() {
  "$BIN_PATH" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}

latest_version() {
  curl -fsSL https://api.github.com/repos/jellyfin/jellyfin/releases/latest \
    | grep -m1 '"tag_name"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'
}

download_package() {
  local version="$1" arch="$2" dest="$3"
  local dir="https://repo.jellyfin.org/files/server/linux/latest-stable/${arch}/"
  if curl -fsSL -o "$dest" "${dir}jellyfin_${version}-${arch}.tar.gz"; then
    return 0
  fi
  log "Direct download failed, trying directory listing as a fallback"
  local found
  found="$(curl -fsSL "$dir" | grep -oE "jellyfin_[0-9.]+-${arch}\.tar\.gz" | sort -V | tail -n1)"
  [ -z "$found" ] && return 1
  curl -fsSL -o "$dest" "${dir}${found}"
}

# ───────────────────────────── Backup / rollback ────────────────────────────
backup() {
  mkdir -p "$BACKUP_DIR"
  BACKUP_FILE="$BACKUP_DIR/jellyfin-backup-$(date '+%Y%m%d-%H%M%S').tar.gz"
  tar czf "$BACKUP_FILE" --absolute-names "$INSTALL_DIR" "$DATA_DIR" 2>>"$LOG_FILE" \
    || die "Backup failed"
  log "Backup created: $BACKUP_FILE"
  ls -1t "$BACKUP_DIR"/jellyfin-backup-*.tar.gz 2>/dev/null | tail -n "+$((KEEP_BACKUPS + 1))" | xargs -r rm -f
}

rollback() {
  log "Rolling back (reason: $1)"
  systemctl stop "$SERVICE_NAME" 2>/dev/null
  rm -rf "$INSTALL_DIR" "$DATA_DIR"
  tar xzf "$BACKUP_FILE" -C / || log "ERROR: failed to restore backup"
  systemctl start "$SERVICE_NAME" 2>/dev/null
  send_mail "Failed to update to ver ${LATEST_VER}, reason: $1" \
"Trying to update from ver ${CURRENT_VER} to ver ${LATEST_VER}
Failed to update to ver ${LATEST_VER}, reason: $1
Rolled back to ver ${CURRENT_VER}."
}

# ────────────────────────────── Deploy / health ─────────────────────────────
deploy() {
  local pkg="$1" extract_dir="$TMP_DIR/extract"
  mkdir -p "$extract_dir"
  tar xzf "$pkg" -C "$extract_dir" || die "Could not extract package"

  local new_bin
  new_bin="$(find "$extract_dir" -type f -name jellyfin \
    -exec sh -c 'file "$1" | grep -qi ELF' _ {} \; -print | head -n1)"
  [ -z "$new_bin" ] && die "Could not find the jellyfin binary in the downloaded package"

  local pkg_root owner
  pkg_root="$(dirname "$new_bin")"
  owner="$(stat -c '%U:%G' "$INSTALL_DIR")"

  rsync -a --delete "$pkg_root"/ "$INSTALL_DIR"/ || die "Could not deploy new version"
  chown -R "$owner" "$INSTALL_DIR"

  # If the binary in the new package moved/was renamed: update the systemd unit
  local new_bin_final="$INSTALL_DIR/$(basename "$new_bin")"
  if [ "$new_bin_final" != "$BIN_PATH" ]; then
    log "Binary path changed ($BIN_PATH -> $new_bin_final), updating systemd unit"
    local unit_file
    unit_file="$(systemctl show -p FragmentPath --value "$SERVICE_NAME")"
    sed -i "s#$BIN_PATH#$new_bin_final#" "$unit_file"
    systemctl daemon-reload
    BIN_PATH="$new_bin_final"
  fi
}

health_check() {
  local url="http://127.0.0.1:${HEALTH_PORT}${HEALTH_URL_PATH}" i
  for ((i = 1; i <= HEALTH_RETRIES; i++)); do
    if curl -fsS "$url" 2>/dev/null | grep -q "\"Version\":\"$LATEST_VER\""; then
      return 0
    fi
    sleep "$HEALTH_DELAY"
  done
  return 1
}

# ───────────────────────────────── Main flow ────────────────────────────────
run_update() {
  require_root
  TMP_DIR="$(mktemp -d)"

  ARCH="$(detect_arch)"
  find_installation

  CURRENT_VER="$(current_version)"
  [ -z "$CURRENT_VER" ] && die "Could not determine the currently installed Jellyfin version"
  LATEST_VER="$(latest_version)"
  [ -z "$LATEST_VER" ] && die "Could not determine the latest version from GitHub"

  if [ "$CURRENT_VER" = "$LATEST_VER" ]; then
    log "Already up to date (version $CURRENT_VER) – no update needed"
    exit 0
  fi

  log "Trying to update from ver $CURRENT_VER to ver $LATEST_VER"

  local pkg="$TMP_DIR/jellyfin.tar.gz"
  download_package "$LATEST_VER" "$ARCH" "$pkg" \
    || die "Download of version $LATEST_VER (architecture $ARCH) failed"

  backup
  ROLLBACK_READY=true

  systemctl stop "$SERVICE_NAME" || die "Could not stop the service"
  deploy "$pkg"
  systemctl start "$SERVICE_NAME" || die "Could not start the service"

  if health_check; then
    log "Updated successfully to ver $LATEST_VER"
    send_mail "Updated successfully to ver $LATEST_VER" \
"Trying to update from ver $CURRENT_VER to ver $LATEST_VER
Updated successfully to ver $LATEST_VER"
  else
    die "Health check after update failed (service is not responding as expected)"
  fi
}

install_cron() {
  require_root
  local schedule="${1:-0 4 * * *}"
  local cron_file="/etc/cron.d/jellyfin-updater"
  echo "$schedule root $SCRIPT_PATH --update >> $LOG_FILE 2>&1" > "$cron_file"
  chmod 644 "$cron_file"
  log "Cronjob installed: $cron_file ('$schedule')"
}



# Main Activity

case "${1:-}" in
  --update|"")
    run_update
    ;;
  --install-cron)
    install_cron "${2:-}"
    ;;
  --help|-h)
    cat <<EOF
Usage: $(basename "$0") [--update] [--install-cron ["CRON_SCHEDULE"]] [--help]

  --update        Run a one-off update (default, requires root)
  --install-cron  Set up a cronjob, default schedule: "0 4 * * *"
                  Example: $(basename "$0") --install-cron "0 3 * * 0"
  --help          Show this help

Configuration (paths, SMTP credentials, health check, backups) can be
adjusted at the top of this script.
EOF
    ;;
  *)
    echo "Unknown option: $1" >&2
    exit 1
    ;;
esac