#!/usr/bin/env bash
# Portainer desktop entries:
#   Portainer      — opens browser to the full container-management UI
#   Portainer Info — opens the generated post-deploy-info.html

set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="${APPS_DIR:-${HOME}/.local/share/applications}"
REPO_DIR="${REPO_DIR:-$(cd "$ENV_DIR/../.." && pwd)}"
source "$REPO_DIR/lib/desktop-lib.sh"

MENU_ID="portainer"
MENU_NAME="Portainer"
MENU_ICON="docker"
DEPLOYED_CHECK_KIND="container"
DEPLOYED_CHECK_VALUE="portainer"

PORTAINER_PORT=$(env_val "PORTAINER_PORT" "9000")

ENTRY_IDS=(pi-bootstrap-portainer)
ENTRY_NAMES=("Portainer")
ENTRY_COMMENTS=(
    "Full Docker container/network/volume management UI"
)
ENTRY_ICONS=(docker)
ENTRY_KINDS=(link)
ENTRY_TARGETS=(
    "http://localhost:$PORTAINER_PORT"
)

INFO_ID="pi-bootstrap-portainer-info"
INFO_NAME="Portainer Info"

run_desktop_install "$@"
