#!/usr/bin/env bash

# =======================================================================================
# PORTAINER + DOCKGE ENVIRONMENT ORCHESTRATOR (run.sh)
# Container management/visualization companions — Portainer for full
# container/network/volume management, Dockge for compose-stack management.
# Neither manages the OTHER environments this repo deploys; see README.
# =======================================================================================

set -euo pipefail

DOCKER="${DOCKER_CMD:-docker}"

if command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE="docker-compose"
elif docker compose version &> /dev/null; then
    DOCKER_COMPOSE="docker compose"
else
    echo "❌ ERROR: No compatible docker-compose command found!" >&2
    exit 1
fi

if ! $DOCKER ps &>/dev/null; then
    DOCKER="sudo $DOCKER"
    DOCKER_COMPOSE="sudo $DOCKER_COMPOSE"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"

# Dockge requires its stacks-directory bind mount to use the IDENTICAL
# absolute path on both sides (host and container) — it invokes `docker
# compose` against this path via the mounted socket, which talks to the
# *host* dockerd. $SCRIPT_DIR is already absolute (see above), so this
# works regardless of where this repo is actually cloned.
export DOCKGE_STACKS_DIR="${SCRIPT_DIR}/stacks"

POLICY="${REBUILD_POLICY:-FAST}"

# STOP: pause containers (keep them, FAST can resume)
if [ "$POLICY" = "STOP" ]; then
    echo "🛑 [STOP] Pausing portainer-dockge (containers preserved)..."
    cd "$SCRIPT_DIR"
    $DOCKER_COMPOSE --env-file "$ENV_FILE" stop || true
    echo "✅ Stack paused. Run with FAST to resume."
    exit 0
fi

# TEARDOWN: stop + remove containers, no reinstall
if [ "$POLICY" = "TEARDOWN" ]; then
    echo "🗑️  [TEARDOWN] Stopping and removing portainer-dockge..."
    cd "$SCRIPT_DIR"
    $DOCKER_COMPOSE --env-file "$ENV_FILE" down --remove-orphans || true
    # Best-effort — immediately removes now-stale desktop entries rather than
    # leaving them until the next manual install-desktop-entries.sh run.
    [ -x "$SCRIPT_DIR/install-desktop.sh" ] && bash "$SCRIPT_DIR/install-desktop.sh" >/dev/null 2>&1 || true
    echo "✅ Stack torn down."
    exit 0
fi

echo "=========================================================="
echo "🎬 Portainer + Dockge Deployment Pipeline"
echo "⚙️  Active Policy: ${POLICY}"
echo "=========================================================="

cd "$SCRIPT_DIR"

if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "❌ Error: .env file missing." >&2
    echo "   Copy .env.example to .env and fill in the values, then re-run." >&2
    exit 1
fi

: "${PORTAINER_PORT:=9000}"
: "${PORTAINER_HTTPS_PORT:=9443}"
: "${DOCKGE_PORT:=5001}"

# Detect host LAN IP so post-deploy URLs are immediately clickable/copyable
HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
[ -z "$HOST_IP" ] && HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$HOST_IP" ] && HOST_IP="localhost"

# Pre-created here (rather than left for Docker to auto-create as a
# bind-mount target) so they're owned by whoever is running this script,
# not by whatever internal UID the container happens to write as.
mkdir -p "${SCRIPT_DIR}/dockge-data" "${DOCKGE_STACKS_DIR}"

# ---------------------------------------------------------------------------------------
# Policy engine
# ---------------------------------------------------------------------------------------
CONTAINER_NAMES=("portainer" "dockge")
ALL_RUNNING=true

for name in "${CONTAINER_NAMES[@]}"; do
    RUNNING_STATE=$("$DOCKER" inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo "MISSING")
    if [ "$RUNNING_STATE" != "true" ]; then
        ALL_RUNNING=false
        break
    fi
done

if [ "$POLICY" = "FAST" ]; then
    if [ "$ALL_RUNNING" = "true" ]; then
        echo "✅ [FAST POLICY] portainer-dockge is active."
        echo "🔎 Reconciling against docker-compose.yml (no image pull) in case it changed..."
        $DOCKER_COMPOSE --env-file "$ENV_FILE" up -d --remove-orphans
        # Best-effort — picks up any .env change (e.g. a changed port) even
        # on this no-op-ish reconcile path.
        [ -x "$SCRIPT_DIR/install-desktop.sh" ] && bash "$SCRIPT_DIR/install-desktop.sh" >/dev/null 2>&1 || true
        echo "=========================================================="
        exit 0
    fi
    echo "🛠️  [FAST POLICY] One or more containers missing or stopped — deploying..."
elif [ "$POLICY" = "CLEAN" ]; then
    echo "🧹 [CLEAN POLICY] Fresh pull and redeploy..."
    $DOCKER_COMPOSE --env-file "$ENV_FILE" down --remove-orphans || true
else
    echo "❌ Error: Unrecognized runtime policy context profile: '${POLICY}'" >&2
    exit 1
fi

echo "📥 Pulling image layers..."
$DOCKER_COMPOSE --env-file "$ENV_FILE" pull

echo "🦅 Launching Portainer + Dockge..."
$DOCKER_COMPOSE --env-file "$ENV_FILE" up -d --remove-orphans

# ---------------------------------------------------------------------------------------
# Post-deploy output — delegates to info.sh so the "just deployed" summary
# and the on-demand INFO menu are always the exact same content.
# ---------------------------------------------------------------------------------------
echo "=========================================================="
echo "🏁 Portainer + Dockge Deployment Complete!"
echo "=========================================================="
[ -x "$SCRIPT_DIR/install-desktop.sh" ] && bash "$SCRIPT_DIR/install-desktop.sh" >/dev/null 2>&1 || true
bash "$SCRIPT_DIR/info.sh" list
