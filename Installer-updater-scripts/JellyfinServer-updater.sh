#!/usr/bin/env bash
#
# jellyfin-updater.sh — Updater for portable Jellyfin Linux builds
# Auto-detects installation (systemd or user process), updates to latest
# stable, health-checks, and rolls back on failure.
# NOTE: manual "portable" tar.gz only — apt/dnf installs are rejected.
#
# Usage:
#   sudo ./jellyfin-updater.sh                          # one-off update
#   sudo ./jellyfin-updater.sh --update-migrate         # update & migrate to systemd
#   sudo ./jellyfin-updater.sh --install-cron ["CRON"]  # set up a cronjob
#   sudo ./jellyfin-updater.sh --help
#
set -uo pipefail

# Config
SERVICE_NAME="jellyfin"
DATA_DIR_OVERRIDE=""
# Directory Jellyfin may read/write (e.g. /mnt/media/movies). Empty = not added to the
# systemd unit. Set via environment (MEDIA_DIR=/mnt/media ./jellyfin-updater.sh) or here.
MEDIA_DIR="${MEDIA_DIR:-}"
BACKUP_DIR="/var/backups/jellyfin-updater"
KEEP_BACKUPS=5
LOG_FILE="/var/log/jellyfin-updater.log"
HEALTH_PORT="8096"
HEALTH_URL_PATH="/System/Info/Public"
HEALTH_RETRIES=20
HEALTH_DELAY=30
MAIL_TO=""
MAIL_FROM="jellyfin-updater@$(hostname -f 2>/dev/null || hostname)"
SMTP_URL=""
SMTP_USER=""
SMTP_PASS=""

# Runtime state
SCRIPT_PATH="$(readlink -f "$0")"
TMP_DIR="" ROLLBACK_READY=false ROLLBACK_REASON=""
ARCH="" BIN_PATH="" INSTALL_DIR="" DATA_DIR="" CONFIG_DIR="" LOG_DIR="" CACHE_DIR=""
CURRENT_VER="" LATEST_VER="" BACKUP_FILE=""
JELLYFIN_PROCESS_USER="" JELLYFIN_PROCESS_PID="" JELLYFIN_PROCESS_CMD=""
RUNNING_VIA_SYSTEMD=true MIGRATE_TO_SYSTEMD=false MIGRATED_FROM_USER=false

# ============================================================================
# Helpers
# ============================================================================

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
cleanup() { [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

send_mail() {
  local subject="$1" body="${2:-}"
  [ -z "$MAIL_TO" ] || [ -z "$SMTP_URL" ] && return 0
  local boundary="jfupdater-$$" msg_file="$(mktemp)"
  { echo "From: $MAIL_FROM"; echo "To: $MAIL_TO"; echo "Subject: $subject"
    echo "MIME-Version: 1.0"; echo "Content-Type: multipart/mixed; boundary=\"$boundary\""; echo
    echo "--$boundary"; echo "Content-Type: text/plain; charset=UTF-8"; echo; echo "$body"; echo
    echo "Log file: $LOG_FILE"
    [ -f "$LOG_FILE" ] && { echo "--$boundary"; echo "Content-Type: text/plain; name=\"$(basename "$LOG_FILE")\""
      echo "Content-Transfer-Encoding: base64"; echo "Content-Disposition: attachment; filename=\"$(basename "$LOG_FILE")\""; echo
      base64 "$LOG_FILE"; }
    echo "--$boundary--"; } >"$msg_file"
  local curl_opts=(-s --url "$SMTP_URL" --mail-from "$MAIL_FROM" --mail-rcpt "$MAIL_TO" --upload-file "$msg_file")
  [[ "$SMTP_URL" == smtp://* ]] && curl_opts+=(--ssl-reqd)
  [ -n "$SMTP_USER" ] && curl_opts+=(--user "$SMTP_USER:$SMTP_PASS")
  curl "${curl_opts[@]}" 2>/dev/null || log "WARNING: failed to send email"
  rm -f "$msg_file"
}

die() {
  log "ERROR: $*"
  if $ROLLBACK_READY; then ROLLBACK_REASON="$*"; rollback
  else send_mail "Failed to update to ver ${LATEST_VER:-?}, reason: $*"; fi
  exit 1
}
require_root() { [ "$(id -u)" -eq 0 ] || { echo "Please run as root." >&2; exit 1; }; }

# ============================================================================
# Process Detection & Management
# ============================================================================

detect_jellyfin_process() {
  local match_pid match_user match_cmd
  match_pid="$(pgrep -af jellyfin 2>/dev/null | grep -v "jellyfin-updater\|grep.*jellyfin" | grep -oE '^[0-9]+' | head -n1)"
  [ -z "$match_pid" ] && return 1
  match_user="$(ps -o user= -p "$match_pid" 2>/dev/null | tr -d ' ')"
  match_cmd="$(ps -o args= -p "$match_pid" 2>/dev/null)"
  [ -z "$match_user" ] || [ -z "$match_cmd" ] && return 1
  JELLYFIN_PROCESS_PID="$match_pid"; JELLYFIN_PROCESS_USER="$match_user"; JELLYFIN_PROCESS_CMD="$match_cmd"
  RUNNING_VIA_SYSTEMD=false
  log "Detected jellyfin user process, PID=$match_pid, user=$match_user"
}

kill_jellyfin_process() {
  [ -z "$JELLYFIN_PROCESS_PID" ] && return 0
  log "Stopping jellyfin process (PID=$JELLYFIN_PROCESS_PID)..."
  kill -TERM "$JELLYFIN_PROCESS_PID" 2>/dev/null
  local attempt; for ((attempt=1; attempt<=30; attempt++)); do
    kill -0 "$JELLYFIN_PROCESS_PID" 2>/dev/null || { log "Jellyfin process stopped"; return 0; }
    sleep 1
  done
  log "Process did not stop gracefully, sending SIGKILL..."
  kill -KILL "$JELLYFIN_PROCESS_PID" 2>/dev/null; sleep 1
  kill -0 "$JELLYFIN_PROCESS_PID" 2>/dev/null && die "Failed to kill jellyfin process"
  log "Jellyfin process killed"
}

ask_migrate_to_systemd() {
  local response; echo -n "Jellyfin is running as a user process. Migrate to systemd? [Y/n]: "; read -r response
  [[ "$response" =~ ^[Nn] ]] && return 1; return 0
}

service_user() {
  [ -n "$JELLYFIN_PROCESS_USER" ] && { echo "$JELLYFIN_PROCESS_USER"; return 0; }
  local unit_file user
  unit_file="$(systemctl show -p FragmentPath --value "$SERVICE_NAME" 2>/dev/null)"
  if [ -f "$unit_file" ]; then
    user="$(sed -n 's/^User=//p' "$unit_file" 2>/dev/null | head -n1 | tr -d '[:space:]')"
    [ -n "$user" ] && { echo "$user"; return 0; }
  fi
  echo root
}

as_user() {
  local user="$1"; shift
  if command -v runuser >/dev/null 2>&1; then runuser -u "$user" -- "$@"
  else sudo -u "$user" "$@"; fi
}

# MEDIA_DIR must be usable by the service user before we touch anything, otherwise the
# unit would come up with a ReadWritePaths entry that does not exist and systemd would
# refuse to start jellyfin.
validate_media_dir() {
  [ -z "$MEDIA_DIR" ] && return 0
  case "$MEDIA_DIR" in /*) ;; *) die "MEDIA_DIR '$MEDIA_DIR' is not an absolute path" ;; esac
  [ -d "$MEDIA_DIR" ] || die "MEDIA_DIR '$MEDIA_DIR' does not exist or is not a directory — create it, point MEDIA_DIR at an existing path, or leave MEDIA_DIR empty"
  local user; user="$(service_user)"
  as_user "$user" test -r "$MEDIA_DIR" || die "MEDIA_DIR '$MEDIA_DIR' is not readable by service user '$user'"
  as_user "$user" test -w "$MEDIA_DIR" || die "MEDIA_DIR '$MEDIA_DIR' is not writable by service user '$user' — fix it with: chown $user '$MEDIA_DIR' (or set MEDIA_DIR to a writable path)"
  log "MEDIA_DIR '$MEDIA_DIR' is readable and writable by '$user'"
  case "$MEDIA_DIR" in /home/*|/root/*)
    log "NOTE: MEDIA_DIR is under a home directory; the unit sets ProtectHome=read-only, so verify jellyfin can still write there" ;;
  esac
}

create_systemd_service() {
  local svc_user="${JELLYFIN_PROCESS_USER:-root}" service_file="/etc/systemd/system/jellyfin.service"
  local media_env="" rw_extra=""
  [ -n "$MEDIA_DIR" ] && { media_env="Environment=JELLYFIN_MEDIA_DIR=$MEDIA_DIR"; rw_extra=" $MEDIA_DIR"; }
  log "Creating systemd service for user '$svc_user'..."
  mkdir -p "$DATA_DIR" "$CONFIG_DIR" "$LOG_DIR" "$CACHE_DIR"
  cat > "$service_file" <<EOF
[Unit]
Description=Jellyfin Media Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$svc_user
Group=$svc_user
WorkingDirectory=$INSTALL_DIR
Environment=JELLYFIN_DATA_DIR=$DATA_DIR
Environment=JELLYFIN_CONFIG_DIR=$CONFIG_DIR
Environment=JELLYFIN_LOG_DIR=$LOG_DIR
Environment=JELLYFIN_CACHE_DIR=$CACHE_DIR
Environment="MALLOC_TRIM_THRESHOLD_=100000"
Environment=DOTNET_EnableWriteFilePreallocation=0
$media_env
ExecStart=$BIN_PATH --datadir $DATA_DIR --configdir $CONFIG_DIR --logdir $LOG_DIR --cachedir $CACHE_DIR
Restart=on-failure
RestartSec=10
TimeoutStartSec=120
TimeoutStopSec=30
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$DATA_DIR $CONFIG_DIR $LOG_DIR $CACHE_DIR $INSTALL_DIR$rw_extra

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$service_file"; systemctl daemon-reload; systemctl enable jellyfin.service 2>/dev/null
  ensure_unit_env "$service_file"
  log "Systemd service created: $service_file"; RUNNING_VIA_SYSTEMD=true
}

# How MEDIA_DIR is written inside a unit file (systemd quoting for paths with spaces).
media_unit_path() {
  case "$MEDIA_DIR" in *[[:space:]]*) printf '"%s"' "$MEDIA_DIR" ;; *) printf '%s' "$MEDIA_DIR" ;; esac
}

# Appends a line to the [Service] section: after the last Environment= line if there is
# one, otherwise directly below [Service]. Writes via a temp file + cat so the unit keeps
# its ownership, mode and inode.
insert_unit_line() {
  local file="$1" line="$2" tmp
  tmp="$(mktemp)" || return 1
  if grep -q '^Environment=' "$file"; then
    awk -v l="$line" '{ a[NR]=$0; if ($0 ~ /^Environment=/) last=NR }
      END { for (i=1; i<=NR; i++) { print a[i]; if (i==last) print l } }' "$file" > "$tmp"
  else
    awk -v l="$line" '{ print; if ($0 ~ /^\[Service\]/) print l }' "$file" > "$tmp"
  fi
  cat "$tmp" > "$file"; rm -f "$tmp"
}

# Idempotently guarantees the runtime env vars and the MEDIA_DIR read-write path on an
# existing unit. Called after every point where a unit file is created or modified.
# $1 = unit file, defaults to the active unit's FragmentPath.
ensure_unit_env() {
  local unit_file="${1:-}"
  [ -n "$unit_file" ] || unit_file="$(systemctl show -p FragmentPath --value "$SERVICE_NAME" 2>/dev/null)"
  [ -n "$unit_file" ] && [ -f "$unit_file" ] || return 0
  log "Ensuring unit env/paths in $unit_file"
  local changed=false
  if ! grep -qE '^Environment="?MALLOC_TRIM_THRESHOLD_=' "$unit_file"; then
    if insert_unit_line "$unit_file" 'Environment="MALLOC_TRIM_THRESHOLD_=100000"' \
       && grep -qF 'MALLOC_TRIM_THRESHOLD_=' "$unit_file"; then changed=true
    else log "WARNING: could not add MALLOC_TRIM_THRESHOLD_ to $unit_file"; fi
  fi
  if ! grep -q '^Environment=DOTNET_EnableWriteFilePreallocation=' "$unit_file"; then
    if insert_unit_line "$unit_file" 'Environment=DOTNET_EnableWriteFilePreallocation=0' \
       && grep -qF 'DOTNET_EnableWriteFilePreallocation=' "$unit_file"; then changed=true
    else log "WARNING: could not add DOTNET_EnableWriteFilePreallocation to $unit_file"; fi
  fi
  if [ -n "$MEDIA_DIR" ]; then
    local media_path; media_path="$(media_unit_path)"
    if grep '^ReadWritePaths=' "$unit_file" | grep -qF " $media_path"; then
      log "ReadWritePaths already grants $MEDIA_DIR"
    elif grep -q '^ReadWritePaths=' "$unit_file"; then
      local tmp; tmp="$(mktemp)"
      if awk -v m="$media_path" '{ if (!done && /^ReadWritePaths=/) { print $0 " " m; done=1 } else print }' \
           "$unit_file" > "$tmp"; then
        cat "$tmp" > "$unit_file"; changed=true
      fi
      rm -f "$tmp"
      log "Added $MEDIA_DIR to ReadWritePaths in $unit_file"
    elif insert_unit_line "$unit_file" "ReadWritePaths=$media_path" \
         && grep -qF "ReadWritePaths=" "$unit_file"; then
      changed=true; log "Added ReadWritePaths=$MEDIA_DIR to $unit_file"
    else log "WARNING: could not add ReadWritePaths=$MEDIA_DIR to $unit_file"; fi
  fi
  $changed && { systemctl daemon-reload; log "Reloaded systemd after updating $unit_file"; }
  return 0
}

fix_permissions() {
  local svc_user; svc_user="$(service_user)"
  chown -R "$svc_user:$svc_user" "$DATA_DIR" "$CONFIG_DIR" "$LOG_DIR" "$CACHE_DIR" 2>/dev/null || true
  [ -d "$INSTALL_DIR" ] && chown -R "$svc_user:$svc_user" "$INSTALL_DIR" 2>/dev/null || true
}

stop_jellyfin() {
  $RUNNING_VIA_SYSTEMD && { systemctl stop "$SERVICE_NAME" 2>/dev/null || true; return; }
  kill_jellyfin_process 2>/dev/null
}

start_jellyfin() {
  if $RUNNING_VIA_SYSTEMD; then
    systemctl start "$SERVICE_NAME" 2>/dev/null || true
    sleep 3
    if systemctl is-active --quiet "$SERVICE_NAME"; then
      log "Systemd service '$SERVICE_NAME' started successfully"
    else
      log "WARNING: Systemd service '$SERVICE_NAME' may not be running. Check 'systemctl status $SERVICE_NAME'"
    fi
  else
    sudo -u "$JELLYFIN_PROCESS_USER" nohup $JELLYFIN_PROCESS_CMD &>/dev/null &
    sleep 3; JELLYFIN_PROCESS_PID=$!
    if kill -0 "$JELLYFIN_PROCESS_PID" 2>/dev/null; then
      log "User process started successfully, PID=$JELLYFIN_PROCESS_PID"
    else
      log "WARNING: User process may not be running. Check process manually."
    fi
  fi
}

# ============================================================================
# Architecture & Installation Detection
# ============================================================================

detect_arch() {
  case "$(uname -m)" in
    x86_64) echo "amd64" ;; aarch64|arm64) echo "arm64" ;; armv7l|armv6l) echo "armhf" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

unit_exec_line() {
  local exec_line
  # 1) systemctl cat — gives the raw ExecStart= line from the unit file (most reliable)
  exec_line="$(systemctl cat "$SERVICE_NAME" 2>/dev/null | sed ':a;N;$!ba;s/\\\n[ \t]*/ /g' | sed -n 's/^ExecStart=//p' | head -n1)"
  [ -n "$exec_line" ] && { echo "$exec_line"; return 0; }
  # 2) Read the unit file directly
  local unit_file; unit_file="$(systemctl show -p FragmentPath --value "$SERVICE_NAME" 2>/dev/null)"
  if [ -f "$unit_file" ]; then
    exec_line="$(sed ':a;N;$!ba;s/\\\n[ \t]*/ /g' "$unit_file" | sed -n 's/^ExecStart=//p' | head -n1)"
    [ -n "$exec_line" ] && { echo "$exec_line"; return 0; }
  fi
  # 3) systemctl show — structured format: { path=/bin/foo ; argv[] = /bin/foo arg1 arg2 ; ... }
  #    Extract argv[] which contains the real command line
  exec_line="$(systemctl show -p ExecStart --value "$SERVICE_NAME" 2>/dev/null | head -n1)"
  if [ -n "$exec_line" ] && [[ "$exec_line" == *"argv["* ]]; then
    exec_line="$(sed 's/.*argv\[\] *= *//;s/ ;.*//' <<<"$exec_line")"
    [ -n "$exec_line" ] && { echo "$exec_line"; return 0; }
  fi
  return 1
}

extract_paths_from_invocation() {
  local invocation="$1"
  BIN_PATH="$(awk '{print $1}' <<<"$invocation")"
  if [ -n "${JELLYFIN_PROCESS_PID:-}" ]; then
    local resolved; resolved="$(readlink -f "/proc/$JELLYFIN_PROCESS_PID/exe" 2>/dev/null)"
    [ -n "$resolved" ] && BIN_PATH="$resolved"
  fi
  [ -x "$BIN_PATH" ] || die "Binary '$BIN_PATH' is not executable"
  INSTALL_DIR="$(dirname "$BIN_PATH")"
  DATA_DIR="$(sed -nE 's/.*(^|[[:space:]])-d ([^[:space:]]+).*/\2/p; s/.*--datadir[= ]([^[:space:]]+).*/\1/p' <<<"$invocation" | tail -n1)"
  CONFIG_DIR="$(sed -nE 's/.*(^|[[:space:]])-c ([^[:space:]]+).*/\2/p; s/.*--configdir[= ]([^[:space:]]+).*/\1/p' <<<"$invocation" | tail -n1)"
  LOG_DIR="$(sed -nE 's/.*(^|[[:space:]])-l ([^[:space:]]+).*/\2/p; s/.*--logdir[= ]([^[:space:]]+).*/\1/p' <<<"$invocation" | tail -n1)"
  CACHE_DIR="$(sed -nE 's/.*(^|[[:space:]])-C ([^[:space:]]+).*/\2/p; s/.*--cachedir[= ]([^[:space:]]+).*/\1/p' <<<"$invocation" | tail -n1)"
  [ -n "$DATA_DIR_OVERRIDE" ] && DATA_DIR="$DATA_DIR_OVERRIDE"
  [ -z "$DATA_DIR" ] && DATA_DIR="/var/lib/jellyfin"
  [ -z "$CONFIG_DIR" ] && CONFIG_DIR="$DATA_DIR/config"
  [ -z "$LOG_DIR" ] && LOG_DIR="$DATA_DIR/log"
  [ -z "$CACHE_DIR" ] && CACHE_DIR="$DATA_DIR/cache"
}

find_installation() {
  local exec_line exec_target invocation

  # Try systemd service first
  if systemctl cat "$SERVICE_NAME" &>/dev/null || systemctl cat jellyfin &>/dev/null; then
    if ! systemctl cat "$SERVICE_NAME" &>/dev/null; then
      local candidate; for candidate in jellyfin jellyfin-server jellyfin-generic; do
        if systemctl cat "$candidate" &>/dev/null; then SERVICE_NAME="$candidate"; log "Using service '$candidate'"; break; fi
      done
    fi
    exec_line="$(unit_exec_line)"
    if [ -n "$exec_line" ]; then
      exec_target="$(awk '{print $1}' <<<"$exec_line")"
      [ -f "$exec_target" ] || { log "ExecStart target '$exec_target' not found"; exec_line=""; }
    fi
    if [ -n "$exec_line" ]; then
      if file "$exec_target" | grep -qi 'ELF'; then invocation="$exec_line"
      else
        invocation="$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=[^$`;&|]*$' "$exec_target")"; eval "$invocation" 2>/dev/null
        invocation="$(sed ':a;N;$!ba;s/\\\n[ \t]*/ /g' "$exec_target")"
        invocation="$(grep -m1 -E '(^|[[:space:]])[^[:space:]]*/jellyfin([[:space:]]|$)' <<<"$invocation")"
        [ -z "$invocation" ] && die "Could not find jellyfin binary in wrapper script '$exec_target'"
        eval "invocation=\"$invocation\"" 2>/dev/null
      fi
      extract_paths_from_invocation "$invocation"
      RUNNING_VIA_SYSTEMD=true
      log "Detected: binary=$BIN_PATH install_dir=$INSTALL_DIR data_dir=$DATA_DIR (via systemd)"
      return 0
    fi
  fi

  # Try running user process
  if detect_jellyfin_process; then
    extract_paths_from_invocation "$JELLYFIN_PROCESS_CMD"
    log "Detected: binary=$BIN_PATH install_dir=$INSTALL_DIR data_dir=$DATA_DIR (via user process)"
    return 0
  fi

  die "Could not find Jellyfin installation (no systemd service or running process found)"
}

# ============================================================================
# Version, Download, Backup, Deploy, Health
# ============================================================================

current_version() { "$BIN_PATH" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.?[0-9]*' | head -n1; }
latest_version() {
  local auth_header=()
  [ -n "${GITHUB_TOKEN:-}" ] && auth_header=(-H "Authorization: token $GITHUB_TOKEN")
  local api_response
  api_response="$(curl -fsSL "${auth_header[@]}" https://api.github.com/repos/jellyfin/jellyfin/releases/latest 2>/dev/null)" \
    || return 1
  if echo "$api_response" | grep -q "API rate limit exceeded"; then
    log "ERROR: GitHub API rate limit exceeded. Set GITHUB_TOKEN env var for higher limits."
    return 1
  fi
  echo "$api_response" | grep -m1 '"tag_name"' | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | sed 's/^v//'
}

download_package() {
  local dest="$TMP_DIR/jellyfin.tar.gz" dir="https://repo.jellyfin.org/files/server/linux/latest-stable/${ARCH}/"
  curl -fsSL -o "$dest" "${dir}jellyfin_${LATEST_VER}-${ARCH}.tar.gz" && return 0
  log "Direct download failed, trying directory listing as a fallback"
  local listing found
  listing="$(curl -fsSL "$dir" 2>/dev/null)" || return 1
  found="$(echo "$listing" | grep -oE "jellyfin_[0-9.]+-${ARCH}\.tar\.gz" | sort -V | tail -n1)"
  [ -z "$found" ] && return 1
  curl -fsSL -o "$dest" "${dir}${found}"
}

backup() {
  mkdir -p "$BACKUP_DIR"
  BACKUP_FILE="$BACKUP_DIR/jellyfin-backup-$(date '+%Y%m%d-%H%M%S').tar.gz"
  tar czf "$BACKUP_FILE" --absolute-names "$INSTALL_DIR" "$DATA_DIR" 2>>"$LOG_FILE" || die "Backup failed"
  log "Backup created: $BACKUP_FILE"
  ls -1t "$BACKUP_DIR"/jellyfin-backup-*.tar.gz 2>/dev/null | tail -n "+$((KEEP_BACKUPS + 1))" | xargs -r rm -f
}

rollback() {
  log "Rolling back (reason: $ROLLBACK_REASON)"; stop_jellyfin
  if $MIGRATED_FROM_USER; then
    log "Reverting migration: disabling systemd service and restoring user process"
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/$SERVICE_NAME.service"
    systemctl daemon-reload 2>/dev/null || true
    RUNNING_VIA_SYSTEMD=false
  fi
  rm -rf "$INSTALL_DIR" "$DATA_DIR"
  tar xzf "$BACKUP_FILE" -C / || log "ERROR: failed to restore backup"
  start_jellyfin
  send_mail "Failed to update to ver ${LATEST_VER}" \
"Trying to update from ver $CURRENT_VER to ver $LATEST_VER
Failed to update to ver $LATEST_VER, reason: $ROLLBACK_REASON
Rolled back to ver $CURRENT_VER."
}

deploy() {
  local extract_dir="$TMP_DIR/extract" new_bin pkg_root new_bin_final
  mkdir -p "$extract_dir"; tar xzf "$TMP_DIR/jellyfin.tar.gz" -C "$extract_dir" || die "Could not extract package"
  new_bin="$(find "$extract_dir" -type f -name jellyfin -exec sh -c 'file "$1" | grep -qi ELF' _ {} \; -print | head -n1)"
  [ -z "$new_bin" ] && die "Could not find jellyfin binary in downloaded package"
  pkg_root="$(dirname "$new_bin")"
  rsync -a --delete "$pkg_root"/ "$INSTALL_DIR"/ || die "Could not deploy new version"
  new_bin_final="$INSTALL_DIR/$(basename "$new_bin")"
  [ -x "$new_bin_final" ] || die "Deployed binary not executable: $new_bin_final"
  if [ "$new_bin_final" != "$BIN_PATH" ] && $RUNNING_VIA_SYSTEMD; then
    log "Binary path changed ($BIN_PATH -> $new_bin_final), updating systemd unit"
    local unit_file; unit_file="$(systemctl show -p FragmentPath --value "$SERVICE_NAME")"
    sed -i "s|^ExecStart=$BIN_PATH |ExecStart=$new_bin_final |" "$unit_file"
    ensure_unit_env "$unit_file"
    systemctl daemon-reload; BIN_PATH="$new_bin_final"
  fi
  BIN_PATH="$new_bin_final"
  INSTALL_DIR="$(dirname "$BIN_PATH")"
}

health_check() {
  local url="http://127.0.0.1:${HEALTH_PORT}${HEALTH_URL_PATH}" attempt
  local expected_version="$LATEST_VER"
  log "Health check: looking for Version=$expected_version at $url"
  log "Health check: LATEST_VER hex=$(printf '%s' "$expected_version" | xxd -p)"
  for ((attempt=1; attempt<=HEALTH_RETRIES; attempt++)); do
    log "Health check attempt $attempt/$HEALTH_RETRIES..."
    local response
    response="$(curl -fsS "$url" 2>/dev/null)" || { log "Health check: could not reach $url"; sleep "$HEALTH_DELAY"; continue; }
    log "Health check: response=$response"
    local server_version
    server_version="$(echo "$response" | sed -n 's/.*"Version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    log "Health check: server_version=$server_version expected=$expected_version"
    local sv_norm="${server_version%%.0}" ev_norm="${expected_version%%.0}"
    if [ "$sv_norm" = "$ev_norm" ]; then
      log "Health check passed on attempt $attempt"
      return 0
    fi
    if [ "$attempt" -eq 5 ] || [ "$attempt" -eq "$HEALTH_RETRIES" ]; then
      log "Checking server logs for errors..."
      if $RUNNING_VIA_SYSTEMD; then
        journalctl -u "$SERVICE_NAME" --no-pager -n 20 2>/dev/null | tee -a "$LOG_FILE" || true
      else
        local log_dir; log_dir="$(dirname "$DATA_DIR")"
        [ -f "$log_dir/logs/jellyfin_$(date +%Y-%m-%d).log" ] && tail -20 "$log_dir/logs/jellyfin_$(date +%Y-%m-%d).log" | tee -a "$LOG_FILE" || true
      fi
    fi
    sleep "$HEALTH_DELAY"
  done; return 1
}

# ============================================================================
# Main Flow
# ============================================================================

run_update() {
  require_root; TMP_DIR="$(mktemp -d)"; ARCH="$(detect_arch)"; find_installation
  validate_media_dir
  # Fix overlapping data/config dirs — Jellyfin 10.11+ / v12 refuses to start if both markers share a directory
  if [ "$CONFIG_DIR" = "$DATA_DIR" ]; then
    log "WARNING: Data and config directories overlap ($CONFIG_DIR). Separating config to $DATA_DIR/config for v12+ compatibility."
    CONFIG_DIR="$DATA_DIR/config"
  fi
  CURRENT_VER="$(current_version)"
  [ -z "$CURRENT_VER" ] && die "Could not determine the currently installed Jellyfin version"
  LATEST_VER="$(latest_version)"
  [ -z "$LATEST_VER" ] && die "Could not determine the latest version from GitHub"
  [ "$CURRENT_VER" = "$LATEST_VER" ] && { log "Already up to date (version $CURRENT_VER)"; exit 0; }
  log "Trying to update from ver $CURRENT_VER to ver $LATEST_VER"
  download_package || die "Download of version $LATEST_VER (architecture $ARCH) failed"
  if ! $RUNNING_VIA_SYSTEMD; then
    ([ "$MIGRATE_TO_SYSTEMD" = true ] || ask_migrate_to_systemd) && {
      MIGRATED_FROM_USER=true
    }
  fi
  stop_jellyfin
  backup; ROLLBACK_READY=true
  deploy
  if $MIGRATED_FROM_USER; then
    create_systemd_service
  fi
  fix_permissions
  [ -x "$BIN_PATH" ] || die "Binary '$BIN_PATH' not found after deploy"
  log "Deploy complete: binary=$BIN_PATH install_dir=$INSTALL_DIR"
  log "Verify binary exists: $(ls -la "$BIN_PATH" 2>&1)"
  start_jellyfin
  log "Server started. Note: Jellyfin 12.x may take several minutes for database migrations on first startup."
  if health_check; then
    log "Updated successfully to ver $LATEST_VER"
    send_mail "Updated successfully to ver $LATEST_VER" "Updated from $CURRENT_VER to $LATEST_VER"
    exit 0
  else die "Health check after update failed"; fi
}

install_cron() {
  require_root; local schedule="${1:-0 4 * * *}" cron_file="/etc/cron.d/jellyfin-updater"
  echo "$schedule root $SCRIPT_PATH --update >> $LOG_FILE 2>&1" > "$cron_file"
  chmod 644 "$cron_file"; log "Cronjob installed: $cron_file ('$schedule')"
}

# ============================================================================
# Entry Point
# ============================================================================

case "${1:-}" in
  --update|"") run_update ;;
  --update-migrate) MIGRATE_TO_SYSTEMD=true; run_update ;;
  --install-cron) install_cron "${2:-}" ;;
  --help|-h) cat <<EOF
Usage: $(basename "$0") [--update] [--update-migrate] [--install-cron ["CRON_SCHEDULE"]] [--help]
  --update          Run a one-off update (default, requires root)
  --update-migrate  Update and migrate user process to systemd service
  --install-cron    Set up a cronjob, default schedule: "0 4 * * *"
  --help            Show this help

Environment:
  MEDIA_DIR         Directory Jellyfin may read/write, added to the unit's
                    ReadWritePaths and exposed as JELLYFIN_MEDIA_DIR. Must
                    exist and be read/writable by the service user. Empty (the
                    default) = not added to the unit.
                    Example: sudo MEDIA_DIR=/mnt/media/movies ./jellyfin-updater.sh
EOF
  ;; *) echo "Unknown option: $1" >&2; exit 1 ;;
esac