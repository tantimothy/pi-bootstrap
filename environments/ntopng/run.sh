#!/usr/bin/env bash

# =======================================================================================
# NTOPNG ENVIRONMENT ORCHESTRATOR (run.sh)
# Deep per-flow traffic analysis (nDPI) — split out of pihole-wireguard since
# it's heavyweight enough to warrant its own opt-in environment rather than
# an on/off toggle bundled into another stack.
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

POLICY="${REBUILD_POLICY:-FAST}"

# STOP: pause containers (keep them, FAST can resume)
if [ "$POLICY" = "STOP" ]; then
    echo "🛑 [STOP] Pausing ntopng (containers preserved)..."
    cd "$SCRIPT_DIR"
    $DOCKER_COMPOSE --env-file "$ENV_FILE" stop || true
    echo "✅ Stack paused. Run with FAST to resume."
    exit 0
fi

# TEARDOWN: stop + remove containers, no reinstall
if [ "$POLICY" = "TEARDOWN" ]; then
    echo "🗑️  [TEARDOWN] Stopping and removing ntopng..."
    cd "$SCRIPT_DIR"
    $DOCKER_COMPOSE --env-file "$ENV_FILE" down --remove-orphans || true
    echo "✅ Stack torn down."
    exit 0
fi

echo "=========================================================="
echo "🎬 ntopng Deployment Pipeline"
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

: "${NTOPNG_INTERFACES:=eth0}"
: "${NTOPNG_PORT:=3002}"

# Detect host LAN IP so post-deploy URLs are immediately clickable/copyable
HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
[ -z "$HOST_IP" ] && HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$HOST_IP" ] && HOST_IP="localhost"

mkdir -p "${SCRIPT_DIR}/ntopng-data" "${SCRIPT_DIR}/ntopng-redis-data"

# ---------------------------------------------------------------------------------------
# Policy engine
# ---------------------------------------------------------------------------------------
CONTAINER_NAMES=("ntopng" "ntopng-redis")
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
        echo "✅ [FAST POLICY] ntopng is active and serving traffic."
        echo "🔎 Reconciling against docker-compose.yml (no image pull) in case it changed..."
        $DOCKER_COMPOSE --env-file "$ENV_FILE" up -d --remove-orphans
        echo "=========================================================="
        exit 0
    fi
    echo "🛠️  [FAST POLICY] One or more containers missing or stopped — deploying..."
elif [ "$POLICY" = "CLEAN" ]; then
    echo "🧹 [CLEAN POLICY] Fresh pull/rebuild and redeploy..."
    $DOCKER_COMPOSE --env-file "$ENV_FILE" down --remove-orphans || true
else
    echo "❌ Error: Unrecognized runtime policy context profile: '${POLICY}'" >&2
    exit 1
fi

echo "📥 Pulling image layers (ntopng-redis only — ntopng is built locally)..."
$DOCKER_COMPOSE --env-file "$ENV_FILE" pull || true

echo "🦅 Launching ntopng + ntopng-redis..."
if [ "$POLICY" = "CLEAN" ]; then
    $DOCKER_COMPOSE --env-file "$ENV_FILE" build --no-cache ntopng
fi
$DOCKER_COMPOSE --env-file "$ENV_FILE" up -d --remove-orphans

# ---------------------------------------------------------------------------------------
# Post-deploy output — delegates to info.sh so the "just deployed" summary
# and the on-demand INFO menu are always the exact same content.
# ---------------------------------------------------------------------------------------
echo "=========================================================="
echo "🏁 ntopng Deployment Complete!"
echo "=========================================================="
bash "$SCRIPT_DIR/info.sh" list
