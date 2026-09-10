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

create_systemd_service() {
  local service_user="${JELLYFIN_PROCESS_USER:-root}" service_file="/etc/systemd/system/jellyfin.service"
  log "Creating systemd service for user '$service_user'..."
  mkdir -p "$DATA_DIR" "$CONFIG_DIR" "$LOG_DIR" "$CACHE_DIR"
  cat > "$service_file" <<EOF
[Unit]
Description=Jellyfin Media Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$service_user
Group=$service_user
WorkingDirectory=$INSTALL_DIR
Environment=JELLYFIN_DATA_DIR=$DATA_DIR
Environment=JELLYFIN_CONFIG_DIR=$CONFIG_DIR
Environment=JELLYFIN_LOG_DIR=$LOG_DIR
Environment=JELLYFIN_CACHE_DIR=$CACHE_DIR
ExecStart=$BIN_PATH --datadir $DATA_DIR --configdir $CONFIG_DIR --logdir $LOG_DIR --cachedir $CACHE_DIR
Restart=on-failure
RestartSec=10
TimeoutStartSec=120
TimeoutStopSec=30
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$DATA_DIR $CONFIG_DIR $LOG_DIR $CACHE_DIR $INSTALL_DIR

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$service_file"; systemctl daemon-reload; systemctl enable jellyfin.service 2>/dev/null
  log "Systemd service created: $service_file"; RUNNING_VIA_SYSTEMD=true
}

fix_permissions() {
  local service_user="${JELLYFIN_PROCESS_USER:-root}"
  chown -R "$service_user:$service_user" "$DATA_DIR" "$CONFIG_DIR" "$LOG_DIR" "$CACHE_DIR" 2>/dev/null || true
  [ -d "$INSTALL_DIR" ] && chown -R "$service_user:$service_user" "$INSTALL_DIR" 2>/dev/null || true
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
  exec_line="$(systemctl show -p ExecStart --value "$SERVICE_NAME" 2>/dev/null | head -n1)"
  [ -n "$exec_line" ] && [ "$exec_line" != "ExecStart=" ] && { echo "$exec_line"; return 0; }
  exec_line="$(systemctl cat "$SERVICE_NAME" 2>/dev/null | sed ':a;N;$!ba;s/\\\n[ \t]*/ /g' | sed -n 's/^ExecStart=//p' | head -n1)"
  [ -n "$exec_line" ] && { echo "$exec_line"; return 0; }
  local unit_file; unit_file="$(systemctl show -p FragmentPath --value "$SERVICE_NAME" 2>/dev/null)"
  [ -f "$unit_file" ] || return 1
  sed ':a;N;$!ba;s/\\\n[ \t]*/ /g' "$unit_file" | sed -n 's/^ExecStart=//p' | head -n1
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
    if [ "$server_version" = "$expected_version" ]; then
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
  backup; ROLLBACK_READY=true
  if ! $RUNNING_VIA_SYSTEMD; then
    ([ "$MIGRATE_TO_SYSTEMD" = true ] || ask_migrate_to_systemd) && {
      MIGRATED_FROM_USER=true
      stop_jellyfin
    }
  else
    stop_jellyfin
  fi
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
EOF
  ;; *) echo "Unknown option: $1" >&2; exit 1 ;;
esac