#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ACTION="${1:-list}"

[ -f "$SCRIPT_DIR/.env" ] && { set -a; source "$SCRIPT_DIR/.env"; set +a; }

: "${GRAFANA_PORT:=3030}"
: "${PIHOLE_WEB_PORT:=8080}"
export SCRIPT_DIR PIHOLE_WEB_PORT

DATA_DIRS=("$SCRIPT_DIR/etc-pihole" "$SCRIPT_DIR/etc-wireguard")
DATA_DESCRIPTIONS=(
    "Pi-hole config, gravity database, custom blocklists, local DNS records"
    "WireGuard server keys + all peer configs — losing this invalidates every client VPN"
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
ENVSUBST_VARS='${SCRIPT_DIR} ${PIHOLE_WEB_PORT}'

source "$REPO_DIR/lib/info-lib.sh"
run_info
