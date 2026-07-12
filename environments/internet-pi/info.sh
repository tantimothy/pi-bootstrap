#!/usr/bin/env bash
# Data lives in info.yaml; the PIHOLE_ENABLE/MONITORING_ENABLE feature-flag
# branching for WEB_UI_NAMES/WEB_UI_URLS lives here (the one piece that
# isn't static data) — see lib/info-lib.sh's _load_info_yaml.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_DIR/lib/info-lib.sh"

_load_info_yaml "$SCRIPT_DIR" "${1:-list}"

WEB_UI_NAMES=(); WEB_UI_URLS=()
if [ "${PIHOLE_ENABLE:-true}" = "true" ]; then
    WEB_UI_NAMES+=("Pi-hole Admin")
    WEB_UI_URLS+=("http://${HOST_IP}/admin")
fi
if [ "${MONITORING_ENABLE:-true}" = "true" ]; then
    WEB_UI_NAMES+=("Grafana dashboards")
    WEB_UI_URLS+=("http://${HOST_IP}:3030")
fi

run_info
