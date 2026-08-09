#!/bin/bash
# Opens a terminal attached to `nethogs` inside the nettools container, live
# bandwidth-by-process on NETTOOLS_INTERFACE. Meant to be invoked from a
# terminal emulator (the desktop entry's `terminal: true`), not run headless.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCKER="${DOCKER_CMD:-docker}"

if [ -f "$ENV_DIR/.env" ]; then
    set -a
    source "$ENV_DIR/.env"
    set +a
fi

CONTAINER_NAME="${NETTOOLS_CONTAINER_NAME:-nettools}"
IFACE="${NETTOOLS_INTERFACE:-eth0}"

if ! "$DOCKER" ps --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
    echo "Container '$CONTAINER_NAME' is not running. Deploy this environment with FAST first." >&2
    read -p "Press Enter to close..."
    exit 1
fi

"$DOCKER" exec -it "$CONTAINER_NAME" nethogs "$IFACE"
