#!/usr/bin/env bash
# NanoClaw's deployment mode is dynamic, so this belongs with the environment
# rather than in backup.sh's generic maintenance reader.
set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKER="${DOCKER_CMD:-docker}"
if [ -f "${ENV_DIR}/.env" ]; then
    set -a
    source "${ENV_DIR}/.env"
    set +a
fi
mode="${NANOCLAW_DEPLOY_MODE:-}"
if [ -z "$mode" ]; then
    [[ "$(uname)" == "Darwin" ]] && mode="container" || mode="host"
fi
if [ "$mode" = "container" ]; then
    $DOCKER ps -a --filter "name=^/${CONTAINER_NAME:-nanoclaw}$" -q 2>/dev/null | grep -q .
else
    systemctl list-unit-files "nanoclaw.service" --no-legend 2>/dev/null | grep -q nanoclaw
fi
