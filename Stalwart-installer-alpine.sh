#!/bin/sh

# ==============================================================================
# Stalwart Mail Server Installer for Alpine Linux (bootstrap + OpenRC)
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

# --- Root check -----------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    die "This installer must be executed as root."
fi

echo "=== Stalwart Mail Server Installer ==="
echo "Target Backend: SQLite (bootstrap wizard)"
echo "Target Init:    OpenRC"
echo ""

# --- 1. Dependencies --------------------------------------------------------
info "Installing system dependencies..."
apk add --no-cache curl wget tar ca-certificates libcap >/dev/null

# --- 2. Architecture detection ----------------------------------------------
ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
    x86_64|amd64)
        STALWART_ARCH="x86_64-unknown-linux-musl"
        ;;
    aarch64|arm64)
        STALWART_ARCH="aarch64-unknown-linux-musl"
        ;;
    *)
        die "Unsupported architecture: $ARCH_RAW"
        ;;
esac

# --- 3. Dedicated system user and group -------------------------------------
info "Creating system user and group (stalwart)..."
NOLOGIN_SHELL="/sbin/nologin"
[ -x "$NOLOGIN_SHELL" ] || NOLOGIN_SHELL="/bin/false"

if ! getent group stalwart >/dev/null 2>&1; then
    addgroup -S stalwart
fi
if ! getent passwd stalwart >/dev/null 2>&1; then
    adduser -S -G stalwart -H -h /var/lib/stalwart -s "$NOLOGIN_SHELL" stalwart
fi

# --- 4. Directory structure --------------------------------------------------
info "Setting up directories..."
mkdir -p /etc/stalwart
mkdir -p /var/lib/stalwart/data
mkdir -p /var/log/stalwart

# --- 5. Download the musl-static binary from the latest GitHub release ------
info "Fetching latest musl static binary from GitHub (arch: ${STALWART_ARCH})..."

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT INT TERM

ASSET="stalwart-${STALWART_ARCH}.tar.gz"
DOWNLOAD_URL="https://github.com/stalwartlabs/stalwart/releases/latest/download/${ASSET}"

if ! wget -q "$DOWNLOAD_URL" -O "$TMP_DIR/stalwart.tar.gz"; then
    die "Failed to download $DOWNLOAD_URL (release asset missing or network unreachable)."
fi

tar -xzf "$TMP_DIR/stalwart.tar.gz" -C "$TMP_DIR"

if [ ! -f "$TMP_DIR/stalwart" ]; then
    die "Downloaded archive did not contain the expected 'stalwart' binary."
fi

mv "$TMP_DIR/stalwart" /usr/local/bin/stalwart
chmod 755 /usr/local/bin/stalwart

# Allow binding privileged ports (25, 465, 587, ...) without running as root
setcap 'cap_net_bind_service=+ep' /usr/local/bin/stalwart || \
    warn "setcap failed - binding to ports < 1024 will require running as root."

# --- 6. Permissions -----------------------------------------------------------
info "Applying file permissions..."
chown -R stalwart:stalwart /etc/stalwart
chown -R stalwart:stalwart /var/lib/stalwart
chown -R stalwart:stalwart /var/log/stalwart
chmod 750 /etc/stalwart
chmod 750 /var/lib/stalwart
chmod 750 /var/log/stalwart

# NOTE: We deliberately do NOT pre-create /etc/stalwart/config.json.
# When Stalwart is started without a config.json, it starts in "bootstrap
# mode", listens on :8080 and serves a setup wizard that lets you choose
# the SQLite backend and writes a valid config.json itself. Hand-writing
# this file is fragile because the schema changes between releases.

# --- 7. OpenRC service ---------------------------------------------------------
info "Generating OpenRC service script..."
cat << 'EOF' > /etc/init.d/stalwart
#!/sbin/openrc-run

description="Stalwart Mail & Collaboration Server"
command="/usr/local/bin/stalwart"
command_args="--config /etc/stalwart/config.json"
command_user="stalwart:stalwart"
command_background=true
pidfile="/run/stalwart.pid"
output_log="/var/log/stalwart/output.log"
error_log="/var/log/stalwart/error.log"

depend() {
    need net
    after firewall
}
EOF

chmod +x /etc/init.d/stalwart
rc-update add stalwart default >/dev/null

# --- 8. Start the service ---------------------------------------------------
info "Starting Stalwart service..."
rc-service stalwart start >/dev/null

# Wait (up to ~15s) for the bootstrap credentials to appear in the log
ADMIN_BLOCK=""
i=0
while [ "$i" -lt 15 ]; do
    if [ -f /var/log/stalwart/error.log ] && \
       ADMIN_BLOCK="$(grep -A8 -i 'bootstrap mode' /var/log/stalwart/error.log 2>/dev/null || true)" && \
       [ -n "$ADMIN_BLOCK" ]; then
        break
    fi
    sleep 1
    i=$((i + 1))
done

echo ""
if rc-service stalwart status 2>/dev/null | grep -q started; then
    success "=== INSTALLATION COMPLETED SUCCESSFULLY ==="
else
    warn "Stalwart service does not appear to be running. Check: rc-service stalwart status"
fi

SERVER_IP="$(hostname -i 2>/dev/null | awk '{print $1}')"
[ -n "$SERVER_IP" ] || SERVER_IP="<your-server-ip>"

echo "Bootstrap Setup Wizard (first run only):"
echo "http://${SERVER_IP}:8080/admin"
echo ""

if [ -n "$ADMIN_BLOCK" ]; then
    printf '%b\n' "${YELLOW}Temporary administrator setup credentials:${NC}"
    echo "$ADMIN_BLOCK"
else
    echo "Could not automatically extract bootstrap credentials."
    echo "Inspect the log manually:"
    echo "  tail -n 30 /var/log/stalwart/error.log"
fi
echo ""
echo "Once you complete the setup wizard, Stalwart writes /etc/stalwart/config.json,"
echo "creates the permanent admin account and restarts into normal operation."
echo ""