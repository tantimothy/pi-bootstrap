#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ACTION="${1:-list}"

[ -f "$SCRIPT_DIR/.env" ] && { set -a; source "$SCRIPT_DIR/.env"; set +a; }

: "${GRAFANA_PORT:=3030}"
: "${PIHOLE_WEB_PORT:=80}"
: "${DARKSTAT_PORT:=667}"
: "${UPTIME_KUMA_PORT:=3001}"
: "${WG_UI_PORT:=51821}"
: "${WG_PORT:=51820}"

# Resolve the host's LAN IP so these URLs are actually usable from another
# device — "localhost" only means something on the Pi's own terminal.
HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
[ -z "$HOST_IP" ] && HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$HOST_IP" ] && HOST_IP="localhost"

DATA_DIRS=("$SCRIPT_DIR/etc-pihole" "$SCRIPT_DIR/etc-wireguard" "$SCRIPT_DIR/darkstat-db")
DATA_DESCRIPTIONS=(
    "Pi-hole config, gravity database, custom blocklists, local DNS records"
    "WireGuard server keys + all peer configs — losing this invalidates every client VPN"
    "darkstat traffic database — per-host bandwidth history"
)
INSTALL_DIRS=(); INSTALL_DESCRIPTIONS=()
NAMED_VOLUMES=("prometheus_data" "grafana_data" "uptime_kuma_data")
NAMED_VOLUME_DESCRIPTIONS=(
    "Prometheus time-series metrics (peer transfer stats, Pi-hole query history)"
    "Grafana database — saved dashboards, alert rules, user preferences"
    "Uptime Kuma database — all monitors, notification channels, incident history"
)
DATA_DIRS_LABEL="📁 Persistent Data Directories (local):"
DELETE_CONFIRM_MSG=$'This permanently deletes all listed directories and Docker volumes.\nWireGuard peer configs will be unrecoverable.'
USEFUL_COMMANDS="🌐 Web UIs:
   http://${HOST_IP}:${PIHOLE_WEB_PORT}/admin                       # Pi-hole Admin
   http://${HOST_IP}:${GRAFANA_PORT}                                # Grafana dashboards (username: admin)
   http://${HOST_IP}:${UPTIME_KUMA_PORT}                            # Uptime Kuma
   http://${HOST_IP}:${WG_UI_PORT}                                  # WireGuard Dashboard (wg-easy)
   http://${HOST_IP}:${DARKSTAT_PORT}                               # darkstat network traffic

   docker exec -it pihole pihole setpassword                        # Change Pi-hole admin password
   docker exec -it wg-easy wg show                                  # Show connected WireGuard peers and transfer stats
   docker run --rm -it ghcr.io/wg-easy/wg-easy wgpw 'pass'        # Generate new bcrypt hash for PASSWORD_HASH
   docker logs -f pihole                                            # Pi-hole live logs
   docker logs -f wg-easy                                           # WireGuard live logs
   docker logs -f grafana                                           # Grafana live logs
   docker logs -f darkstat                                          # darkstat logs
   docker logs -f uptime-kuma                                       # Uptime Kuma live logs
   docker compose -f ${SCRIPT_DIR}/docker-compose.yml ps           # Full stack status

📌 Notes:
   🌐 Pi-hole config lives at ./etc-pihole/pihole.toml on the host. Edits via
      env vars only seed it on first creation — use the web UI (Settings >
      All Settings) or 'pihole-FTL --config <key> <value>' afterward.
   ➕ WireGuard: add a client/device via the Web Dashboard above → 'New
      Client', then scan the QR code (mobile) or download the .conf (desktop).
   📡 WireGuard: remote access requires forwarding external UDP port
      ${WG_PORT} to this Pi's local static IP on your home router/gateway.
   💾 WireGuard state (server keys, peer configs) lives at ./etc-wireguard —
      back this up; losing it invalidates every client config.
   🔑 To change the WireGuard dashboard login password:
      1. docker run --rm -it ghcr.io/wg-easy/wg-easy wgpw 'your_new_password'
      2. Put the printed hash in PASSWORD_HASH= in .env, single-quoted
      3. docker compose up -d --force-recreate wg-easy
   📊 Grafana: pre-provisioned dashboards are in the 'Pi Network' folder. If
      missing (no internet at deploy time), import manually: Dashboards >
      Import > ID 10176 (Pi-hole) / 12177 (WireGuard), datasource Prometheus.
   ⚙️  FTLCONF_webserver_api_password only seeds pihole.toml on first container
      creation, then is ignored — use 'pihole setpassword' to change it later.
   ⚙️  WG_HOST is read fresh on every container start — editing it in .env and
      recreating wg-easy does take effect, but any client .conf/QR code you
      already downloaded is a static snapshot of the OLD host and won't
      update; redownload it from the dashboard for each existing peer.

📊 Backup named volumes:
   docker run --rm -v prometheus_data:/data -v \$(pwd):/backup alpine tar czf /backup/prometheus_data.tar.gz /data
   docker run --rm -v grafana_data:/data -v \$(pwd):/backup alpine tar czf /backup/grafana_data.tar.gz /data"

source "$REPO_DIR/lib/info-lib.sh"
run_info
