#!/usr/bin/env bash
# ==============================================================================
#  Native media-stack installer (NO DOCKER)
#  Assumes: Jellyfin already installed, NAS already mounted.
#
#  Stack: any WireGuard VPN + qBittorrent-nox (network-namespace isolated)
#         + Prowlarr + Radarr + Sonarr + Lidarr + Readarr + Whisparr
#         + Seerr (Jellyseerr's actively maintained successor) + Homarr
#         + a tiny webhook for a safe P2P on/off switch
# ==============================================================================
set -euo pipefail

# ---------- 1. CONFIGURATION (edit these) -------------------------------------
NAS_PATH="/mnt/nas/media"          # Existing NAS mount, ONE shared area
WG_CONF_SRC="/root/vpn.conf"       # Any standard WireGuard .conf from ANY provider
LAN_SUBNET="192.168.0.0/24"        # Your home network, adjust if different
WEBHOOK_PORT=9000

# Fixed internal addressing for the private host<->namespace link (not your LAN).
# Change only if 10.200.200.0/30 collides with something you already use.
NS_NAME="vpnns"
VETH_HOST_IP="10.200.200.1/30"
VETH_NS_IP="10.200.200.2"

# ---------- 2. PRE-FLIGHT CHECKS ----------------------------------------------
[[ $EUID -eq 0 ]] || { echo "Please run as root."; exit 1; }
[[ -d "$NAS_PATH" ]] || { echo "ERROR: $NAS_PATH does not exist."; exit 1; }
[[ -f "$WG_CONF_SRC" ]] || { echo "ERROR: WireGuard config not found at $WG_CONF_SRC.
Export a standard WireGuard client .conf from your VPN provider and copy it there
(any provider works: Mullvad, ProtonVPN, IVPN, AirVPN, a self-hosted server, ...)."; exit 1; }

case "$(uname -m)" in
  aarch64) SERVARR_ARCH=arm64 ;;
  armv7l)  SERVARR_ARCH=arm   ;;
  x86_64)  SERVARR_ARCH=x64   ;;
  *) echo "Unsupported architecture."; exit 1 ;;
esac

echo "==> Installing base packages..."
apt-get update -qq
apt-get install -y wireguard-tools iproute2 iptables curl git jq openssl \
  ca-certificates build-essential python3 make g++ qbittorrent-nox >/dev/null

# ---------- 3. NAS FOLDER STRUCTURE + SHARED GROUP ----------------------------
echo "==> Creating NAS folder structure..."
# Downloads AND finished media live in the SAME share -> required for hardlinks.
mkdir -p "$NAS_PATH"/{downloads/incomplete,downloads/complete,movies,tv,music,books}

# WHY a shared group ("medianas")?
# qBittorrent (user qbtuser) writes the downloaded files. Radarr/Sonarr/etc.
# (user mediasvc) then need to read those same files to create a hardlink into
# movies/tv/etc. Two different Linux users writing/reading the same NAS folder
# only works cleanly if both belong to one shared group that owns the folder,
# with the setgid bit so new files/folders automatically inherit that group.
groupadd -f medianas
chgrp -R medianas "$NAS_PATH"
chmod -R 2775 "$NAS_PATH"

# ---------- 4. SERVICE USERS ---------------------------------------------------
# qbtuser  : isolated, unprivileged, no login - runs ONLY qBittorrent.
#            This user's process is placed in its own network namespace (below),
#            so isolation here is about *filesystem* permissions, not networking.
# mediasvc : ONE shared, unprivileged, no-login account for every other service
#            (Prowlarr/Radarr/Sonarr/Lidarr/Readarr/Whisparr/Seerr/Homarr).
#            These services don't need to be isolated from each other - only
#            qBittorrent's P2P traffic does - so one shared account keeps user
#            management simple instead of creating six near-identical accounts.
id -u qbtuser  &>/dev/null || useradd --system --create-home --shell /usr/sbin/nologin qbtuser
id -u mediasvc &>/dev/null || useradd --system --create-home --shell /usr/sbin/nologin mediasvc
usermod -aG medianas qbtuser
usermod -aG medianas mediasvc

# ---------- 5. VPN NETWORK NAMESPACE (the actual killswitch) ------------------
# Design: qBittorrent runs inside its own network namespace that contains
# NOTHING but loopback and the WireGuard interface. There is no default route
# to anywhere else - not because a firewall rule forbids it, but because no
# such path physically exists in that namespace. If the tunnel goes down,
# qBittorrent has zero interfaces left to send a single packet through.
#
# Management access (WebUI, Radarr/Sonarr talking to qBittorrent's API) goes
# through a private point-to-point veth link between the host and the
# namespace - this is NOT your LAN, it's an isolated /30 that only connects
# the host to this one namespace. Only ONE narrow, explicit port-forward
# (WebUI port 8080) bridges it to your LAN, so outside access is possible
# but auditable and minimal - very different from "allow the whole LAN out".
echo "==> Setting up the isolated VPN network namespace..."

cp "$WG_CONF_SRC" /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/wg0.conf

# Extract the provider's DNS server (works for ANY WireGuard provider, since
# they all use the same standard "DNS = x.x.x.x" line) and force ALL DNS
# lookups made inside the namespace through it. Since the namespace's only
# route out is the tunnel, DNS queries fail closed if the VPN is down -
# exactly what protects against leaking which sites/trackers you're resolving.
WG_DNS=$(grep -iE '^\s*DNS\s*=' /etc/wireguard/wg0.conf | head -n1 | awk -F'=' '{print $2}' | cut -d',' -f1 | tr -d ' \t')
[[ -n "$WG_DNS" ]] || WG_DNS="9.9.9.9"
mkdir -p /etc/netns/${NS_NAME}
echo "nameserver ${WG_DNS}" > /etc/netns/${NS_NAME}/resolv.conf
# Remove the DNS line from wg0.conf itself - wg-quick's own resolvconf hook
# isn't namespace-aware and would otherwise fight with the override above.
sed -i '/^\s*DNS\s*=/Id' /etc/wireguard/wg0.conf

mkdir -p /opt/vpn-netns
cat > /opt/vpn-netns/up.sh <<EOF
#!/usr/bin/env bash
set -e
ip netns add ${NS_NAME} 2>/dev/null || true
ip netns exec ${NS_NAME} ip link set lo up

ip link add veth-host type veth peer name veth-ns 2>/dev/null || true
ip link set veth-ns netns ${NS_NAME}
ip addr add ${VETH_HOST_IP} dev veth-host 2>/dev/null || true
ip link set veth-host up
ip netns exec ${NS_NAME} ip addr add ${VETH_NS_IP}/30 dev veth-ns 2>/dev/null || true
ip netns exec ${NS_NAME} ip link set veth-ns up

# Bring the tunnel up INSIDE the namespace - this becomes its only route out.
ip netns exec ${NS_NAME} wg-quick up wg0

# One narrow port-forward so LAN devices can reach the WebUI at the Pi's
# normal IP. Restricted to your LAN subnet as the source, on purpose.
sysctl -w net.ipv4.ip_forward=1 >/dev/null
iptables -t nat -A PREROUTING -s ${LAN_SUBNET} -p tcp --dport 8080 -j DNAT --to-destination ${VETH_NS_IP}:8080
iptables -A FORWARD -d ${VETH_NS_IP} -p tcp --dport 8080 -j ACCEPT
EOF

cat > /opt/vpn-netns/down.sh <<EOF
#!/usr/bin/env bash
iptables -t nat -D PREROUTING -s ${LAN_SUBNET} -p tcp --dport 8080 -j DNAT --to-destination ${VETH_NS_IP}:8080 2>/dev/null || true
iptables -D FORWARD -d ${VETH_NS_IP} -p tcp --dport 8080 -j ACCEPT 2>/dev/null || true
ip netns exec ${NS_NAME} wg-quick down wg0 2>/dev/null || true
ip link del veth-host 2>/dev/null || true
ip netns del ${NS_NAME} 2>/dev/null || true
EOF
chmod +x /opt/vpn-netns/up.sh /opt/vpn-netns/down.sh

cat > /etc/systemd/system/vpn-netns.service <<EOF
[Unit]
Description=Isolated network namespace for the VPN tunnel (provider-agnostic WireGuard)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/vpn-netns/up.sh
ExecStop=/opt/vpn-netns/down.sh

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable vpn-netns >/dev/null

# ---------- 6. qBITTORRENT-NOX (runs entirely inside the namespace) -----------
echo "==> Configuring qBittorrent..."
mkdir -p /home/qbtuser/.config/qBittorrent
cat > /home/qbtuser/.config/qBittorrent/qBittorrent.conf <<EOF
[Preferences]
WebUI\\Port=8080
WebUI\\Address=0.0.0.0

[BitTorrent]
Session\\DefaultSavePath=${NAS_PATH}/downloads/complete
Session\\TempPath=${NAS_PATH}/downloads/incomplete
Session\\TempPathEnabled=true
EOF
chown -R qbtuser:medianas /home/qbtuser

cat > /etc/systemd/system/qbittorrent-nox.service <<EOF
[Unit]
Description=qBittorrent-nox (isolated network namespace - no path to the internet other than the VPN tunnel exists)
Requires=vpn-netns.service
After=vpn-netns.service
BindsTo=vpn-netns.service

[Service]
User=qbtuser
Group=medianas
NetworkNamespacePath=/run/netns/${NS_NAME}
BindReadOnlyPaths=/etc/netns/${NS_NAME}/resolv.conf:/etc/resolv.conf
ExecStart=/usr/bin/qbittorrent-nox --webui-port=8080
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable qbittorrent-nox >/dev/null

# ---------- 7. THE *ARR STACK (self-contained .NET releases) ------------------
install_servarr() {
  local name="$1" branch="$2"
  local lower; lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')
  echo "==> Installing ${name}..."
  curl -fsSL -o "/tmp/${name}.tar.gz" \
    "https://${lower}.servarr.com/v1/update/${branch}/updatefile?os=linux&runtime=netcore&arch=${SERVARR_ARCH}"
  tar -xzf "/tmp/${name}.tar.gz" -C /opt
  mkdir -p "/opt/${name}-data"
  chown -R mediasvc:medianas "/opt/${name}" "/opt/${name}-data"

  cat > "/etc/systemd/system/${lower}.service" <<EOF
[Unit]
Description=${name} Daemon
After=network.target

[Service]
User=mediasvc
Group=medianas
Type=simple
ExecStart=/opt/${name}/${name} -nobrowser -data=/opt/${name}-data
Restart=on-failure
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "${lower}" >/dev/null
}
install_servarr Prowlarr master
install_servarr Radarr master
install_servarr Sonarr master
install_servarr Lidarr master
install_servarr Readarr master
install_servarr Whisparr nightly   # adult-content automation; branch differs from the others

# ---------- 8. NODE.JS (shared by Seerr + Homarr) ------------------------------
echo "==> Installing Node.js 24..."
if ! command -v node >/dev/null || [[ "$(node -v | grep -oE '^v[0-9]+' | tr -d v)" -lt 24 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_24.x | bash - >/dev/null
  apt-get install -y nodejs >/dev/null
fi
npm install -g pnpm@10.30.3 --silent

# ---------- 9. SEERR (actively maintained successor to Jellyseerr) ------------
echo "==> Installing Seerr..."
mkdir -p /opt/seerr
git clone --quiet https://github.com/seerr-team/seerr.git /opt/seerr 2>/dev/null || true
cd /opt/seerr && git checkout --quiet main
CYPRESS_INSTALL_BINARY=0 pnpm install --frozen-lockfile --silent
pnpm build
chown -R mediasvc:medianas /opt/seerr

mkdir -p /etc/seerr
echo "PORT=5055" > /etc/seerr/seerr.conf

cat > /etc/systemd/system/seerr.service <<EOF
[Unit]
Description=Seerr Service
Wants=network-online.target
After=network-online.target

[Service]
User=mediasvc
Group=medianas
EnvironmentFile=/etc/seerr/seerr.conf
Environment=NODE_ENV=production
Type=exec
Restart=on-failure
WorkingDirectory=/opt/seerr
ExecStart=$(command -v node) dist/index.js

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now seerr >/dev/null

# ---------- 10. HOMARR DASHBOARD ------------------------------------------------
echo "==> Installing Homarr..."
mkdir -p /opt/homarr
git clone --quiet https://github.com/homarr-labs/homarr.git /opt/homarr 2>/dev/null || true
cd /opt/homarr && git checkout --quiet "$(git tag --sort=v:refname | tail -n1)"
pnpm install --frozen-lockfile --silent

mkdir -p /opt/homarr-data/{db,redis,trusted-certificates}
SECRET_KEY=$(openssl rand -hex 32)
cat > /opt/homarr/.env <<EOF
SECRET_ENCRYPTION_KEY=${SECRET_KEY}
DB_DRIVER=better-sqlite3
DB_URL=/opt/homarr-data/db/db.sqlite
LOG_LEVEL=info
AUTH_PROVIDERS=credentials
TURBO_TELEMETRY_DISABLED=1
EOF

pnpm build
pnpm db:migration:sqlite:run
chown -R mediasvc:medianas /opt/homarr /opt/homarr-data

for svc in nextjs websocket tasks; do
  case "$svc" in
    nextjs)    exec_path="/opt/homarr/apps/nextjs/server.js" ;;
    websocket) exec_path="/opt/homarr/apps/websocket/wssServer.cjs" ;;
    tasks)     exec_path="/opt/homarr/apps/tasks/tasks.cjs" ;;
  esac
  cat > "/etc/systemd/system/homarr-${svc}.service" <<EOF
[Unit]
Description=Homarr ${svc}
After=network.target

[Service]
Type=simple
User=mediasvc
Group=medianas
WorkingDirectory=$(dirname "$exec_path")
Environment=NODE_ENV=production
EnvironmentFile=/opt/homarr/.env
ExecStart=$(command -v node) ${exec_path}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
done
systemctl daemon-reload
systemctl enable --now homarr-nextjs homarr-websocket homarr-tasks >/dev/null

# ---------- 11. P2P SWITCH (webhook, strict on/off ordering) ------------------
echo "==> Setting up the P2P switch..."
mkdir -p /opt/webhook
WEBHOOK_TOKEN=$(openssl rand -hex 20)

cat > /opt/webhook/p2p-on.sh <<EOF
#!/usr/bin/env bash
# Order: VPN namespace FIRST, then qBittorrent.
set -e
systemctl start vpn-netns
for i in \$(seq 1 15); do
  ip netns exec ${NS_NAME} wg show wg0 latest-handshakes 2>/dev/null | grep -qv \$'\t0' && break
  sleep 1
done
systemctl start qbittorrent-nox
EOF

cat > /opt/webhook/p2p-off.sh <<'EOF'
#!/usr/bin/env bash
# Order: qBittorrent FIRST, then the VPN namespace (leak-proof shutdown order).
set -e
systemctl stop qbittorrent-nox
systemctl stop vpn-netns
EOF
chmod +x /opt/webhook/p2p-*.sh

cat > /opt/webhook/hooks.json <<EOF
[
  { "id": "p2p-on",  "execute-command": "/opt/webhook/p2p-on.sh",
    "trigger-rule": { "match": { "type": "value", "value": "${WEBHOOK_TOKEN}",
      "parameter": { "source": "url", "name": "token" } } } },
  { "id": "p2p-off", "execute-command": "/opt/webhook/p2p-off.sh",
    "trigger-rule": { "match": { "type": "value", "value": "${WEBHOOK_TOKEN}",
      "parameter": { "source": "url", "name": "token" } } } }
]
EOF

apt-get install -y webhook >/dev/null
cat > /etc/systemd/system/p2p-webhook.service <<EOF
[Unit]
Description=P2P on/off switch (used by the Homarr dashboard)
After=network.target

[Service]
ExecStart=/usr/bin/webhook -hooks /opt/webhook/hooks.json -ip 0.0.0.0 -port ${WEBHOOK_PORT} -verbose
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now p2p-webhook >/dev/null

# ---------- 12. START THE VPN + SUMMARY ----------------------------------------
systemctl start vpn-netns
sleep 2
systemctl start qbittorrent-nox

PI_IP=$(hostname -I | awk '{print $1}')
cat <<SUMMARY

==================================================================
 Installation complete (100% native, no Docker).

 qBittorrent WebUI : http://${PI_IP}:8080   (from the Pi itself: http://${VETH_NS_IP}:8080)
 Prowlarr           : http://${PI_IP}:9696
 Radarr             : http://${PI_IP}:7878
 Sonarr             : http://${PI_IP}:8989
 Lidarr             : http://${PI_IP}:8686
 Readarr            : http://${PI_IP}:8787
 Whisparr           : http://${PI_IP}:6969
 Seerr              : http://${PI_IP}:5055
 Homarr             : http://${PI_IP}:3000

 P2P switch:
   ON : http://${PI_IP}:${WEBHOOK_PORT}/hooks/p2p-on?token=${WEBHOOK_TOKEN}
   OFF: http://${PI_IP}:${WEBHOOK_PORT}/hooks/p2p-off?token=${WEBHOOK_TOKEN}
 (token also saved in /opt/webhook/hooks.json)

 Killswitch test (do this before trusting the setup):
   sudo systemctl stop vpn-netns
   -> qbittorrent-nox must also be stopped (BindsTo)
   sudo systemctl start qbittorrent-nox   # try to force-start it anyway
   -> it will start, but has literally no interface to reach the internet with,
      since its whole network namespace disappeared along with the tunnel.

 See README.md for the remaining manual configuration steps.
==================================================================
SUMMARY