#!/usr/bin/env bash
#
# virkunja-Installer-Updater.sh
#
# Install, update, and test-mail script for a self-hosted Vikunja instance.
# Checks the GitHub Releases API for the current version instead of using
# a hardcoded download URL, and only updates when a newer version exists.
#
# Usage:
#   sudo ./virkunja-Installer-Updater.sh --install
#   sudo ./virkunja-Installer-Updater.sh --update
#        ./virkunja-Installer-Updater.sh --test-mail

# ! There should be a automatic backup of the binary when updating is choosen, 
# ! even if it's only meant to run only manually I think I will need more time restoring than for Implementing this functionality

set -uo pipefail

# =============================================================================
# Configuration
# =============================================================================

INSTALL_DIR="/opt/vikunja"
CONFIG_FILE="$INSTALL_DIR/config.yml"
VERSION_FILE="$INSTALL_DIR/.installed_version"
SERVICE_FILE="/etc/systemd/system/vikunja.service"
BIN_LINK="/usr/bin/vikunja"
LOG_FILE="/var/log/virkunja-installer-updater.log"

GITHUB_API_URL="https://api.github.com/repos/go-vikunja/vikunja/releases/latest"

# Mail settings used in config.yml and for --test-mail.l
# Replace these example values with your real ones.
MAIL_HOST="smtp.example.com"
MAIL_PORT="587"
MAIL_USERNAME="user@example.com"
MAIL_PASSWORD="changeme"
MAIL_FROM="user@example.com"

# =============================================================================
# Functions
# =============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2" | tee -a "$LOG_FILE" >&2
}

detect_arch() {
    case "$(uname -m)" in
        x86_64)    echo "amd64" ;;
        aarch64)   echo "arm64" ;;
        armv7l)    echo "arm-7" ;;
        armv6l)    echo "arm-6" ;;
        *)         log ERROR "Unsupported architecture: $(uname -m)"; exit 1 ;;
    esac
}

# Prints the latest release tag (e.g. "v2.6.0") from the GitHub API
get_latest_version() {
    local response
    response="$(curl -fsSL "$GITHUB_API_URL")" || { log ERROR "GitHub API request failed"; return 1; }

    local version
    version="$(echo "$response" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"

    if [[ -z "$version" ]]; then
        log ERROR "Could not read version from GitHub API response"
        return 1
    fi
    echo "$version"
}

get_installed_version() {
    [[ -f "$VERSION_FILE" ]] && cat "$VERSION_FILE" || echo "none"
}

# Downloads and unpacks a release, prints the path it was extracted to
download_release() {
    local version="$1" arch="$2"
    local file="vikunja-${version}-linux-${arch}-full.zip"
    local url="https://dl.vikunja.io/vikunja/${version}/${file}"
    local dir; dir="$(mktemp -d)"

    log INFO "Downloading $url"
    curl -fsSL -o "$dir/$file" "$url" || { log ERROR "Download failed: $url"; return 1; }

    unzip -oq "$dir/$file" -d "$dir/extracted" || { log ERROR "Extraction failed: $file"; return 1; }
    echo "$dir/extracted"
}

write_config() {
    log INFO "Writing $CONFIG_FILE"
    cat > "$CONFIG_FILE" <<EOF
service:

    # ! Review that before using, Ig that should be a variable at the top, to coonfigure it at one single place
  publicurl: "http://<your-server-ip>:3456/"            
  secret: "$(head -c32 /dev/urandom | base64)"

mailer:
  enabled: true
  host: "$MAIL_HOST"
  port: $MAIL_PORT
  username: "$MAIL_USERNAME"
  password: "$MAIL_PASSWORD"
  fromemail: "$MAIL_FROM"
EOF
}

write_service_file() {
    log INFO "Writing $SERVICE_FILE"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Vikunja
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$BIN_LINK
Restart=always
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF
}

install_vikunja() {
    [[ $EUID -eq 0 ]] || { log ERROR "Run with sudo"; exit 1; }
    [[ -x "$BIN_LINK" ]] && { log WARN "Already installed, use --update instead"; return 1; }

    local version arch source
    version="$(get_latest_version)" || return 1
    arch="$(detect_arch)"
    source="$(download_release "$version" "$arch")" || return 1

    mkdir -p "$INSTALL_DIR"
    cp -r "$source"/. "$INSTALL_DIR"/
    chmod +x "$INSTALL_DIR/vikunja"
    ln -sf "$INSTALL_DIR/vikunja" "$BIN_LINK"
    echo "$version" > "$VERSION_FILE"

    [[ -f "$CONFIG_FILE" ]] || write_config
    write_service_file

    systemctl daemon-reload
    systemctl enable --now vikunja || { log ERROR "Failed to start Vikunja"; return 1; }

    log INFO "Installed Vikunja $version"
}

update_vikunja() {
    [[ $EUID -eq 0 ]] || { log ERROR "Run with sudo"; exit 1; }
    [[ -x "$BIN_LINK" ]] || { log ERROR "Not installed, use --install first"; return 1; }

    local current latest source
    current="$(get_installed_version)"
    latest="$(get_latest_version)" || return 1

    if [[ "$current" == "$latest" ]]; then
        log INFO "Already up to date ($current)"
        return 0
    fi

    log INFO "Updating $current -> $latest"
    source="$(download_release "$latest" "$(detect_arch)")" || return 1

    systemctl stop vikunja
    cp -f "$INSTALL_DIR/vikunja" "$INSTALL_DIR/vikunja.bak.$current"
    cp -f "$source/vikunja" "$INSTALL_DIR/vikunja"
    chmod +x "$INSTALL_DIR/vikunja"
    echo "$latest" > "$VERSION_FILE"

    systemctl start vikunja || { log ERROR "Failed to start Vikunja after update"; return 1; }
    log INFO "Updated to $latest"
}

test_mail() {
    read -r -p "Send test mail to: " recipient
    [[ -n "$recipient" ]] || { log ERROR "No recipient given"; return 1; }

    local mail_file; mail_file="$(mktemp)"
    printf 'From: %s\nTo: %s\nSubject: Vikunja mail test\n\nThis is a test email.\n' \
        "$MAIL_FROM" "$recipient" > "$mail_file"

    if curl -fsS --ssl-reqd "smtp://${MAIL_HOST}:${MAIL_PORT}" \
        --mail-from "$MAIL_FROM" --mail-rcpt "$recipient" \
        --user "${MAIL_USERNAME}:${MAIL_PASSWORD}" --upload-file "$mail_file"; then
        log INFO "Test mail sent to $recipient"
    else
        log ERROR "Sending test mail failed"
    fi
    rm -f "$mail_file"
}

# =============================================================================
# Main
# =============================================================================

[[ $# -eq 0 ]] && { echo "Usage: $0 [--install] [--update] [--test-mail]"; exit 1; }

for arg in "$@"; do
    case "$arg" in
        --install)   install_vikunja ;;
        --update)    update_vikunja ;;
        --test-mail) test_mail ;;
        *)           echo "Unknown option: $arg"; exit 1 ;;
    esac
done