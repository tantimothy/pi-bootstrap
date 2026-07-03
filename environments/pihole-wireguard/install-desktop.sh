#!/usr/bin/env bash
# Pi-hole + WireGuard desktop entries:
#   Pi-hole Admin        — opens browser to the admin web UI
#   Grafana              — opens browser to the monitoring dashboard
#   Uptime Kuma          — opens browser to the uptime monitor
#   WireGuard Dashboard  — opens browser to the wg-easy peer manager

set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="${APPS_DIR:-${HOME}/.local/share/applications}"

ENTRIES=(
    pi-bootstrap-pihole
    pi-bootstrap-grafana
    pi-bootstrap-uptime-kuma
    pi-bootstrap-wireguard
)

if [ "${1:-}" = "--uninstall" ]; then
    for e in "${ENTRIES[@]}"; do rm -f "$APPS_DIR/${e}.desktop"; done
    exit 0
fi

mkdir -p "$APPS_DIR"

# Read a value from .env with a fallback default
env_val() {
    local key="$1" default="$2"
    local val
    val=$(grep "^${key}=" "$ENV_DIR/.env" 2>/dev/null | cut -d= -f2 | tr -d "\"'" | head -1)
    echo "${val:-$default}"
}

PIHOLE_PORT=$(env_val "PIHOLE_WEB_PORT"  "8080")
GRAFANA_PORT=$(env_val "GRAFANA_PORT"    "3030")
UPTIME_PORT=$(env_val  "UPTIME_KUMA_PORT" "3001")
WG_PORT=$(env_val      "WG_UI_PORT"      "51821")

cat > "$APPS_DIR/pi-bootstrap-pihole.desktop" << EOF
[Desktop Entry]
Name=Pi-hole Admin
Comment=DNS ad-blocker — blocklist management, query log, client stats
Exec=xdg-open http://localhost:$PIHOLE_PORT/admin
Icon=network-server
Type=Application
Categories=Network;System;
Terminal=false
EOF
echo "  ✓  Pi-hole Admin  (http://localhost:$PIHOLE_PORT/admin)"

cat > "$APPS_DIR/pi-bootstrap-grafana.desktop" << EOF
[Desktop Entry]
Name=Grafana (Pi Network)
Comment=Monitoring dashboards — Pi-hole metrics, WireGuard peers, node and speedtest
Exec=xdg-open http://localhost:$GRAFANA_PORT
Icon=utilities-system-monitor
Type=Application
Categories=Network;System;
Terminal=false
EOF
echo "  ✓  Grafana         (http://localhost:$GRAFANA_PORT)"

cat > "$APPS_DIR/pi-bootstrap-uptime-kuma.desktop" << EOF
[Desktop Entry]
Name=Uptime Kuma
Comment=Service uptime and health monitoring dashboard
Exec=xdg-open http://localhost:$UPTIME_PORT
Icon=network-server
Type=Application
Categories=Network;System;
Terminal=false
EOF
echo "  ✓  Uptime Kuma     (http://localhost:$UPTIME_PORT)"

cat > "$APPS_DIR/pi-bootstrap-wireguard.desktop" << EOF
[Desktop Entry]
Name=WireGuard VPN Dashboard
Comment=WireGuard peer management — add or remove clients, view connection status
Exec=xdg-open http://localhost:$WG_PORT
Icon=network-vpn
Type=Application
Categories=Network;
Terminal=false
EOF
echo "  ✓  WireGuard       (http://localhost:$WG_PORT)"
