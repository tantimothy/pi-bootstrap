#!/usr/bin/env bash

# =======================================================================================
# ADVANCED PIPELINE ORCHESTRATION SH WRAPPER (run.sh)
# Clean, Unescaped Production Template
# =======================================================================================

# Fail fast on command errors, unassigned variables, or broken pipes
set -euo pipefail

# ---------------------------------------------------------------------------------------
# 1. Framework Variable Inheritance & Core Setup
# ---------------------------------------------------------------------------------------
DOCKER="${DOCKER_CMD:-docker}"

# Force detection of the correct compose command
if command -v docker-compose &> /dev/null; then
    # Older standalone binary
    DOCKER_COMPOSE="docker-compose"
elif docker compose version &> /dev/null; then
    # Newer docker plugin
    DOCKER_COMPOSE="docker compose"
else
    echo "❌ ERROR: No compatible docker-compose command found!" >&2
    exit 1
fi

# Apply sudo prefix if needed (re-using the logic from your deploy.sh)
if ! $DOCKER ps &>/dev/null; then
    DOCKER="sudo $DOCKER"
    DOCKER_COMPOSE="sudo $DOCKER_COMPOSE"
fi

POLICY="${REBUILD_POLICY:-FAST}"

# Resolve deterministic local scopes
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

echo "=========================================================="
echo "🎬 Subsystem Execution Pipeline Initiated"
echo "⚙️  Active Compilation Strategy Policy: ${POLICY}"
echo "=========================================================="

# ---------------------------------------------------------------------------------------
# 2. Workspace Context & Secret Sourcing
# ---------------------------------------------------------------------------------------
cd "$SCRIPT_DIR"

if [ -f "$ENV_FILE" ]; then
    echo "🔑 Sourcing runtime variables and secrets from configuration ecosystem..."
    
    # Safely auto-export all variables, respecting spaces and quotes
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "❌ Error: Mandatory target environment configuration file (.env) missing." >&2
    echo "   Ensure your parent TUI wizard has parsed your configurations." >&2
    exit 1
fi

# Fallback boundaries to safeguard the deployment if unassigned
: "${PIHOLE_WEB_PORT:=8080}"
: "${WG_UI_PORT:=51821}"

# ---------------------------------------------------------------------------------------
# 3. Pre-emptive Volume Generation & Permission Management
# ---------------------------------------------------------------------------------------
echo "📁 Executing pre-emptive volume generation routines..."
mkdir -p "${SCRIPT_DIR}/etc-pihole"
mkdir -p "${SCRIPT_DIR}/etc-wireguard"
echo "✅ Local host storage layout initialized cleanly."

# ---------------------------------------------------------------------------------------
# 4. Advanced Policy Engine Routing State Machine
# ---------------------------------------------------------------------------------------
CONTAINER_NAMES=("pihole" "wg-easy")
ALL_RUNNING=true
ANY_EXISTS=false
ANY_STOPPED=false

for name in "${CONTAINER_NAMES[@]}"; do
    RUNNING_STATE=$("$DOCKER" inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo "MISSING")
    
    if [ "$RUNNING_STATE" = "true" ]; then
        ANY_EXISTS=true
    elif [ "$RUNNING_STATE" = "false" ]; then
        ANY_EXISTS=true
        ANY_STOPPED=true
        ALL_RUNNING=false
    else
        ALL_RUNNING=false
    fi
done

# Evaluate image availability to detect completely blank/pruned states
IMAGE_EVAL_PIHOLE=$("$DOCKER" images -q pihole/pihole:latest 2>/dev/null || true)
IMAGE_EVAL_WGEASY=$("$DOCKER" images -q ghcr.io/wg-easy/wg-easy:latest 2>/dev/null || true)

# Operational Policy Routing Engine
if [ "$POLICY" = "FAST" ]; then
    # Strategy Shortcut 1A: Container is actively running
    if [ "$ALL_RUNNING" = "true" ]; then
        echo "✅ [FAST POLICY] Stack containers are active and serving traffic."
        echo "🚀 Maximizing platform uptime. Bypassing execution pipeline."
        echo "=========================================================="
        exit 0
    fi

    # Strategy Shortcut 1B: Container is stopped, image exists
    if [ "$ANY_STOPPED" = "true" ] && [ -n "$IMAGE_EVAL_PIHOLE" ] && [ -n "$IMAGE_EVAL_WGEASY" ]; then
        echo "🔄 [FAST POLICY] Containers exist but are stopped."
        echo "⚡ Executing non-destructive fast-start recovery to preserve local data configurations..."
        $DOCKER_COMPOSE --env-file "$ENV_FILE" start
        echo "✅ System lifecycle restored smoothly."
        echo "=========================================================="
        exit 0
    fi
fi

# Rebuild Execution Strategies
if [ "$POLICY" = "CLEAN" ]; then
    echo "🧹 [CLEAN POLICY] Force eviction and zero-cache pipeline requested."
    echo "🛑 Dismantling operational environments..."
    $DOCKER_COMPOSE --env-file "$ENV_FILE" down --volumes --remove-orphans || true
    
    echo "🗑️  Evicting local structural image layers..."
    "$DOCKER" rmi pihole/pihole:latest ghcr.io/wg-easy/wg-easy:latest 2>/dev/null || true
    
    echo "🏗️  Triggering pristine build phase..."
    $DOCKER_COMPOSE --env-file "$ENV_FILE" build --no-cache

elif [ "$POLICY" = "FAST" ]; then
    echo "🛠️  [FAST POLICY] Footprint missing. Running selective compilation..."
    if [ -z "$IMAGE_EVAL_PIHOLE" ] || [ -z "$IMAGE_EVAL_WGEASY" ]; then
        $DOCKER_COMPOSE --env-file "$ENV_FILE" build
    fi
else
    echo "❌ Error: Unrecognized runtime policy context profile: '${POLICY}'" >&2
    exit 1
fi

# ---------------------------------------------------------------------------------------
# 5. Pipeline Layer Pulling & Detached Launch Execution
# ---------------------------------------------------------------------------------------
echo "📥 Orchestrating container deployment manifest layers..."

if [ "$POLICY" = "CLEAN" ]; then
    $DOCKER_COMPOSE --env-file "$ENV_FILE" pull --quiet
else
    $DOCKER_COMPOSE --env-file "$ENV_FILE" pull
fi

echo "🦅 Launching system infrastructure nodes into background space..."
$DOCKER_COMPOSE --env-file "$ENV_FILE" up -d --remove-orphans

# ---------------------------------------------------------------------------------------
# 6. Pipeline Sanity Validation & Telemetry Output
# ---------------------------------------------------------------------------------------
echo "=========================================================="
echo "🏁 Infrastructure Execution Pipeline Completed Successfully!"
echo "=========================================================="
echo "🌍 Pi-hole Web Admin Panel:  http://localhost:${PIHOLE_WEB_PORT}/admin"
echo "🔐 WireGuard Web Dashboard: http://localhost:${WG_UI_PORT}"
echo "=========================================================="
echo ""
echo "📌 Post-Install Notes (normally shown by the installer, hidden behind the container build):"
echo ""
echo "  🔑 Pi-hole: change/reset the admin web UI password"
echo "     docker exec -it pihole pihole setpassword"
echo ""
echo "  🌐 Pi-hole: config lives at ./etc-pihole/pihole.toml on the host."
echo "     Edits via env vars only seed it on first creation — use the web UI"
echo "     (Settings > All Settings) or 'pihole-FTL --config <key> <value>' afterward."
echo ""
echo "  ➕ WireGuard: add a client / device"
echo "     Open the Web Dashboard above, click 'New Client', then scan the QR code"
echo "     with the WireGuard mobile app, or download the .conf for desktop clients."
echo ""
echo "  📡 WireGuard: remote access requires router port forwarding"
echo "     Forward external UDP port ${WG_PORT:-51820} to this Pi's local static IP"
echo "     on your home router/gateway, or remote peers will never reach the tunnel."
echo ""
echo "  👀 WireGuard: check connected peers / tunnel status"
echo "     docker exec -it wg-easy wg show"
echo ""
echo "  💾 WireGuard: persistent state (server keys, peer configs) lives at"
echo "     ./etc-wireguard on the host — back this up; losing it invalidates all"
echo "     existing client configs and requires re-adding every device."
echo "=========================================================="