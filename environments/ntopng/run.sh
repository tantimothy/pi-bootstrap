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
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
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
    # Best-effort — immediately removes now-stale desktop entries rather than
    # leaving them until the next manual install-desktop-entries.sh run.
    bash "$REPO_DIR/lib/run-install-desktop.sh" "$SCRIPT_DIR" >/dev/null 2>&1 || true
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

# CONTAINER_NAME is substituted directly into docker-compose.yml's
# container_name fields — a value Docker's naming rules reject (spaces,
# etc.) would otherwise surface as a cryptic "Invalid container name"
# error mid-recreate instead of a clear one here. This also catches the
# old pre-single-value CONTAINER_NAME format (e.g. "ntopng ntopng-redis")
# left over in a .env from before this variable was actually read by
# docker-compose.yml.
if [ -n "${CONTAINER_NAME:-}" ] && ! [[ "$CONTAINER_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
    echo "❌ Error: CONTAINER_NAME='${CONTAINER_NAME}' in .env is not a valid container name." >&2
    echo "   Docker container names may only contain [a-zA-Z0-9_.-], and must start with an alphanumeric." >&2
    echo "   Set it to a single name (e.g. CONTAINER_NAME=ntopng) or remove the line to use the default." >&2
    exit 1
fi

: "${NTOPNG_INTERFACES:=eth0}"
: "${NTOPNG_PORT:=3002}"

mkdir -p "${SCRIPT_DIR}/ntopng-data" "${SCRIPT_DIR}/ntopng-redis-data"

# ---------------------------------------------------------------------------------------
# Policy engine
# ---------------------------------------------------------------------------------------
CONTAINER_NAMES=("${CONTAINER_NAME:-ntopng}" "${CONTAINER_NAME:+${CONTAINER_NAME}-}ntopng-redis")
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
        # Best-effort — picks up any .env change (e.g. NTOPNG_PORT) even on
        # this no-op-ish reconcile path.
        bash "$REPO_DIR/lib/run-install-desktop.sh" "$SCRIPT_DIR" >/dev/null 2>&1 || true
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

# Reached by both a real FAST deploy and CLEAN — either path can leave the
# previous image dangling (ntopng-redis via a newer pull, ntopng itself via
# CLEAN's --no-cache local rebuild retagging over the old build). -f only
# removes untagged/dangling images, never anything still referenced by a
# container.
"$DOCKER" image prune -f >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------------------
# Post-deploy output — delegates to info.sh so the "just deployed" summary
# and the on-demand INFO menu are always the exact same content.
# ---------------------------------------------------------------------------------------
echo "=========================================================="
echo "🏁 ntopng Deployment Complete!"
echo "=========================================================="
bash "$REPO_DIR/lib/run-install-desktop.sh" "$SCRIPT_DIR" >/dev/null 2>&1 || true
bash "$REPO_DIR/lib/run-info.sh" "$SCRIPT_DIR" list
