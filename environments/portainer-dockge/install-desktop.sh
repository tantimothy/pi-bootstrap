#!/usr/bin/env bash
# Portainer + Dockge desktop entries:
#   Portainer          — opens browser to the full container-management UI
#   Dockge              — opens browser to the compose-stack UI
#   Portainer+Dockge Info — opens the generated post-deploy-info.html

set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="${APPS_DIR:-${HOME}/.local/share/applications}"
REPO_DIR="${REPO_DIR:-$(cd "$ENV_DIR/../.." && pwd)}"
source "$REPO_DIR/lib/desktop-lib.sh"

MENU_ID="portainer-dockge"
MENU_NAME="Portainer + Dockge"
MENU_ICON="docker"
DEPLOYED_CHECK_KIND="container"
DEPLOYED_CHECK_VALUE="portainer"

PORTAINER_PORT=$(env_val "PORTAINER_PORT" "9000")
DOCKGE_PORT=$(env_val "DOCKGE_PORT" "5001")

ENTRY_IDS=(pi-bootstrap-portainer pi-bootstrap-dockge)
ENTRY_NAMES=("Portainer" "Dockge")
ENTRY_COMMENTS=(
    "Full Docker container/network/volume management UI"
    "Lightweight compose-stack management UI"
)
ENTRY_ICONS=(docker docker)
ENTRY_KINDS=(link link)
ENTRY_TARGETS=(
    "http://localhost:$PORTAINER_PORT"
    "http://localhost:$DOCKGE_PORT"
)

INFO_ID="pi-bootstrap-portainer-dockge-info"
INFO_NAME="Portainer + Dockge Info"

run_desktop_install "$@"
