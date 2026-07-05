#!/usr/bin/env bash

# =======================================================================================
# NANOCLAW ENVIRONMENT ORCHESTRATOR (run.sh)
# NanoClaw is a host-level Node.js service — it manages its own Docker containers
# per conversation group. This script handles install, start, and rebuild lifecycle.
# Supports Linux (systemd) and macOS (launchd).
# =======================================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
POLICY="${REBUILD_POLICY:-FAST}"

OS_TYPE="linux"
if [[ "$(uname)" == "Darwin" ]]; then OS_TYPE="macos"; fi

echo "=========================================================="
echo "🤖 NanoClaw Deployment Pipeline"
echo "⚙️  Active Policy: ${POLICY}"
echo "=========================================================="

# ---------------------------------------------------------------------------------------
# 1. Source configuration
# ---------------------------------------------------------------------------------------
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "❌ Error: .env file missing." >&2
    echo "   Copy .env.example to .env and fill in the values, then re-run." >&2
    exit 1
fi

INSTALL_PATH="${NANOCLAW_INSTALL_PATH:-/home/pi/nanoclaw}"
NANOCLAW_PORT="${NANOCLAW_PORT:-3080}"

# Detect host LAN IP so post-deploy URLs are immediately clickable/copyable
HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
[ -z "$HOST_IP" ] && HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$HOST_IP" ] && HOST_IP="localhost"

# ---------------------------------------------------------------------------------------
# 2. Helper: check if the nanoclaw service is active
# ---------------------------------------------------------------------------------------
nanoclaw_is_active() {
    if [ "$OS_TYPE" = "macos" ]; then
        launchctl list | grep -q "nanoclaw" 2>/dev/null
    else
        systemctl is-active --quiet nanoclaw 2>/dev/null
    fi
}

nanoclaw_service_exists() {
    if [ "$OS_TYPE" = "macos" ]; then
        launchctl list | grep -q "nanoclaw" 2>/dev/null || \
            ls ~/Library/LaunchAgents/ 2>/dev/null | grep -q "nanoclaw"
    else
        systemctl list-unit-files "nanoclaw.service" --no-legend 2>/dev/null | grep -q "nanoclaw"
    fi
}

nanoclaw_start() {
    if [ "$OS_TYPE" = "macos" ]; then
        # NanoClaw's installer registers a launchd plist; find and load it
        PLIST=$(ls ~/Library/LaunchAgents/*.nanoclaw*.plist 2>/dev/null | head -1 || true)
        if [ -n "$PLIST" ]; then
            launchctl load "$PLIST" 2>/dev/null || launchctl start "$(basename "$PLIST" .plist)"
        fi
    else
        sudo systemctl start nanoclaw
    fi
}

nanoclaw_stop() {
    if [ "$OS_TYPE" = "macos" ]; then
        PLIST=$(ls ~/Library/LaunchAgents/*.nanoclaw*.plist 2>/dev/null | head -1 || true)
        if [ -n "$PLIST" ]; then
            launchctl unload "$PLIST" 2>/dev/null || true
        fi
    else
        sudo systemctl stop nanoclaw 2>/dev/null || true
        sudo systemctl disable nanoclaw 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------------------
# 3. STOP / TEARDOWN — handle before anything else so no deploy logic runs
# ---------------------------------------------------------------------------------------
if [ "$POLICY" = "STOP" ]; then
    echo "🛑 [STOP] Pausing NanoClaw service (agent containers preserved)..."
    nanoclaw_stop
    echo "✅ Service stopped. Run with FAST to resume."
    exit 0
fi

if [ "$POLICY" = "TEARDOWN" ]; then
    echo "🗑️  [TEARDOWN] Stopping NanoClaw service and removing agent containers..."
    nanoclaw_stop
    AGENT_CONTAINERS=$(docker ps -a --format '{{.ID}} {{.Image}}' 2>/dev/null \
        | awk '$2 ~ /^nanoclaw-agent-v2-/ {print $1}')
    if [ -n "$AGENT_CONTAINERS" ]; then
        echo "🐳 Removing agent containers..."
        echo "$AGENT_CONTAINERS" | xargs docker stop 2>/dev/null || true
        echo "$AGENT_CONTAINERS" | xargs docker rm   2>/dev/null || true
    fi
    echo "✅ Service and containers removed."
    exit 0
fi

if [ "$POLICY" = "FAST" ]; then
    if nanoclaw_is_active; then
        echo "✅ [FAST POLICY] NanoClaw service is already running."
        echo ""
        if [ "$OS_TYPE" = "linux" ]; then
            systemctl status nanoclaw --no-pager --lines=5 2>/dev/null || true
        fi
        echo ""
        echo "🌐 Web interface: http://${HOST_IP}:${NANOCLAW_PORT}"
        echo "=========================================================="
        exit 0
    fi

    # Service registered but not running — start it
    if nanoclaw_service_exists; then
        echo "🔄 [FAST POLICY] NanoClaw is installed but stopped. Starting..."
        nanoclaw_start
        echo "✅ NanoClaw started."
        echo "🌐 Web interface: http://${HOST_IP}:${NANOCLAW_PORT}"
        echo "=========================================================="
        exit 0
    fi
fi

# ---------------------------------------------------------------------------------------
# 4. CLEAN policy: stop service, remove agent containers, wipe install directory
# ---------------------------------------------------------------------------------------
if [ "$POLICY" = "CLEAN" ]; then
    echo "🧹 [CLEAN POLICY] Stopping NanoClaw service and agent containers..."
    nanoclaw_stop

    # NanoClaw names its agent images nanoclaw-agent-v2-{hash}:latest where the
    # hash is derived from the install path. Filter by prefix to catch all of them.
    AGENT_CONTAINERS=$(docker ps -a --format '{{.ID}} {{.Image}}' 2>/dev/null \
        | awk '$2 ~ /^nanoclaw-agent-v2-/ {print $1}')
    if [ -n "$AGENT_CONTAINERS" ]; then
        echo "🐳 Stopping and removing NanoClaw agent containers..."
        echo "$AGENT_CONTAINERS" | xargs docker stop 2>/dev/null || true
        echo "$AGENT_CONTAINERS" | xargs docker rm   2>/dev/null || true
    fi

    if [ -d "$INSTALL_PATH" ]; then
        echo "🗑️  Removing install directory: $INSTALL_PATH"
        rm -rf "$INSTALL_PATH"
    fi

    echo "✅ Clean complete. Proceeding with fresh install below."
fi

# ---------------------------------------------------------------------------------------
# 5. First-time installation — clone and run the interactive nanoclaw.sh wizard
# ---------------------------------------------------------------------------------------
if [ ! -d "$INSTALL_PATH" ]; then
    echo "📥 Cloning NanoClaw repository to $INSTALL_PATH ..."
    git clone https://github.com/qwibitai/nanoclaw.git "$INSTALL_PATH"
    echo "✅ Clone complete."
else
    echo "📦 Install path exists. Pulling latest changes..."
    git -C "$INSTALL_PATH" pull --ff-only || echo "⚠️  Git pull skipped (local changes or detached HEAD)."
fi

echo ""
echo "🧙 Handing off to the NanoClaw interactive setup wizard..."
echo "   The wizard will ask for your Anthropic API key, channel setup, and more."
echo "   Follow the prompts in your terminal."
echo ""

# Re-bind stdin/stdout to the physical terminal (in case we were called via pipe)
exec 0< /dev/tty
exec 1> /dev/tty
exec 2> /dev/tty

cd "$INSTALL_PATH"
bash nanoclaw.sh

# ---------------------------------------------------------------------------------------
# 6. Post-install status
#    Delegates to info.sh so the "just deployed" summary and the on-demand
#    INFO menu are always the exact same content — one file, not two.
# ---------------------------------------------------------------------------------------
echo "=========================================================="
echo "🏁 NanoClaw Setup Complete"
echo "=========================================================="
bash "$SCRIPT_DIR/info.sh" list
