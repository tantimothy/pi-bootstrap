#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ACTION="${1:-list}"

[ -f "$SCRIPT_DIR/.env" ] && { set -a; source "$SCRIPT_DIR/.env"; set +a; }

: "${PORTAINER_PORT:=9000}"
: "${PORTAINER_HTTPS_PORT:=9443}"
: "${DOCKGE_PORT:=5001}"

# Resolve the host's LAN IP so these URLs are actually usable from another
# device — "localhost" only means something on the Pi's own terminal.
HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
[ -z "$HOST_IP" ] && HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$HOST_IP" ] && HOST_IP="localhost"

DATA_DIRS=("$SCRIPT_DIR/dockge-data" "$SCRIPT_DIR/stacks")
DATA_DESCRIPTIONS=(
    "Dockge's own app state (settings, terminal history)"
    "Dockge's compose-stack directory — any stacks you create/import through its UI"
)
INSTALL_DIRS=(); INSTALL_DESCRIPTIONS=()
NAMED_VOLUMES=("portainer_data")
NAMED_VOLUME_DESCRIPTIONS=(
    "Portainer's own app state — users, endpoints, stacks it manages"
)
DELETE_CONFIRM_MSG="Portainer's users/settings and any Dockge-managed stack files under ./stacks will be lost. This does NOT stop or remove containers that Portainer/Dockge were managing — only their own app state."
WEB_UI_NAMES=(
    "Portainer (full container/network/volume management)"
    "Portainer (same, over HTTPS — self-signed cert, browser will warn)"
    "Dockge (compose-stack management)"
)
WEB_UI_URLS=(
    "http://${HOST_IP}:${PORTAINER_PORT}"
    "https://${HOST_IP}:${PORTAINER_HTTPS_PORT}"
    "http://${HOST_IP}:${DOCKGE_PORT}"
)
USEFUL_COMMANDS="   docker logs -f portainer                                         # Portainer live logs
   docker logs -f dockge                                            # Dockge live logs
   docker compose -f ${SCRIPT_DIR}/docker-compose.yml ps           # Stack status

📌 Notes:
   🔐 Portainer gives you 5 minutes after its FIRST start to create the
      initial admin account — if you miss the window, the container must be
      restarted (docker restart portainer) to get a fresh 5-minute window.
   🔌 Both containers mount /var/run/docker.sock read-write, which is
      effectively root-equivalent access to the host — anyone who can reach
      either UI, or anyone who compromises either container, can control
      every container on this Pi, not just the ones in this environment.
      Only deploy this on a trusted LAN, and treat both UIs' credentials
      with the same care as root's password.
   🗂️  Dockge manages its own stacks under ./stacks, deliberately separate
      from this repo's own environments/ directory — see this environment's
      README for why."

source "$REPO_DIR/lib/info-lib.sh"
run_info
