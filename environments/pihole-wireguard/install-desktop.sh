#!/usr/bin/env bash
# Pi-hole + WireGuard desktop entries — data lives in desktop-entries.yaml,
# not here (all grouped in their own "Pi-hole + WireGuard" application-menu
# submenu, not scattered into Internet/System):
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

run_desktop_install_yaml "$ENV_DIR" "$@"
