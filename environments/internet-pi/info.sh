#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ACTION="${1:-list}"

[ -f "$SCRIPT_DIR/.env" ] && { set -a; source "$SCRIPT_DIR/.env"; set +a; }

INSTALL_PATH="${INTERNET_PI_INSTALL_PATH:-/home/pi/internet-pi}"
export INSTALL_PATH

DATA_DIRS=("$HOME/pi-hole" "$HOME/internet-monitoring/grafana" "$HOME/internet-monitoring/prometheus")
DATA_DESCRIPTIONS=(
    "Pi-hole config, gravity database, custom blocklists, local DNS records"
    "Grafana dashboard definitions, data source config, user settings"
    "Prometheus time-series metrics — speedtest history, ping latency, uptime"
)
INSTALL_DIRS=("$INSTALL_PATH")
INSTALL_DESCRIPTIONS=("internet-pi repo clone + generated config.yml and inventory.ini")
NAMED_VOLUMES=(); NAMED_VOLUME_DESCRIPTIONS=()
DATA_DIRS_LABEL="📁 Persistent Data Directories (back these up):"
INSTALL_DIRS_LABEL="📂 Install Directories (can be re-cloned):"
DELETE_INSTALL_DIRS=true
DELETE_CONFIRM_MSG="All Pi-hole settings and Grafana dashboards will be lost."
ENVSUBST_VARS='${INSTALL_PATH}'

source "$REPO_DIR/lib/info-lib.sh"
run_info
