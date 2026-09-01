#!/bin/sh

# ==============================================================================
# PocketBase Installer for Alpine Linux (diskless/RAM mode + OpenRC)
# ==============================================================================

set -eu

# --- Colors -------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { printf '%b\n' "${BLUE}==>${NC} $1"; }
success() { printf '%b\n' "${GREEN}==>${NC} $1"; }
warn()    { printf '%b\n' "${YELLOW}Warning:${NC} $1" >&2; }
die()     { printf '%b\n' "${RED}Error:${NC} $1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "This installer must be executed as root."

# --- Settings -------------------------------------------------------------
# No reverse proxy / no TLS on this host -> keep PocketBase LAN-only.
# 0.0.0.0 is only safe if this VM's interface itself is not internet-facing.
PB_BIND_ADDR="0.0.0.0"    # <-- WARNING: LAN-only assumption, do not expose!
PB_PORT="8090"
BIN_DIR="/opt/pocketbase"
DATA_DIR="/var/lib/pocketbase/pb_data"
LOG_DIR="/var/log/pocketbase"

echo "=== PocketBase Installer (Alpine diskless, OpenRC) ==="

# --- 0. Idempotency check ---------------------------------------------------
if [ -x "${BIN_DIR}/pocketbase" ] || [ -f /etc/init.d/pocketbase ]; then
    die "PocketBase already appears to be installed. This script does not overwrite an existing install."
fi

# --- 1. Dependencies --------------------------------------------------------
info "Installing system dependencies..."
apk add --no-cache curl unzip jq ca-certificates >/dev/null

# --- 2. Architecture detection ----------------------------------------------
ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
    x86_64|amd64)      PB_ARCH="amd64" ;;
    aarch64|arm64)     PB_ARCH="arm64" ;;
    armv7l|armv6l|arm) PB_ARCH="armv7" ;;
    *) die "Unsupported architecture: $ARCH_RAW (PocketBase only ships amd64/arm64/armv7 linux builds)." ;;
esac
info "Detected ${ARCH_RAW} -> PocketBase build: linux_${PB_ARCH}"

# --- 3. Dedicated system user and group -------------------------------------
info "Creating system user and group (pocketbase)..."
NOLOGIN_SHELL="/sbin/nologin"; [ -x "$NOLOGIN_SHELL" ] || NOLOGIN_SHELL="/bin/false"
getent group pocketbase >/dev/null 2>&1 || addgroup -S pocketbase
getent passwd pocketbase >/dev/null 2>&1 || \
    adduser -S -G pocketbase -H -h "$DATA_DIR" -s "$NOLOGIN_SHELL" pocketbase

# --- 4. Directories ----------------------------------------------------------
info "Setting up directories..."
mkdir -p "$BIN_DIR" "$DATA_DIR" "$LOG_DIR"

# --- 5. Latest stable version via GitHub API ---------------------------------
info "Querying GitHub API for the latest stable PocketBase release..."
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

API_URL="https://api.github.com/repos/pocketbase/pocketbase/releases/latest"
API_RESPONSE="$(curl -fsSL -H "User-Agent: pocketbase-alpine-installer" "$API_URL")" \
    || die "Failed to reach GitHub API. Check network connectivity."
echo "$API_RESPONSE" | jq -e '.message' >/dev/null 2>&1 && \
    die "GitHub API error: $(echo "$API_RESPONSE" | jq -r '.message') (often a rate limit)."

PB_TAG="$(echo "$API_RESPONSE" | jq -r '.tag_name // empty')"
[ -n "$PB_TAG" ] || die "Could not determine the latest PocketBase version."
PB_VERSION="${PB_TAG#v}"
ASSET_NAME="pocketbase_${PB_VERSION}_linux_${PB_ARCH}.zip"
BASE_URL="https://github.com/pocketbase/pocketbase/releases/download/${PB_TAG}"
info "Latest stable version: ${PB_TAG}"

# --- 6. Download, verify checksum, unpack ------------------------------------
info "Downloading ${ASSET_NAME}..."
curl -fsSL "${BASE_URL}/${ASSET_NAME}" -o "$TMP_DIR/pocketbase.zip" \
    || die "Failed to download ${ASSET_NAME} (asset missing for this arch/version?)."

# PocketBase releases ship a checksums.txt file - verify against it if present.
if curl -fsSL "${BASE_URL}/checksums.txt" -o "$TMP_DIR/checksums.txt" 2>/dev/null; then
    EXPECTED_SUM="$(grep " ${ASSET_NAME}\$" "$TMP_DIR/checksums.txt" | awk '{print $1}')"
    ACTUAL_SUM="$(sha256sum "$TMP_DIR/pocketbase.zip" | awk '{print $1}')"
    if [ -z "$EXPECTED_SUM" ]; then
        warn "No checksum entry found for ${ASSET_NAME} - skipping verification."
    elif [ "$EXPECTED_SUM" != "$ACTUAL_SUM" ]; then
        die "Checksum mismatch for ${ASSET_NAME}!"
    else
        success "Checksum OK (sha256)."
    fi
else
    warn "checksums.txt not found for this release - skipping verification."
fi

unzip -q "$TMP_DIR/pocketbase.zip" -d "$TMP_DIR"
[ -f "$TMP_DIR/pocketbase" ] || die "Downloaded archive did not contain the expected 'pocketbase' binary."
mv "$TMP_DIR/pocketbase" "${BIN_DIR}/pocketbase"
chmod 755 "${BIN_DIR}/pocketbase"

# --- 7. Permissions -----------------------------------------------------------
info "Applying file permissions..."
chown -R pocketbase:pocketbase "$BIN_DIR" "$(dirname "$DATA_DIR")" "$LOG_DIR"
chmod 750 "$(dirname "$DATA_DIR")" "$LOG_DIR"

# --- 8. OpenRC config + service -----------------------------------------------
info "Writing /etc/conf.d/pocketbase and /etc/init.d/pocketbase..."
cat << EOF > /etc/conf.d/pocketbase
pocketbase_bind="${PB_BIND_ADDR}"
pocketbase_port="${PB_PORT}"
pocketbase_data_dir="${DATA_DIR}"
EOF

cat << 'EOF' > /etc/init.d/pocketbase
#!/sbin/openrc-run
name="pocketbase"
description="PocketBase - Open Source realtime backend"
: "${pocketbase_bind:=127.0.0.1}"
: "${pocketbase_port:=8090}"
: "${pocketbase_data_dir:=/var/lib/pocketbase/pb_data}"
command="/opt/pocketbase/pocketbase"
command_args="serve --http=${pocketbase_bind}:${pocketbase_port} --dir=${pocketbase_data_dir}"
command_user="pocketbase:pocketbase"
# supervise-daemon: OpenRC's built-in process supervisor, respawns on crash.
# This is a fixed OpenRC keyword, not a name we chose.
supervisor="supervise-daemon"
pidfile="/run/pocketbase.pid"
supervise_daemon_args="--stdout /var/log/pocketbase/output.log --stderr /var/log/pocketbase/error.log"
depend() {
    need net
    after firewall
}
EOF

chmod +x /etc/init.d/pocketbase
rc-update add pocketbase default >/dev/null

# --- 9. Start service, grab one-time setup link ------------------------------
info "Starting PocketBase service..."
rc-service pocketbase start >/dev/null

# PocketBase prints a one-time superuser setup link to its error log on first
# start (same idea as Stalwart's bootstrap block) - wait up to ~15s for it.
SETUP_LINE=""
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    SETUP_LINE="$(grep -i 'pbinstal' /var/log/pocketbase/error.log 2>/dev/null || true)"
    [ -n "$SETUP_LINE" ] && break
    sleep 1
done

echo ""
if rc-service pocketbase status 2>/dev/null | grep -q started; then
    success "=== INSTALLATION COMPLETED SUCCESSFULLY ==="
else
    warn "PocketBase service does not appear to be running. Check: rc-service pocketbase status"
fi
printf 'Version:        %s\nBind address:   %s:%s  (LAN only - no TLS, no reverse proxy)\nData directory: %s\n\n' \
    "$PB_TAG" "$PB_BIND_ADDR" "$PB_PORT" "$DATA_DIR"
if [ -n "$SETUP_LINE" ]; then
    printf '%b\n' "${YELLOW}First-time superuser setup link (one-time, from log):${NC}"
    echo "$SETUP_LINE"
else
    echo "Could not extract the setup link. Inspect manually: tail -n 30 /var/log/pocketbase/error.log"
fi

# --- 10. lbu persistence check ------------------------------------------------
echo ""
warn "This is a diskless/RAM Alpine VM. Without 'lbu commit', everything above (binary, service, and especially ${DATA_DIR}) is LOST on reboot!"
for p in "$BIN_DIR" "$DATA_DIR" "$LOG_DIR" /etc/init.d/pocketbase /etc/conf.d/pocketbase; do
    lbu include "$p" 2>/dev/null || true
done
info "Included in lbu: ${BIN_DIR}, ${DATA_DIR}, ${LOG_DIR}, /etc/init.d/pocketbase, /etc/conf.d/pocketbase"

if [ -t 0 ]; then
    printf '%b' "${YELLOW}Run 'lbu commit' now to persist this installation? [y/N]: ${NC}"
    read -r ANSWER
    case "$ANSWER" in
        [Yy]*) lbu commit && success "lbu commit completed." || warn "lbu commit failed - please run it manually." ;;
        *) warn "Skipped - remember to run 'lbu commit' before rebooting." ;;
    esac
else
    warn "Non-interactive session - run 'lbu commit' manually before rebooting."
fi