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

# Public URL written into config.yml. Replace with your real server address.
PUBLIC_URL="http://<your-server-ip>:3456/"

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

# Installs jq if it's missing, since get_asset_url relies on it
check_jq() {
    command -v jq >/dev/null 2>&1 && return 0

    log INFO "jq not found, installing it"
    if [[ $EUID -ne 0 ]]; then
        log ERROR "jq is required. Install it with: sudo apt install jq"
        exit 1
    fi

    apt-get update -y && apt-get install -y jq || { log ERROR "Failed to install jq"; exit 1; }
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

# Returns 0 (true) if version $1 is strictly greater than version $2
version_gt() {
    [[ "$1" == "$2" ]] && return 1
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]
}

# Finds the release asset URL for the given architecture via the GitHub API
get_asset_url() {
    local arch="$1"
    curl -fsSL "$GITHUB_API_URL" \
        | jq -r --arg arch "$arch" \
            '.assets[] | select(.name | test("^vikunja-.*-linux-" + $arch + "-full\\.zip$")) | .browser_download_url' \
        | head -n1
}


# Downloads and unpacks a release, prints the path it was extracted to
download_release() {
    local arch="$1"
    local dir; dir="$(mktemp -d)"

    local url; url="$(get_asset_url "$arch")"
    [[ -n "$url" ]] || { log ERROR "No release asset found for architecture $arch"; return 1; }
    local file; file="$(basename "$url")"

    log INFO "Downloading $url"
    curl -fsSL -o "$dir/$file" "$url" || { log ERROR "Download failed: $url"; return 1; }

  
    unzip -oq "$dir/$file" -d "$dir/extracted" || { log ERROR "Extraction failed: $file"; return 1; }

    # Vikunja releases sometimes ship their contents inside a single subfolder instead of flat in the zip. If "extracted" only contains one folder, that's the actual content root.
    local root="$dir/extracted"
    local entries=("$root"/*)
    if [[ ${#entries[@]} -eq 1 && -d "${entries[0]}" ]]; then
        root="${entries[0]}"
    fi

    # The binary is usually named "vikunja-vX.Y.Z-linux-<arch>" instead of plain "vikunja". Find it by pattern and create a canonical "vikunja" copy so the rest of the script can keep referencing a fixed name.
    local binary
    binary="$(find "$root" -maxdepth 1 -type f -name "vikunja-v*-linux-${arch}*" | head -n1)"
    [[ -n "$binary" ]] || { log ERROR "vikunja binary not found after extraction"; return 1; }
    cp -f "$binary" "$root/vikunja"
    chmod +x "$root/vikunja"

    echo "$root"
}

write_config() {
    log INFO "Writing $CONFIG_FILE"
    cat > "$CONFIG_FILE" <<EOF
service:
  publicurl: "$PUBLIC_URL"            
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

# writes the systemd service file for Vikunja
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
    source="$(download_release "$arch")" || return 1

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

# Checking the Github api for a newer version, if there's one we're trying to auto update it
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
 
    if ! version_gt "$latest" "$current"; then
        log ERROR "Installed version ($current) is not older than latest release ($latest), skipping update"
        return 1
    fi
 
    log INFO "Updating $current -> $latest"
    source="$(download_release "$(detect_arch)")" || return 1
 
    systemctl stop vikunja
    # Alr we're backing it uo here
    cp -f "$INSTALL_DIR/vikunja" "$INSTALL_DIR/vikunja.bak.$current"
    cp -f "$source/vikunja" "$INSTALL_DIR/vikunja"
    chmod +x "$INSTALL_DIR/vikunja"
    echo "$latest" > "$VERSION_FILE"
 
    systemctl start vikunja || { log ERROR "Failed to start Vikunja after update"; return 1; }
    log INFO "Updated to $latest"
}

# We don't test the mailing functionality of virkunja here, we're just checking that the smtp credentials are correct and that we're able to send mails from this device.
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

check_jq

for arg in "$@"; do
    case "$arg" in
        --install)   install_vikunja ;;
        --update)    update_vikunja ;;
        --test-mail) test_mail ;;
        *)           echo "Unknown option: $arg"; exit 1 ;;
    esac
done