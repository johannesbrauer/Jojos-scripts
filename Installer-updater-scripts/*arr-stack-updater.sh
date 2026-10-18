#!/usr/bin/env bash
# ==============================================================================
#  Native media-stack updater (NO DOCKER) - companion to *arr-stack-installer.sh
#
#  Looks for and applies updates for the stack the installer created, while
#  preserving all user data (configs, databases, downloads/media live on the NAS
#  or in the app data dirs and are never touched):
#
#    --servarr       Prowlarr, Radarr, Sonarr, Lidarr, Whisparr
#    --qBittorrent   qBittorrent-nox (apt, exactly like the installer)
#    --Homarr        Homarr (git tag + pnpm build, like the installer)
#    --Seerr         Seerr (git main + embedded Node 22 + pnpm 10, like the installer)
#    --Byparr        git pull /opt/Byparr + restart its systemd unit (no backup)
#
#  Per section: detect installed vs latest -> if newer: backup -> update ->
#  health check -> on failure roll back to the backup.
#  Backups: $BACKUP_DIR/<app>/<timestamp>.tar.gz, newest KEEP_BACKUPS kept
#  (the just-created "current" backup always survives, older ones are pruned).
#
#  Flags are combinable. Running with no flag prints this help and does nothing.
# ==============================================================================
set -euo pipefail
trap 'echo "ERROR: updater aborted at line ${LINENO} (exit $?)" >&2' ERR

# ---------- CONFIGURATION (edit these) --------------------------------------
# qBittorrent WebUI address inside the VPN namespace (must match the installer).
VETH_NS_IP="10.200.200.2"
QBIT_WEBUI_PORT="8080"

# The *arr apps to check, as "Name:branch" (Sonarr v4 is special-cased in code).
SERVARR_APPS=(
  "Prowlarr:master"
  "Radarr:master"
  "Sonarr:main"
  "Lidarr:master"
  "Whisparr:nightly"
)

# Service users/groups created by the installer.
MEDIASVC_USER="mediasvc"
MEDIANAS_GROUP="medianas"

# qBittorrent (installed via apt by the installer).
QBIT_CONFIG_DIR="/home/qbtuser/.config/qBittorrent"

# Homarr (source build, like the installer).
HOMARR_DIR="/opt/homarr"
HOMARR_DATA_DIR="/opt/homarr-data"
HOMARR_HEALTH_URL="http://127.0.0.1:3000/api/health/live"
HOMARR_UNITS=(homarr-nextjs homarr-websocket homarr-tasks)

# Seerr (source build with the private Node 22 + pnpm 10 the installer embedded).
SEERR_DIR="/opt/seerr"
SEERR_BRANCH="main"
SEERR_HEALTH_URL="http://127.0.0.1:5055/api/v1/status"
NODE22_DIR="/opt/seerr-node"
PNPM10_DIR="/opt/pnpm10"

# Byparr (pull-only; must already be installed at $BYPARR_DIR with a systemd unit).
BYPARR_DIR="/opt/Byparr"
BYPARR_SERVICE="byparr.service"
BYPARR_HEALTH_URL="http://127.0.0.1:8191/"
BYPARR_BRANCH="main"

# Backups: newest KEEP_BACKUPS archives per app are kept.
BACKUP_DIR="/var/backups/arr-stack-updater"
KEEP_BACKUPS=2

LOG_FILE="/var/log/arr-stack-updater.log"

# How long to wait for a service to become healthy after an update.
HEALTH_RETRIES=40
HEALTH_DELAY=10

# ---------- RUNTIME STATE ----------------------------------------------------
require_root() { [[ $EUID -eq 0 ]] || { echo "Please run as root." >&2; exit 1; }; }

mkdir -p "$(dirname "$LOG_FILE")"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }

WORK_DIR=""
CURRENT_BACKUP=""
cleanup() { if [[ -n "$WORK_DIR" ]]; then rm -rf "$WORK_DIR"; fi; return 0; }
trap cleanup EXIT

die() { log "ERROR: $*"; exit 1; }

prompt_yes() {
  local msg="$1" ans
  if [[ -t 0 ]]; then
    read -r -p "${msg} [y/N]: " ans
    [[ "$ans" =~ ^[Yy] ]]
  else
    log "Non-interactive shell; defaulting to NO for: ${msg}"
    return 1
  fi
}

# git wrapper that honours the repo's owning user (installed dirs belong to
# mediasvc, but this script runs as root -> would otherwise trip "dubious ownership").
git_dir() { local d="$1"; shift; git -c "safe.directory=$d" -C "$d" "$@"; }

ensure_deps() {
  local missing=() c
  for c in curl git jq tar; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log "Installing missing packages: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" || die "Could not install: ${missing[*]}"
  fi
}

# ---------- BACKUP / RESTORE -------------------------------------------------
# backup_now <app-key> <path> [path...]
backup_now() {
  local key="$1"; shift
  mkdir -p "$BACKUP_DIR/$key"
  CURRENT_BACKUP="$BACKUP_DIR/$key/${key}-$(date '+%Y%m%d-%H%M%S').tar.gz"
  if ! tar czf "$CURRENT_BACKUP" --absolute-names "$@" 2>>"$LOG_FILE"; then
    log "ERROR: backup failed for ${key}"
    CURRENT_BACKUP=""
    return 1
  fi
  log "Backup created: $CURRENT_BACKUP"
  # Keep only the newest KEEP_BACKUPS archives (the current one always remains).
  ls -1t "$BACKUP_DIR/$key"/*.tar.gz 2>/dev/null | tail -n "+$((KEEP_BACKUPS + 1))" | xargs -r rm -f || true
  return 0
}

# restore_backup <tarball> <path> [path...] - replace the given paths with the archive.
restore_backup() {
  local archive="$1"; shift
  local p
  [[ -n "$archive" && -f "$archive" ]] || { log "WARN: no backup archive to restore from"; return 1; }
  for p in "$@"; do rm -rf "$p"; done
  tar xzf "$archive" -C / 2>>"$LOG_FILE" || { log "ERROR: restore from ${archive} failed"; return 1; }
  return 0
}

# ---------- SERVARR ----------------------------------------------------------
SERVARR_ARCH=""
detect_arch() {
  case "$(uname -m)" in
    aarch64) SERVARR_ARCH=arm64 ;;
    armv7l)  SERVARR_ARCH=arm ;;
    x86_64)  SERVARR_ARCH=x64   ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

# Extract <Key>value</Key> from a Servarr config.xml.
config_val() {
  local file="$1" key="$2"
  sed -n "s:.*<${key}>\(.*\)</${key}>.*:\1:p" "$file" 2>/dev/null | head -n1
}

# Query the app's own API for its version (v3 then v1), 127.0.0.1:port.
servarr_api_version() {
  local port="$1" apikey="$2" path v
  for path in /api/v3/system/status /api/v1/system/status; do
    v=$(curl -fsSL --max-time 8 -H "X-Api-Key: ${apikey}" \
          "http://127.0.0.1:${port}${path}" 2>/dev/null | jq -r '.version // empty' 2>/dev/null || true)
    [[ -n "$v" ]] && { echo "$v"; return 0; }
  done
  return 1
}

# Installed version via config.xml + API, falling back to the newest log file.
servarr_installed_version() {
  local datadir="$1" cfg="$1/config.xml" port apikey v logf
  if [[ -f "$cfg" ]]; then
    port="$(config_val "$cfg" Port)"
    apikey="$(config_val "$cfg" ApiKey)"
    if [[ -n "$port" && -n "$apikey" ]]; then
      if v="$(servarr_api_version "$port" "$apikey")"; then echo "$v"; return 0; fi
    fi
  fi
  logf="$(ls -1t "$datadir"/logs/*.txt 2>/dev/null | head -n1 || true)"
  if [[ -n "$logf" && -f "$logf" ]]; then
    v="$(grep -oE 'Version [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$logf" 2>/dev/null | tail -n1 | awk '{print $2}' || true)"
    if [[ -n "$v" ]]; then echo "$v"; return 0; fi
  fi
  return 1
}

servarr_latest_version() {
  local name="$1" branch="$2" lower url
  lower="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
  if [[ "$name" == "Sonarr" ]]; then
    url="https://services.sonarr.tv/v1/update/${branch}/changes?version=4&os=linux&runtime=netcore&arch=${SERVARR_ARCH}"
  else
    url="https://${lower}.servarr.com/v1/update/${branch}/changes?os=linux&runtime=netcore&arch=${SERVARR_ARCH}"
  fi
  curl -fsSL --max-time 20 "$url" 2>/dev/null | jq -r '.[0].version // empty' 2>/dev/null || true
}

# Exact download URLs used by the installer.
servarr_download_url() {
  local name="$1" branch="$2" lower
  lower="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
  if [[ "$name" == "Sonarr" ]]; then
    echo "https://services.sonarr.tv/v1/download/main/latest?version=4&os=linux&arch=${SERVARR_ARCH}"
  else
    echo "https://${lower}.servarr.com/v1/update/${branch}/updatefile?os=linux&runtime=netcore&arch=${SERVARR_ARCH}"
  fi
}

# Health: wait until the API reports the expected version (or service active if unconfigured).
servarr_health() {
  local name="$1" datadir="$2" expected="$3" lower
  lower="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
  local cfg="$datadir/config.xml" port apikey v i
  if [[ ! -f "$cfg" ]]; then
    sleep 3
    systemctl is-active --quiet "$lower"
    return $?
  fi
  port="$(config_val "$cfg" Port)"
  apikey="$(config_val "$cfg" ApiKey)"
  if [[ -z "$port" || -z "$apikey" ]]; then
    sleep 3
    systemctl is-active --quiet "$lower"
    return $?
  fi
  for ((i = 1; i <= HEALTH_RETRIES; i++)); do
    v="$(servarr_api_version "$port" "$apikey" || true)"
    [[ "$v" == "$expected" ]] && return 0
    sleep "$HEALTH_DELAY"
  done
  return 1
}

update_servarr_app() {
  local entry="$1" name branch lower install_dir data_dir cur latest url tarball tmpdir
  name="${entry%%:*}"; branch="${entry##*:}"
  lower="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
  install_dir="/opt/${name}"
  data_dir="/opt/${name}-data"

  if [[ ! -x "${install_dir}/${name}" ]]; then
    log "SKIP ${name}: not installed (${install_dir}/${name} missing)"
    return 0
  fi

  cur="$(servarr_installed_version "$data_dir" || true)"
  latest="$(servarr_latest_version "$name" "$branch" || true)"

  if [[ -z "$latest" ]]; then log "WARN ${name}: could not determine latest version, skipping"; return 1; fi
  if [[ -z "$cur" ]]; then log "WARN ${name}: could not determine installed version, skipping"; return 1; fi
  if [[ "$cur" == "$latest" ]]; then log "${name} already up to date (${cur})"; return 0; fi

  log "==> ${name}: ${cur} -> ${latest}"
  backup_now "servarr-${name}" "$install_dir" "$data_dir" || { log "ERROR ${name}: backup failed"; return 1; }

  url="$(servarr_download_url "$name" "$branch")"
  tarball="$WORK_DIR/${name}.tar.gz"
  tmpdir="$WORK_DIR/${name}-extract"
  mkdir -p "$tmpdir"

  log "Downloading ${name}..."
  curl -fsSL -o "$tarball" "$url" || { log "ERROR ${name}: download failed"; return 1; }
  tar -xzf "$tarball" -C "$tmpdir" || { log "ERROR ${name}: extraction failed"; return 1; }
  [[ -x "$tmpdir/${name}/${name}" ]] || { log "ERROR ${name}: binary not found in archive"; return 1; }

  systemctl stop "$lower" 2>/dev/null || true
  if ! rm -rf "$install_dir" || ! mv "$tmpdir/${name}" "$install_dir"; then
    log "ERROR ${name}: deploy failed - rolling back"
    restore_backup "$CURRENT_BACKUP" "$install_dir" "$data_dir" || true
    systemctl start "$lower" 2>/dev/null || true
    return 1
  fi
  chown -R "${MEDIASVC_USER}:${MEDIANAS_GROUP}" "$install_dir" 2>/dev/null || true
  systemctl start "$lower" 2>/dev/null || true

  if servarr_health "$name" "$data_dir" "$latest"; then
    log "${name} updated to ${latest} and healthy"
    return 0
  fi

  log "ERROR ${name}: health check failed - rolling back to ${cur}"
  systemctl stop "$lower" 2>/dev/null || true
  restore_backup "$CURRENT_BACKUP" "$install_dir" "$data_dir" || true
  chown -R "${MEDIASVC_USER}:${MEDIANAS_GROUP}" "$install_dir" "$data_dir" 2>/dev/null || true
  systemctl start "$lower" 2>/dev/null || true
  servarr_health "$name" "$data_dir" "$cur" || log "WARN ${name}: still unhealthy after rollback"
  return 1
}

update_servarr() {
  local entry failed=0
  for entry in "${SERVARR_APPS[@]}"; do
    update_servarr_app "$entry" || failed=1
  done
  return "$failed"
}

# ---------- qBITTORRENT ------------------------------------------------------
qbit_health() {
  local i
  for ((i = 1; i <= HEALTH_RETRIES; i++)); do
    if systemctl is-active --quiet qbittorrent-nox \
       && curl -fsS --max-time 5 "http://${VETH_NS_IP}:${QBIT_WEBUI_PORT}/" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$HEALTH_DELAY"
  done
  return 1
}

update_qbittorrent() {
  command -v qbittorrent-nox >/dev/null 2>&1 || { log "SKIP qBittorrent: not installed"; return 0; }

  local installed candidate
  installed="$(dpkg-query -W -f='${Version}' qbittorrent-nox 2>/dev/null || true)"
  apt-get update -qq || true
  candidate="$(apt-cache policy qbittorrent-nox 2>/dev/null | awk '/Candidate:/{print $2}' | head -n1)"

  if [[ -z "$installed" || -z "$candidate" || "$candidate" == "(none)" ]]; then
    log "WARN qBittorrent: could not determine versions (installed='${installed}' candidate='${candidate}'), skipping"
    return 1
  fi
  if ! dpkg --compare-versions "$candidate" gt "$installed"; then
    log "qBittorrent already up to date (${installed})"
    return 0
  fi

  log "==> qBittorrent: ${installed} -> ${candidate}"
  local was_active=0
  systemctl is-active --quiet qbittorrent-nox && was_active=1 || true
  if [[ -d "$QBIT_CONFIG_DIR" ]]; then
    backup_now "qBittorrent" "$QBIT_CONFIG_DIR" || { log "ERROR qBittorrent: backup failed"; return 1; }
  else
    log "NOTE qBittorrent: no config dir at ${QBIT_CONFIG_DIR}, skipping backup"
  fi

  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade qbittorrent-nox; then
    log "ERROR qBittorrent: apt upgrade failed"
    return 1
  fi

  # Respect the P2P on/off switch: only (re)start + health-check if it was running.
  if [[ "$was_active" != 1 ]]; then
    log "qBittorrent updated to ${candidate}; service was stopped (P2P off) - leaving it stopped"
    return 0
  fi

  systemctl restart qbittorrent-nox 2>/dev/null || systemctl start qbittorrent-nox 2>/dev/null || true
  if qbit_health; then
    log "qBittorrent updated to ${candidate} and healthy"
    return 0
  fi

  log "ERROR qBittorrent: health check failed - attempting rollback"
  systemctl stop qbittorrent-nox 2>/dev/null || true
  if [[ -n "$CURRENT_BACKUP" ]]; then
    restore_backup "$CURRENT_BACKUP" "$QBIT_CONFIG_DIR" || true
    chown -R qbtuser:"${MEDIANAS_GROUP}" "$QBIT_CONFIG_DIR" 2>/dev/null || true
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades "qbittorrent-nox=${installed}" 2>/dev/null \
    || log "WARN qBittorrent: could not downgrade binary (old .deb unavailable); config restored"
  systemctl start vpn-netns 2>/dev/null || true
  systemctl start qbittorrent-nox 2>/dev/null || true
  return 1
}

# ---------- HOMARR -----------------------------------------------------------
homarr_build() {
  local dir="$1"
  (
    cd "$dir"
    pnpm install --frozen-lockfile && pnpm build && pnpm db:migration:sqlite:run
  ) >>"$LOG_FILE" 2>&1
}

# Re-resolve the next/tsx binaries and rewrite the unit ExecStart lines so a
# rebuild cannot leave the installer's units pointing at a stale workspace path.
homarr_fix_units() {
  local next_bin tsx_bin f
  next_bin="$(find /opt/homarr -maxdepth 6 -type l -path '*/.bin/next' 2>/dev/null | head -n1 || true)"
  if [[ -z "$next_bin" ]]; then
    next_bin="$(cd /opt/homarr/apps/nextjs 2>/dev/null && pnpm exec which next 2>/dev/null || true)"
  fi
  tsx_bin="$(find /opt/homarr -maxdepth 6 -type l -path '*/.bin/tsx' 2>/dev/null | head -n1 || true)"
  if [[ -z "$tsx_bin" ]]; then
    tsx_bin="$(cd /opt/homarr/apps/websocket 2>/dev/null && pnpm exec which tsx 2>/dev/null || true)"
  fi
  if [[ -z "$next_bin" || -z "$tsx_bin" ]]; then
    log "WARN Homarr: could not resolve next/tsx binaries; leaving units unchanged"
    return 1
  fi
  f=/etc/systemd/system/homarr-nextjs.service
  [[ -f "$f" ]] && sed -i "s|^ExecStart=.*|ExecStart=${next_bin} start -p 3000|" "$f"
  f=/etc/systemd/system/homarr-websocket.service
  [[ -f "$f" ]] && sed -i "s|^ExecStart=.*|ExecStart=${tsx_bin} /opt/homarr/apps/websocket/src/main.ts|" "$f"
  f=/etc/systemd/system/homarr-tasks.service
  [[ -f "$f" ]] && sed -i "s|^ExecStart=.*|ExecStart=${tsx_bin} /opt/homarr/apps/tasks/src/main.ts|" "$f"
  return 0
}

homarr_health() {
  local i
  for ((i = 1; i <= HEALTH_RETRIES; i++)); do
    if systemctl is-active --quiet homarr-nextjs \
       && { curl -fsSL --max-time 5 "$HOMARR_HEALTH_URL" >/dev/null 2>&1 \
            || curl -fsSL --max-time 5 "http://127.0.0.1:3000/" >/dev/null 2>&1; }; then
      return 0
    fi
    sleep "$HEALTH_DELAY"
  done
  return 1
}

homarr_start() { systemctl daemon-reload; systemctl start "${HOMARR_UNITS[@]}" 2>/dev/null || true; }
homarr_stop()  { systemctl stop "${HOMARR_UNITS[@]}" 2>/dev/null || true; }

update_homarr() {
  local dir="$HOMARR_DIR" data="$HOMARR_DATA_DIR" current latest current_major latest_major target bp

  [[ -d "$dir/.git" ]] || { log "SKIP Homarr: not installed at ${dir}"; return 0; }
  command -v pnpm >/dev/null 2>&1 || { log "ERROR Homarr: pnpm not found"; return 1; }

  log "==> Homarr: fetching tags..."
  git_dir "$dir" fetch --tags --quiet || { log "ERROR Homarr: git fetch failed"; return 1; }

  current="$(git_dir "$dir" describe --tags --abbrev=0 2>/dev/null || true)"
  [[ -n "$current" ]] || { log "WARN Homarr: cannot determine installed tag"; return 1; }
  latest="$(git_dir "$dir" tag --sort=v:refname | tail -n1)"
  current_major="$(echo "$current" | sed -E 's/^v?([0-9]+).*/\1/')"
  latest_major="$(echo "$latest" | sed -E 's/^v?([0-9]+).*/\1/')"
  target="$latest"

  if [[ "$latest_major" != "$current_major" ]]; then
    if prompt_yes "Homarr major upgrade ${current} -> ${latest} detected. Major releases may change architecture/build tooling. Continue?"; then
      target="$latest"
    else
      target="$(git_dir "$dir" tag --list "v${current_major}.*" --sort=v:refname | tail -n1)"
      log "Staying on major v${current_major}: target ${target}"
    fi
  fi
  [[ -n "$target" ]] || { log "WARN Homarr: no target tag found"; return 1; }
  [[ "$target" == "$current" ]] && { log "Homarr already up to date (${current})"; return 0; }

  log "==> Homarr: ${current} -> ${target}"
  bp=("$data"); [[ -f "$dir/.env" ]] && bp+=("$dir/.env")
  backup_now "Homarr" "${bp[@]}" || { log "ERROR Homarr: backup failed"; return 1; }

  homarr_stop
  if ! git_dir "$dir" checkout --quiet "$target"; then
    log "ERROR Homarr: checkout ${target} failed"
    homarr_start
    return 1
  fi

  if ! homarr_build "$dir"; then
    log "ERROR Homarr: build failed - rolling back to ${current}"
    git_dir "$dir" checkout --quiet "$current" 2>/dev/null || true
    restore_backup "$CURRENT_BACKUP" "$data" || true
    homarr_build "$dir" || true
    homarr_fix_units || true
    chown -R "${MEDIASVC_USER}:${MEDIANAS_GROUP}" "$dir" "$data" 2>/dev/null || true
    homarr_start
    return 1
  fi

  homarr_fix_units || true
  chown -R "${MEDIASVC_USER}:${MEDIANAS_GROUP}" "$dir" "$data" 2>/dev/null || true
  homarr_start

  if homarr_health; then
    log "Homarr updated to ${target} and healthy"
    return 0
  fi

  log "ERROR Homarr: health check failed - rolling back to ${current}"
  homarr_stop
  git_dir "$dir" checkout --quiet "$current" 2>/dev/null || true
  restore_backup "$CURRENT_BACKUP" "$data" || true
  homarr_build "$dir" || true
  homarr_fix_units || true
  chown -R "${MEDIASVC_USER}:${MEDIANAS_GROUP}" "$dir" "$data" 2>/dev/null || true
  homarr_start
  return 1
}

# ---------- SEERR ------------------------------------------------------------
seerr_build() {
  local dir="$1"
  (
    export PATH="${PNPM10_DIR}/bin:${NODE22_DIR}/bin:${PATH}"
    export CYPRESS_INSTALL_BINARY=0
    cd "$dir"
    pnpm install --frozen-lockfile && pnpm build
  ) >>"$LOG_FILE" 2>&1
}

seerr_health() {
  local i
  for ((i = 1; i <= HEALTH_RETRIES; i++)); do
    if systemctl is-active --quiet seerr \
       && { curl -fsSL --max-time 5 "$SEERR_HEALTH_URL" >/dev/null 2>&1 \
            || curl -fsSL --max-time 5 "http://127.0.0.1:5055/api/v1/settings/public" >/dev/null 2>&1; }; then
      return 0
    fi
    sleep "$HEALTH_DELAY"
  done
  return 1
}

update_seerr() {
  local dir="$SEERR_DIR" cur latest bp

  [[ -d "$dir/.git" ]] || { log "SKIP Seerr: not installed at ${dir}"; return 0; }
  [[ -x "${NODE22_DIR}/bin/node" && -x "${PNPM10_DIR}/bin/pnpm" ]] \
    || { log "ERROR Seerr: embedded Node 22 / pnpm 10 not found (${NODE22_DIR}, ${PNPM10_DIR})"; return 1; }

  git_dir "$dir" fetch --quiet origin "$SEERR_BRANCH" || { log "ERROR Seerr: git fetch failed"; return 1; }
  cur="$(git_dir "$dir" rev-parse HEAD)"
  latest="$(git_dir "$dir" rev-parse "origin/${SEERR_BRANCH}")"
  if [[ "$cur" == "$latest" ]]; then
    log "Seerr already up to date ($(git_dir "$dir" rev-parse --short HEAD))"
    return 0
  fi

  log "==> Seerr: $(git_dir "$dir" rev-parse --short HEAD) -> $(git_dir "$dir" rev-parse --short "origin/${SEERR_BRANCH}")"
  bp=()
  [[ -d "$dir/config" ]] && bp+=("$dir/config")
  [[ -f "$dir/.env" ]] && bp+=("$dir/.env")
  if [[ ${#bp[@]} -gt 0 ]]; then
    backup_now "Seerr" "${bp[@]}" || { log "ERROR Seerr: backup failed"; return 1; }
  else
    log "NOTE Seerr: no config/.env to back up"
  fi

  systemctl stop seerr 2>/dev/null || true
  if ! git_dir "$dir" checkout --quiet "$SEERR_BRANCH" || ! git_dir "$dir" pull --ff-only --quiet; then
    log "ERROR Seerr: update checkout failed"
    systemctl start seerr 2>/dev/null || true
    return 1
  fi

  if ! seerr_build "$dir"; then
    log "ERROR Seerr: build failed - rolling back"
    git_dir "$dir" checkout --quiet "$cur" 2>/dev/null || true
    restore_backup "$CURRENT_BACKUP" "$dir/config" || true
    seerr_build "$dir" || true
    chown -R "${MEDIASVC_USER}:${MEDIANAS_GROUP}" "$dir" 2>/dev/null || true
    systemctl start seerr 2>/dev/null || true
    return 1
  fi

  chown -R "${MEDIASVC_USER}:${MEDIANAS_GROUP}" "$dir" 2>/dev/null || true
  systemctl start seerr 2>/dev/null || true

  if seerr_health; then
    log "Seerr updated and healthy"
    return 0
  fi

  log "ERROR Seerr: health check failed - rolling back"
  systemctl stop seerr 2>/dev/null || true
  git_dir "$dir" checkout --quiet "$cur" 2>/dev/null || true
  restore_backup "$CURRENT_BACKUP" "$dir/config" || true
  seerr_build "$dir" || true
  chown -R "${MEDIASVC_USER}:${MEDIANAS_GROUP}" "$dir" 2>/dev/null || true
  systemctl start seerr 2>/dev/null || true
  return 1
}

# ---------- BYPARR (pull-only, no backup) ------------------------------------
byparr_health() {
  local i
  for ((i = 1; i <= HEALTH_RETRIES; i++)); do
    if systemctl is-active --quiet "$BYPARR_SERVICE" \
       && curl -fsSL --max-time 5 "$BYPARR_HEALTH_URL" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$HEALTH_DELAY"
  done
  return 1
}

update_byparr() {
  local dir="$BYPARR_DIR"
  [[ -d "$dir/.git" ]] || { log "ERROR Byparr: no git repo at ${dir} (pull-only, never install)"; return 1; }

  log "==> Byparr: pulling ${dir}"
  if ! git_dir "$dir" pull --ff-only origin "$BYPARR_BRANCH"; then
    log "ERROR Byparr: git pull failed"
    return 1
  fi

  log "Restarting ${BYPARR_SERVICE}..."
  systemctl restart "$BYPARR_SERVICE" 2>/dev/null || { log "ERROR Byparr: could not restart ${BYPARR_SERVICE}"; return 1; }

  if byparr_health; then
    log "Byparr restarted and healthy"
    return 0
  fi
  log "ERROR Byparr: health check failed"
  return 1
}

# ---------- ENTRY POINT ------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [--servarr] [--qBittorrent] [--Homarr] [--Seerr] [--Byparr]

Flags are combinable. With no flag, this help is shown and nothing is done.

  --servarr      Prowlarr, Radarr, Sonarr, Lidarr, Whisparr (backup + health + rollback)
  --qBittorrent  qBittorrent-nox via apt (backup + health + rollback)
  --Homarr       Homarr via git tag + pnpm build (backup + health + rollback;
                 prompts before a major version jump)
  --Seerr        Seerr via git ${SEERR_BRANCH} + pnpm build (backup + health + rollback)
  --Byparr       git pull ${BYPARR_DIR} + restart ${BYPARR_SERVICE} (no backup)
  -h, --help     Show this help

Backups: ${BACKUP_DIR}/<app>/ (newest ${KEEP_BACKUPS} kept per app)
Log:     ${LOG_FILE}
EOF
}

main() {
  if [[ $# -eq 0 ]]; then usage; exit 0; fi

  local do_servarr=0 do_qbit=0 do_homarr=0 do_seerr=0 do_byparr=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --servarr)                do_servarr=1 ;;
      --qBittorrent|--qbittorrent) do_qbit=1 ;;
      --Homarr|--homarr)        do_homarr=1 ;;
      --Seerr|--seerr)          do_seerr=1 ;;
      --Byparr|--byparr)        do_byparr=1 ;;
      -h|--help)                usage; exit 0 ;;
      *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
    shift
  done

  require_root
  ensure_deps
  detect_arch
  WORK_DIR="$(mktemp -d /var/tmp/arr-stack-updater.XXXXXX)"
  log "=== *arr stack update started (arch=${SERVARR_ARCH}) ==="

  local failed=0
  if [[ "$do_servarr" == 1 ]]; then update_servarr || failed=1; fi
  if [[ "$do_qbit" == 1 ]]; then update_qbittorrent || failed=1; fi
  if [[ "$do_homarr" == 1 ]]; then update_homarr || failed=1; fi
  if [[ "$do_seerr" == 1 ]]; then update_seerr || failed=1; fi
  if [[ "$do_byparr" == 1 ]]; then update_byparr || failed=1; fi

  if [[ "$failed" == 1 ]]; then
    log "=== *arr stack update finished WITH ERRORS ==="
    exit 1
  fi
  log "=== *arr stack update finished successfully ==="
}

main "$@"
