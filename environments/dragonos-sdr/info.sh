#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ACTION="${1:-list}"

[ -f "$SCRIPT_DIR/.env" ] && { set -a; source "$SCRIPT_DIR/.env"; set +a; }

CONTAINER_NAME="${CONTAINER_NAME:-sdr-dragonos-core}"

DATA_DIRS=("$SCRIPT_DIR/workspace/captures" "$SCRIPT_DIR/workspace/msf_data")
DATA_DESCRIPTIONS=(
    "SDR captures, signal recordings, and analysis outputs"
    "Metasploit Framework data — workspace, loot, credentials"
)
INSTALL_DIRS=(); INSTALL_DESCRIPTIONS=()
NAMED_VOLUMES=(); NAMED_VOLUME_DESCRIPTIONS=()
DELETE_CONFIRM_MSG="All SDR captures will be lost."
USEFUL_COMMANDS="   docker exec -it ${CONTAINER_NAME} /usr/local/bin/sdr-menu.sh   # Reattach to SDR menu
   docker exec -it ${CONTAINER_NAME} bash                          # Open shell in container
   docker logs ${CONTAINER_NAME}                                   # Container logs
   ls ${SCRIPT_DIR}/workspace/captures/                            # Browse SDR captures"

source "$REPO_DIR/lib/info-lib.sh"
run_info
