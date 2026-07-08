#!/usr/bin/env bash
# Pi-hole + WireGuard desktop entries (all grouped in their own "Pi-hole +
# WireGuard" application-menu submenu, not scattered into Internet/System):
#   Pi-hole Admin        — opens browser to the admin web UI
#   Grafana              — opens browser to the monitoring dashboard
#   Uptime Kuma          — opens browser to the uptime monitor
#   WireGuard Dashboard  — opens browser to the wg-easy peer manager
#   Dozzle               — opens browser to the container log viewer
#   Pi-hole + WireGuard Info — opens the generated post-deploy-info.html

set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="${APPS_DIR:-${HOME}/.local/share/applications}"
REPO_DIR="${REPO_DIR:-$(cd "$ENV_DIR/../.." && pwd)}"
source "$REPO_DIR/lib/desktop-lib.sh"

MENU_ID="pihole-wireguard"
CATEGORY="X-PiBootstrap-${MENU_ID};"

ENTRIES=(
    pi-bootstrap-pihole
    pi-bootstrap-grafana
    pi-bootstrap-uptime-kuma
    pi-bootstrap-wireguard
    pi-bootstrap-darkstat
    pi-bootstrap-dozzle
    pi-bootstrap-pihole-wireguard-info
)

if [ "${1:-}" = "--uninstall" ]; then
    for e in "${ENTRIES[@]}"; do rm -f "$APPS_DIR/${e}.desktop"; remove_desktop_icon "$e"; done
    remove_submenu "$MENU_ID"
    exit 0
fi

mkdir -p "$APPS_DIR"

# Only install entries if the environment has been deployed.
# If it isn't (or was deployed before and has since been torn down), remove
# any stale entries so the menu doesn't accumulate broken shortcuts.
if ! docker ps -a --filter "name=^/pihole$" -q 2>/dev/null | grep -q .; then
    for e in "${ENTRIES[@]}"; do rm -f "$APPS_DIR/${e}.desktop"; remove_desktop_icon "$e"; done
    remove_submenu "$MENU_ID"
    echo "  ⚠  pihole-wireguard: container 'pihole' not found — skipping (deploy the environment first)"
    exit 0
fi
echo "  pihole-wireguard: deployed ✓"

register_submenu "$MENU_ID" "Pi-hole + WireGuard" "network-server"

# Read a value from .env with a fallback default
env_val() {
    local key="$1" default="$2"
    local val
    val=$(grep "^${key}=" "$ENV_DIR/.env" 2>/dev/null | cut -d= -f2 | tr -d "\"'" | head -1)
    echo "${val:-$default}"
}

PIHOLE_PORT=$(env_val "PIHOLE_WEB_PORT"  "80")
GRAFANA_PORT=$(env_val "GRAFANA_PORT"    "3030")
UPTIME_PORT=$(env_val  "UPTIME_KUMA_PORT" "3001")
WG_PORT=$(env_val      "WG_UI_PORT"      "51821")
DARKSTAT_PORT=$(env_val "DARKSTAT_PORT"  "667")
DOZZLE_PORT=$(env_val   "DOZZLE_PORT"    "8888")

install_link_icon "pi-bootstrap-pihole" "Pi-hole Admin" \
    "DNS ad-blocker — blocklist management, query log, client stats" \
    "http://localhost:$PIHOLE_PORT/admin" "network-server" "$CATEGORY"
echo "  ✓  Pi-hole Admin  (http://localhost:$PIHOLE_PORT/admin)"

install_link_icon "pi-bootstrap-grafana" "Grafana (Pi Network)" \
    "Monitoring dashboards — Pi-hole metrics, WireGuard peers, node and speedtest" \
    "http://localhost:$GRAFANA_PORT" "utilities-system-monitor" "$CATEGORY"
echo "  ✓  Grafana         (http://localhost:$GRAFANA_PORT)"

install_link_icon "pi-bootstrap-uptime-kuma" "Uptime Kuma" \
    "Service uptime and health monitoring dashboard" \
    "http://localhost:$UPTIME_PORT" "network-server" "$CATEGORY"
echo "  ✓  Uptime Kuma     (http://localhost:$UPTIME_PORT)"

install_link_icon "pi-bootstrap-wireguard" "WireGuard VPN Dashboard" \
    "WireGuard peer management — add or remove clients, view connection status" \
    "http://localhost:$WG_PORT" "network-vpn" "$CATEGORY"
echo "  ✓  WireGuard       (http://localhost:$WG_PORT)"

install_link_icon "pi-bootstrap-darkstat" "darkstat (Traffic)" \
    "Per-host network bandwidth usage and protocol breakdown" \
    "http://localhost:$DARKSTAT_PORT" "network-wired" "$CATEGORY"
echo "  ✓  darkstat        (http://localhost:$DARKSTAT_PORT)"

install_link_icon "pi-bootstrap-dozzle" "Dozzle (Logs)" \
    "Real-time log viewer for every container on this host" \
    "http://localhost:$DOZZLE_PORT" "utilities-terminal" "$CATEGORY"
echo "  ✓  Dozzle          (http://localhost:$DOZZLE_PORT)"

# Ensure post-deploy-info.html exists even if INFO has never been opened
# from the menu yet (run.sh already generates it right after deploy, but
# this is a cheap, idempotent safety net either way).
bash "$ENV_DIR/info.sh" list >/dev/null 2>&1 || true
install_info_icon "pi-bootstrap-pihole-wireguard-info" "Pi-hole + WireGuard Info" "$ENV_DIR/post-deploy-info.html" "$CATEGORY"
echo "  ✓  Info page       (post-deploy-info.html)"
