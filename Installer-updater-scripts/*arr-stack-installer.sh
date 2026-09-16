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

# ---------- CONFIGURATION (edit these) -------------------------------------
NAS_PATH="/mnt/nas/media"          # Existing NAS mount, ONE shared area
WG_CONF_SRC="/root/vpn.conf"       # Any standard WireGuard .conf from ANY provider
LAN_SUBNET="192.168.0.0/24"        # Your home network, adjust if different
WEBHOOK_PORT=9000

# Fixed internal addressing for the private host<->namespace link (not your LAN).
# Change only if 10.200.200.0/30 collides with something you already use.
NS_NAME="vpnns"
VETH_HOST_IP="10.200.200.1/30"
VETH_NS_IP="10.200.200.2"

# ---------- PRE-FLIGHT CHECKS ----------------------------------------------
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

# ---------- NAS FOLDER STRUCTURE + SHARED GROUP ----------------------------
echo "==> Creating NAS folder structure..."
# Downloads AND finished media live in the SAME share -> required for hardlinks.
mkdir -p "$NAS_PATH"/{downloads/incomplete,downloads/complete,movies,tv,music,books}

# qBittorrent (user qbtuser) writes the downloaded files. Radarr/Sonarr/etc.
# (user mediasvc) then need to read those same files to create a hardlink into movies/tv/etc. 
# Two different Linux users writing/reading the same NAS folder only works cleanly if both belong to one shared group that owns the folder,
# with the setgid bit so new files/folders automatically inherit that group.
groupadd -f medianas
chgrp -R medianas "$NAS_PATH"
chmod -R 2775 "$NAS_PATH"

# ---------- SERVICE USERS ---------------------------------------------------
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

# ---------- VPN NETWORK NAMESPACE (the actual killswitch) ------------------
# Design: qBittorrent runs inside its own network namespace that contains NOTHING but loopback and the WireGuard interface. 
# There is no default route to anywhere else - not because a firewall rule forbids it, but because no such path physically exists in that namespace.
# If the tunnel goes down, qBittorrent has zero interfaces left to send a single packet through.
#
# Management access (WebUI, Radarr/Sonarr talking to qBittorrent's API) goes through a private point-to-point veth link between the host and the
# namespace - this is NOT your LAN, it's an isolated /30 that only connects the host to this one namespace.
# Only ONE narrow, explicit port-forward (WebUI port 8080) bridges it to your LAN, so outside access is possible
# but auditable and minimal - very different from "allow the whole LAN out".
echo "==> Setting up the isolated VPN network namespace..."

cp "$WG_CONF_SRC" /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/wg0.conf

# Extract the provider's DNS server (works for ANY WireGuard provider, since they all use the same standard "DNS = x.x.x.x" line) and force ALL DNS lookups made inside the namespace through it.
# Since the namespace's only route out is the tunnel, DNS queries fail closed if the VPN is down -
# exactly what protects against leaking which sites/trackers we're resolving.
WG_DNS=$(grep -iE '^\s*DNS\s*=' /etc/wireguard/wg0.conf | head -n1 | awk -F'=' '{print $2}' | cut -d',' -f1 | tr -d ' \t')
[[ -n "$WG_DNS" ]] || WG_DNS="9.9.9.9"
mkdir -p /etc/netns/${NS_NAME}
echo "nameserver ${WG_DNS}" > /etc/netns/${NS_NAME}/resolv.conf
# Remove the DNS line from wg0.conf itself - wg-quick's own resolvconf hook
# isn't namespace-aware and would otherwise fight with the override above.
sed -i '/^\s*DNS\s*=/Id' /etc/wireguard/wg0.conf

# Extract the provider's Endpoint. In a brand-new namespace there is NO route to
# it yet, so wg-quick's initial handshake would be unroutable. We add a specific
# host-route (in up.sh below) that lets ONLY the Endpoint IP reach the host; every
# other packet still routes through the tunnel, so this stays leak-proof.
WG_ENDPOINT=$(grep -iE '^\s*Endpoint\s*=' /etc/wireguard/wg0.conf | head -n1 | sed -E 's/^[[:space:]]*[Ee]ndpoint[[:space:]]*=[[:space:]]*//; s/[[:space:]]*$//')
[[ -n "$WG_ENDPOINT" ]] || { echo "ERROR: No Endpoint line found in $WG_CONF_SRC."; exit 1; }
WG_ENDPOINT_IP=${WG_ENDPOINT%:*}
WG_ENDPOINT_IP=${WG_ENDPOINT_IP#[}
WG_ENDPOINT_IP=${WG_ENDPOINT_IP%]}
if [[ "$WG_ENDPOINT_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  :
elif [[ "$WG_ENDPOINT_IP" =~ ^[0-9a-fA-F:]+$ ]]; then
  echo "ERROR: IPv6 WireGuard Endpoints are not supported by this script ($WG_ENDPOINT_IP)." >&2; exit 1
else
  WG_ENDPOINT_IP=$(getent ahostsv4 "$WG_ENDPOINT_IP" | awk 'NR==1{print $1}' || true)
  [[ -n "$WG_ENDPOINT_IP" ]] || { echo "ERROR: Cannot resolve Endpoint host '$WG_ENDPOINT'." >&2; exit 1; }
fi

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

# Host forwarding must be on BEFORE the handshake - the namespace reaches the
# provider's Endpoint only by hopping through the host.
sysctl -w net.ipv4.ip_forward=1 >/dev/null

# Bootstrap host-route: ONLY the VPN Endpoint IP may leave the namespace via the
# host (handshake packets). No default route through the host exists in this
# namespace - that is exactly what keeps it leak-proof if the tunnel drops.
ip netns exec ${NS_NAME} ip route add ${WG_ENDPOINT_IP}/32 via ${VETH_HOST_IP%/*} dev veth-ns

# Bring the tunnel up INSIDE the namespace - this becomes its only route out.
ip netns exec ${NS_NAME} wg-quick up wg0

# Route LAN return-traffic back through the host so the forwarded WebUI works
# (without this, replies to LAN clients would exit via the tunnel instead of
# coming back through the veth link).
ip netns exec ${NS_NAME} ip route replace ${LAN_SUBNET} via ${VETH_HOST_IP%/*} dev veth-ns

# One narrow port-forward so LAN devices can reach the WebUI at the machine's
# normal IP. Restricted to your LAN subnet as the source, on purpose.
iptables -t nat -A PREROUTING -s ${LAN_SUBNET} -p tcp --dport 8080 -j DNAT --to-destination ${VETH_NS_IP}:8080
# Everything forwarded INTO the namespace (WebUI forwards + WireGuard handshake replies).
iptables -A FORWARD -o veth-host -d ${VETH_NS_IP} -j ACCEPT
# Namespace -> LAN: only replies to established flows (the forwarded WebUI).
iptables -A FORWARD -i veth-host -s ${VETH_NS_IP} -d ${LAN_SUBNET} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# Explicitly block any NEW namespace -> LAN connections (belt and braces).
iptables -A FORWARD -i veth-host -s ${VETH_NS_IP} -d ${LAN_SUBNET} -m conntrack --ctstate NEW -j DROP
EOF

cat > /opt/vpn-netns/down.sh <<EOF
#!/usr/bin/env bash
iptables -t nat -D PREROUTING -s ${LAN_SUBNET} -p tcp --dport 8080 -j DNAT --to-destination ${VETH_NS_IP}:8080 2>/dev/null || true
iptables -D FORWARD -o veth-host -d ${VETH_NS_IP} -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i veth-host -s ${VETH_NS_IP} -d ${LAN_SUBNET} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i veth-host -s ${VETH_NS_IP} -d ${LAN_SUBNET} -m conntrack --ctstate NEW -j DROP 2>/dev/null || true
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

# ---------- qBITTORRENT-NOX (runs entirely inside the namespace) -----------
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

# ---------- THE *ARR STACK (self-contained .NET releases) ------------------
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

# ---------- NODE.JS (shared by Seerr + Homarr) ------------------------------
echo "==> Installing Node.js 24..."
if ! command -v node >/dev/null || [[ "$(node -v | grep -oE '^v[0-9]+' | tr -d v)" -lt 24 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_24.x | bash - >/dev/null
  apt-get install -y nodejs >/dev/null
fi
npm install -g pnpm@10.30.3 --silent

# ---------- SEERR ------------
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

# ---------- HOMARR DASHBOARD ------------------------------------------------
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

# ---------- P2P SWITCH (webhook, strict on/off ordering) ------------------
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

# ---------- VPN EGRESS STATUS PAGE (Homarr widget) --------------------------
# Serves a tiny self-refreshing page + status.json showing the qBittorrent
# namespace's current egress IP / city / country (with Mullvad exit confirmation
# when the tunnel egresses Mullvad). In Homarr add it as an "Embed" widget.
echo "==> Setting up VPN status page (for Homarr)..."
mkdir -p /opt/vpn-netns/www

cat > /opt/vpn-netns/status.sh <<EOF
#!/usr/bin/env bash
set -e
ip netns exec ${NS_NAME} curl -fsSL --max-time 10 https://am.i.mullvad.net/json \\
  -o /tmp/vpn-status.json 2>/dev/null || echo '{}' > /tmp/vpn-status.json
[ -s /tmp/vpn-status.json ] || echo '{}' > /tmp/vpn-status.json
mv -f /tmp/vpn-status.json /opt/vpn-netns/www/status.json
EOF
chmod +x /opt/vpn-netns/status.sh

cat > /opt/vpn-netns/www/index.html <<'EOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>VPN egress</title>
<style>
  body{font-family:system-ui,sans-serif;background:#111;color:#eee;display:flex;justify-content:center;align-items:center;min-height:100vh;margin:0}
  .card{background:#1c1c1e;border:1px solid #333;border-radius:10px;padding:24px 32px;min-width:280px}
  h1{font-size:16px;margin:0 0 14px;color:#9aa}
  .row{display:flex;justify-content:space-between;gap:24px;padding:6px 0;border-bottom:1px solid #2a2a2c}
  .row:last-child{border:none}
  .k{color:#777}.v{font-weight:600}
  .ok{color:#4ade80}.bad{color:#f87171}
</style>
</head>
<body>
<div class="card">
  <h1>VPN egress (qBittorrent)</h1>
  <div class="row"><span class="k">IP</span><span class="v" id="ip">-</span></div>
  <div class="row"><span class="k">City</span><span class="v" id="city">-</span></div>
  <div class="row"><span class="k">Country</span><span class="v" id="country">-</span></div>
  <div class="row"><span class="k">Provider</span><span class="v" id="org">-</span></div>
  <div class="row"><span class="k">Mullvad exit</span><span class="v" id="mullvad">-</span></div>
</div>
<script>
async function refresh(){
  try{
    const r=await fetch('status.json',{cache:'no-store'});
    const d=await r.json();
    document.getElementById('ip').textContent=d.ip||'unreachable';
    document.getElementById('city').textContent=d.city||'-';
    document.getElementById('country').textContent=d.country||'-';
    document.getElementById('org').textContent=d.organization||'-';
    const ok=d.mullvad_exit_ip===true;
    const m=document.getElementById('mullvad');
    m.textContent=ok?'YES':'no';
    m.className='v '+(ok?'ok':'bad');
  }catch(e){ document.getElementById('ip').textContent='no data'; }
}
refresh();
setInterval(refresh,30000);
</script>
</body>
</html>
EOF

cat > /etc/systemd/system/vpn-status.service <<EOF
[Unit]
Description=Refresh VPN egress status.json (Homarr widget)
After=vpn-netns.service

[Service]
Type=oneshot
ExecStart=/opt/vpn-netns/status.sh
EOF

cat > /etc/systemd/system/vpn-status.timer <<EOF
[Unit]
Description=Refresh VPN egress status every 2 minutes

[Timer]
OnBootSec=30s
OnUnitActiveSec=2min
Unit=vpn-status.service

[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/vpn-status-web.service <<EOF
[Unit]
Description=Serves the VPN egress page for the Homarr embed widget
After=network.target

[Service]
Type=simple
ExecStart=$(command -v python3) -m http.server 8855 --bind 0.0.0.0 --directory /opt/vpn-netns/www
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now vpn-status.timer vpn-status-web >/dev/null
/opt/vpn-netns/status.sh

# ---------- START THE VPN + SUMMARY ----------------------------------------
systemctl start vpn-netns
sleep 2
systemctl start qbittorrent-nox

# ---------- POST-INSTALL LEAK CHECK (plus Mullvad egress info) -------------
echo "==> Verifying VPN egress (kill-switch check)..."
for _ in $(seq 1 15); do
  ip netns exec ${NS_NAME} wg show wg0 latest-handshakes 2>/dev/null | grep -qv $'\t0' && break
  sleep 1
done

# am.i.mullvad.net/json reports IP + city + country for ANY VPN provider, and
# confirms the Mullvad exit-IP + server when the tunnel actually egresses Mullvad.
HOST_WAN=$(curl -fsSL --max-time 15 https://am.i.mullvad.net/json 2>/dev/null | jq -c '{ip: .ip, city: .city, country: .country, mullvad: (.mullvad_exit_ip == true)}' || true)
NS_WAN=$(ip netns exec ${NS_NAME} curl -fsSL --max-time 15 https://am.i.mullvad.net/json 2>/dev/null | jq -c '{ip: .ip, city: .city, country: .country, mullvad: (.mullvad_exit_ip == true), server: .server_hostname}' || true)

NS_IP=$(jq -r '.ip // "unreachable"' <<<"${NS_WAN:-{\"ip\":null}}" 2>/dev/null || echo "unreachable")
HOST_IP_WAN=$(jq -r '.ip // "unreachable"' <<<"${HOST_WAN:-{\"ip\":null}}" 2>/dev/null || echo "unreachable")

if [[ -n "$NS_IP" && "$NS_IP" != "unreachable" && "$NS_IP" != "$HOST_IP_WAN" ]]; then
  echo "OK: No IP leak. Namespace egress IP = ${NS_IP} (host = ${HOST_IP_WAN})."
  echo "    VPN location : $(jq -r '"\(.city), \(.country)"' <<<"${NS_WAN}" 2>/dev/null)"
  if jq -e '.mullvad' <<<"${NS_WAN}" >/dev/null 2>&1; then
    echo "    Mullvad     : confirmed exit IP ${NS_IP} - server $(jq -r '.server // "unknown"' <<<"${NS_WAN}")"
  else
    echo "    Mullvad     : not detected (fine if your provider is not Mullvad)."
  fi
else
  echo "!!! LEAK-CHECK FAILED: namespace egress = ${NS_IP}, host egress = ${HOST_IP_WAN}." >&2
  echo "!!! Do NOT trust this setup until the VPN tunnel is confirmed working." >&2
  exit 1
fi

PI_IP=$(hostname -I | awk '{print $1}')
cat <<SUMMARY

==================================================================
 Installation complete (100% native, no Docker).

 qBittorrent WebUI  : http://${PI_IP}:8080   (from the Pi itself: http://${VETH_NS_IP}:8080)
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

 VPN status widget (in Homarr: add an "Embed" widget with this URL):
   URL: http://${PI_IP}:8855        (raw JSON: http://${PI_IP}:8855/status.json)

 Killswitch test (do this before trusting the setup):
   sudo systemctl stop vpn-netns
   -> qbittorrent-nox must also be stopped (BindsTo)
   sudo systemctl start qbittorrent-nox   # try to force-start it anyway
   -> it will start, but has literally no interface to reach the internet with,
      since its whole network namespace disappeared along with the tunnel.

 See README.md for the remaining manual configuration steps.
==================================================================
SUMMARY