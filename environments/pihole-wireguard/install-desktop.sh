#!/usr/bin/env bash
# Pi-hole + WireGuard desktop entries (all grouped in their own "Pi-hole +
# WireGuard" application-menu submenu, not scattered into Internet/System):
#   Pi-hole Admin        — opens browser to the admin web UI
#   Grafana              — opens browser to the monitoring dashboard
#   Uptime Kuma          — opens browser to the uptime monitor
#   WireGuard Dashboard  — opens browser to the wg-easy peer manager
#   darkstat             — opens browser to the traffic monitor
#   Dozzle               — opens browser to the container log viewer
#   NetAlertX            — opens browser to the network device scanner
#   Pi-hole + WireGuard Info — opens the generated post-deploy-info.html

set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="${APPS_DIR:-${HOME}/.local/share/applications}"
REPO_DIR="${REPO_DIR:-$(cd "$ENV_DIR/../.." && pwd)}"
source "$REPO_DIR/lib/desktop-lib.sh"

MENU_ID="pihole-wireguard"
MENU_NAME="Pi-hole + WireGuard"
MENU_ICON="network-server"
DEPLOYED_CHECK_KIND="container"
# Mirrors docker-compose.yml's own CONTAINER_NAME override for the primary
# (pihole) container — hardcoding this independently would silently break
# the deployed-check for anyone who's actually customized it.
DEPLOYED_CHECK_VALUE="$(env_val "CONTAINER_NAME" "pihole")"

PIHOLE_PORT=$(env_val "PIHOLE_WEB_PORT"   "80")
GRAFANA_PORT=$(env_val "GRAFANA_PORT"     "3030")
UPTIME_PORT=$(env_val  "UPTIME_KUMA_PORT" "3001")
WG_PORT=$(env_val      "WG_UI_PORT"       "51821")
DARKSTAT_PORT=$(env_val "DARKSTAT_PORT"   "667")
DOZZLE_PORT=$(env_val   "DOZZLE_PORT"     "8888")
NETALERTX_PORT=$(env_val "NETALERTX_PORT" "20211")

ENTRY_IDS=(
    pi-bootstrap-pihole
    pi-bootstrap-grafana
    pi-bootstrap-uptime-kuma
    pi-bootstrap-wireguard
    pi-bootstrap-darkstat
    pi-bootstrap-dozzle
    pi-bootstrap-netalertx
)
ENTRY_NAMES=(
    "Pi-hole Admin"
    "Grafana (Pi Network)"
    "Uptime Kuma"
    "WireGuard VPN Dashboard"
    "darkstat (Traffic)"
    "Dozzle (Logs)"
    "NetAlertX (Device Scanner)"
)
ENTRY_COMMENTS=(
    "DNS ad-blocker — blocklist management, query log, client stats"
    "Monitoring dashboards — Pi-hole metrics, WireGuard peers, node and speedtest"
    "Service uptime and health monitoring dashboard"
    "WireGuard peer management — add or remove clients, view connection status"
    "Per-host network bandwidth usage and protocol breakdown"
    "Real-time log viewer for every container on this host"
    "Network presence scanner — new/unknown device alerts, online/offline history"
)
ENTRY_ICONS=(
    network-server
    utilities-system-monitor
    network-server
    network-vpn
    network-wired
    utilities-terminal
    network-wired
)
ENTRY_KINDS=(link link link link link link link)
ENTRY_TARGETS=(
    "http://localhost:$PIHOLE_PORT/admin"
    "http://localhost:$GRAFANA_PORT"
    "http://localhost:$UPTIME_PORT"
    "http://localhost:$WG_PORT"
    "http://localhost:$DARKSTAT_PORT"
    "http://localhost:$DOZZLE_PORT"
    "http://localhost:$NETALERTX_PORT"
)

INFO_ID="pi-bootstrap-pihole-wireguard-info"
INFO_NAME="Pi-hole + WireGuard Info"

run_desktop_install "$@"
