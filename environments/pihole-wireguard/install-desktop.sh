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

# Only install entries if the environment has been deployed.
# If it isn't (or was deployed before and has since been torn down), remove
# any stale entries so the menu doesn't accumulate broken shortcuts.
if ! docker ps -a --filter "name=^/pihole$" -q 2>/dev/null | grep -q .; then
    for e in "${ENTRIES[@]}"; do rm -f "$APPS_DIR/${e}.desktop"; done
    echo "  ⚠  pihole-wireguard: container 'pihole' not found — skipping (deploy the environment first)"
    exit 0
fi
echo "  pihole-wireguard: deployed ✓"

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

# Build a shell command that tries several launchers in turn. A bare
# `xdg-open` silently does nothing on some Pi desktop images that lack a
# configured default browser handler, so fall back through common
# alternatives. Inlined into each Exec= (rather than a shared function)
# since the desktop launcher spawns a fresh process with no access to
# functions defined in this installer script.
open_cmd() {
    local url="$1"
    printf 'xdg-open %s 2>/dev/null || x-www-browser %s 2>/dev/null || sensible-browser %s 2>/dev/null || chromium-browser %s 2>/dev/null' \
        "$url" "$url" "$url" "$url"
}

cat > "$APPS_DIR/pi-bootstrap-pihole.desktop" << EOF
[Desktop Entry]
Name=Pi-hole Admin
Comment=DNS ad-blocker — blocklist management, query log, client stats
Exec=bash -c "$(open_cmd "http://localhost:$PIHOLE_PORT/admin")"
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
Exec=bash -c "$(open_cmd "http://localhost:$GRAFANA_PORT")"
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
Exec=bash -c "$(open_cmd "http://localhost:$UPTIME_PORT")"
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
Exec=bash -c "$(open_cmd "http://localhost:$WG_PORT")"
Icon=network-vpn
Type=Application
Categories=Network;
Terminal=false
EOF
echo "  ✓  WireGuard       (http://localhost:$WG_PORT)"
