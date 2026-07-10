#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ACTION="${1:-list}"

[ -f "$SCRIPT_DIR/.env" ] && { set -a; source "$SCRIPT_DIR/.env"; set +a; }

: "${PORTAINER_PORT:=9000}"
: "${PORTAINER_HTTPS_PORT:=9443}"

# Resolve the host's LAN IP so these URLs are actually usable from another
# device — "localhost" only means something on the Pi's own terminal.
HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
[ -z "$HOST_IP" ] && HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$HOST_IP" ] && HOST_IP="localhost"

DATA_DIRS=(); DATA_DESCRIPTIONS=()
INSTALL_DIRS=(); INSTALL_DESCRIPTIONS=()
NAMED_VOLUMES=("portainer_data")
NAMED_VOLUME_DESCRIPTIONS=(
    "Portainer's own app state — users, endpoints, stacks it manages"
)
DELETE_CONFIRM_MSG="Portainer's users/settings will be lost. This does NOT stop or remove containers that Portainer was managing — only its own app state."
WEB_UI_NAMES=(
    "Portainer (full container/network/volume management)"
    "Portainer (same, over HTTPS — self-signed cert, browser will warn)"
)
WEB_UI_URLS=(
    "http://${HOST_IP}:${PORTAINER_PORT}"
    "https://${HOST_IP}:${PORTAINER_HTTPS_PORT}"
)
USEFUL_COMMANDS="   docker logs -f portainer                                         # Portainer live logs
   docker compose -f ${SCRIPT_DIR}/docker-compose.yml ps           # Stack status

📌 Notes:
   🔐 Portainer gives you 5 minutes after its FIRST start to create the
      initial admin account — if you miss the window, the container must be
      restarted (docker restart portainer) to get a fresh 5-minute window.
      Recent Portainer versions also require a one-time setup token from
      its own logs (docker logs portainer | grep setup_token) to complete
      that first admin account.
   🔌 Mounts /var/run/docker.sock read-write, which is effectively
      root-equivalent access to the host — anyone who can reach the UI, or
      anyone who compromises the container, can control every container on
      this Pi, not just the ones in this environment. Only deploy this on a
      trusted LAN, and treat its credentials with the same care as root's
      password."

source "$REPO_DIR/lib/info-lib.sh"
run_info
