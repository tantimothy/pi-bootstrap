#!/usr/bin/env bash

# =======================================================================================
# NANOCLAW ENVIRONMENT ORCHESTRATOR (run.sh)
# NanoClaw is a host-level Node.js service — it manages its own Docker containers
# per conversation group. This script handles install, start, and rebuild lifecycle.
#
# Two deployment modes for the orchestrator process itself (NANOCLAW_DEPLOY_MODE):
#   "host"      — bare systemd (Linux) / launchd (macOS) service, full access to
#                 whatever the OS user account can read/write. Supports iMessage
#                 on macOS (setup/add-imessage.sh needs real Messages.app/TCC
#                 access). This is the original, unchanged behavior.
#   "container" — the orchestrator itself runs inside a Docker container, with
#                 filesystem access limited to NANOCLAW_INSTALL_PATH (nothing
#                 else on the host is reachable). No iMessage support — Docker
#                 Desktop on macOS runs containers inside a Linux VM with no
#                 path to the host's Messages.app/TCC layer at all. See the
#                 README's "Deployment Modes" section for the full tradeoff.
# Auto-selected by OS if NANOCLAW_DEPLOY_MODE is unset in .env: macOS defaults
# to "container", Linux defaults to "host" — override explicitly to change it.
# =======================================================================================

set -euo pipefail

DOCKER="${DOCKER_CMD:-docker}"
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

INSTALL_PATH="${NANOCLAW_INSTALL_PATH:-$HOME/nanoclaw}"
NANOCLAW_PORT="${NANOCLAW_PORT:-3080}"

DEPLOY_MODE="${NANOCLAW_DEPLOY_MODE:-}"
if [ -z "$DEPLOY_MODE" ]; then
    if [ "$OS_TYPE" = "macos" ]; then DEPLOY_MODE="container"; else DEPLOY_MODE="host"; fi
fi
echo "📦 Deploy mode: ${DEPLOY_MODE} (set NANOCLAW_DEPLOY_MODE in .env to override)"

# Detect host LAN IP so post-deploy URLs are immediately clickable/copyable.
# `ip` doesn't exist on macOS at all (it's Linux-only iproute2) — under
# `set -euo pipefail`, letting that failure propagate through the pipe
# into awk would silently kill this whole script before it prints
# anything, since ip's own stderr is redirected away. The `|| true`
# absorbs that so awk (which never fails, even on empty input) is what
# actually determines the pipeline's exit status.
HOST_IP=$( { ip route get 1.1.1.1 2>/dev/null || true; } | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
[ -z "$HOST_IP" ] && HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$HOST_IP" ] && HOST_IP="localhost"

# =========================================================================================
# CONTAINER MODE — the orchestrator itself runs sandboxed in Docker.
# =========================================================================================
if [ "$DEPLOY_MODE" = "container" ]; then
    CONTAINER_NAME="${CONTAINER_NAME:-nanoclaw}"
    IMAGE_TAG="nanoclaw-orchestrator:latest"

    # Mounted at the SAME absolute path both on the host and inside this
    # container — not remapped to some internal path like /workspace.
    # NanoClaw spawns per-conversation-group agent containers itself via
    # the bind-mounted Docker socket (Docker-outside-of-Docker: those
    # containers are siblings of this one, not nested inside it) — any
    # path it passes to `docker run -v <path>:...` is resolved by the
    # HOST's Docker daemon against the real host filesystem, not this
    # container's view of it. Keeping the path identical on both sides is
    # what makes a path NanoClaw computes relative to its own install
    # directory valid in both contexts at once. Remapping this would
    # silently break agent container spawning, or mount the wrong
    # directory on the host — not a loud failure, so this is worth
    # getting right rather than "simplifying."
    if [ ! -d "$INSTALL_PATH" ]; then
        echo "📁 Creating install path: $INSTALL_PATH"
        mkdir -p "$INSTALL_PATH"
    fi

    if [ "$POLICY" = "STOP" ]; then
        echo "🛑 [STOP] Pausing NanoClaw container (agent containers preserved)..."
        $DOCKER stop "$CONTAINER_NAME" 2>/dev/null || true
        echo "✅ Container paused. Run with FAST to resume."
        exit 0
    fi

    if [ "$POLICY" = "TEARDOWN" ]; then
        echo "🗑️  [TEARDOWN] Stopping and removing NanoClaw container and agent containers..."
        $DOCKER stop "$CONTAINER_NAME" 2>/dev/null || true
        $DOCKER rm   "$CONTAINER_NAME" 2>/dev/null || true
        AGENT_CONTAINERS=$($DOCKER ps -a --format '{{.ID}} {{.Image}}' 2>/dev/null \
            | awk '$2 ~ /^nanoclaw-agent-v2-/ {print $1}')
        if [ -n "$AGENT_CONTAINERS" ]; then
            echo "🐳 Removing agent containers..."
            echo "$AGENT_CONTAINERS" | xargs "$DOCKER" stop 2>/dev/null || true
            echo "$AGENT_CONTAINERS" | xargs "$DOCKER" rm   2>/dev/null || true
        fi
        [ -x "$SCRIPT_DIR/install-desktop.sh" ] && bash "$SCRIPT_DIR/install-desktop.sh" >/dev/null 2>&1 || true
        echo "✅ Container and agent containers removed. Install path (\$NANOCLAW_INSTALL_PATH) untouched."
        exit 0
    fi

    if [ "$POLICY" = "CLEAN" ]; then
        echo "🧹 [CLEAN POLICY] Rebuilding the orchestrator image before touching anything running..."
        if ! $DOCKER build --no-cache -t "$IMAGE_TAG" "$SCRIPT_DIR"; then
            echo "❌ Build failed — leaving the existing container untouched."
            exit 1
        fi
        echo "🛑 Fresh image ready — tearing down the previous container and agent containers..."
        $DOCKER stop "$CONTAINER_NAME" 2>/dev/null || true
        $DOCKER rm   "$CONTAINER_NAME" 2>/dev/null || true
        AGENT_CONTAINERS=$($DOCKER ps -a --format '{{.ID}} {{.Image}}' 2>/dev/null \
            | awk '$2 ~ /^nanoclaw-agent-v2-/ {print $1}')
        if [ -n "$AGENT_CONTAINERS" ]; then
            echo "$AGENT_CONTAINERS" | xargs "$DOCKER" stop 2>/dev/null || true
            echo "$AGENT_CONTAINERS" | xargs "$DOCKER" rm   2>/dev/null || true
        fi
        echo "🗑️  Removing install directory for a fresh clone: $INSTALL_PATH"
        rm -rf "$INSTALL_PATH"
        mkdir -p "$INSTALL_PATH"
        $DOCKER image prune -f >/dev/null 2>&1 || true
    fi

    # FAST (and the tail end of CLEAN, which falls through here): build
    # the image if it's missing, then start/create the container, then
    # hand off to NanoClaw's own interactive wizard if it hasn't been
    # installed into $INSTALL_PATH yet.
    if [ -z "$($DOCKER images -q "$IMAGE_TAG" 2>/dev/null)" ]; then
        echo "🛠️  Building the orchestrator image (first run)..."
        $DOCKER build -t "$IMAGE_TAG" "$SCRIPT_DIR"
    fi

    if $DOCKER ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "✅ [FAST POLICY] NanoClaw container is already running."
    elif $DOCKER ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "🔄 [FAST POLICY] NanoClaw container exists but is stopped. Starting..."
        $DOCKER start "$CONTAINER_NAME" >/dev/null
    else
        echo "🚀 Launching the NanoClaw orchestrator container..."
        $DOCKER run -d --name "$CONTAINER_NAME" --restart unless-stopped \
            -e NANOCLAW_INSTALL_PATH="$INSTALL_PATH" \
            -e CONTAINER_NAME="$CONTAINER_NAME" \
            -v "$INSTALL_PATH:$INSTALL_PATH" \
            -v /var/run/docker.sock:/var/run/docker.sock \
            -p "$NANOCLAW_PORT:$NANOCLAW_PORT" \
            "$IMAGE_TAG" >/dev/null
    fi

    if ! $DOCKER exec "$CONTAINER_NAME" test -f "$INSTALL_PATH/dist/index.js" 2>/dev/null; then
        if [ ! -f "$INSTALL_PATH/nanoclaw.sh" ]; then
            echo "📥 Cloning NanoClaw repository to $INSTALL_PATH ..."
            git clone https://github.com/nanocoai/nanoclaw.git "$INSTALL_PATH"
            echo "✅ Clone complete."
        else
            echo "📦 Install path exists. Pulling latest changes..."
            git -C "$INSTALL_PATH" pull --ff-only || echo "⚠️  Git pull skipped (local changes or detached HEAD)."
        fi
        echo ""
        echo "🧙 Handing off to the NanoClaw interactive setup wizard (inside the container)..."
        echo "   The wizard will ask for your Anthropic API key, channel setup, and more."
        echo "   iMessage isn't offered in container mode — see the README."
        echo ""
        exec 0< /dev/tty
        exec 1> /dev/tty
        exec 2> /dev/tty
        $DOCKER exec -it "$CONTAINER_NAME" bash -lc "cd '$INSTALL_PATH' && bash nanoclaw.sh"
    fi

    echo "🌐 Web interface: http://${HOST_IP}:${NANOCLAW_PORT}"
    echo "=========================================================="
    [ -x "$SCRIPT_DIR/install-desktop.sh" ] && bash "$SCRIPT_DIR/install-desktop.sh" >/dev/null 2>&1 || true
    bash "$SCRIPT_DIR/info.sh" list
    exit 0
fi

# =========================================================================================
# HOST MODE — bare systemd/launchd service, unchanged from before container mode existed.
# =========================================================================================

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
    AGENT_CONTAINERS=$($DOCKER ps -a --format '{{.ID}} {{.Image}}' 2>/dev/null \
        | awk '$2 ~ /^nanoclaw-agent-v2-/ {print $1}')
    if [ -n "$AGENT_CONTAINERS" ]; then
        echo "🐳 Removing agent containers..."
        echo "$AGENT_CONTAINERS" | xargs "$DOCKER" stop 2>/dev/null || true
        echo "$AGENT_CONTAINERS" | xargs "$DOCKER" rm   2>/dev/null || true
    fi
    # Best-effort — immediately removes now-stale desktop entries rather than
    # leaving them until the next manual install-desktop-entries.sh run.
    [ -x "$SCRIPT_DIR/install-desktop.sh" ] && bash "$SCRIPT_DIR/install-desktop.sh" >/dev/null 2>&1 || true
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
        # Best-effort refresh in case NANOCLAW_PORT (or anything else read
        # from .env) changed since entries were last installed.
        [ -x "$SCRIPT_DIR/install-desktop.sh" ] && bash "$SCRIPT_DIR/install-desktop.sh" >/dev/null 2>&1 || true
        exit 0
    fi

    # Service registered but not running — start it
    if nanoclaw_service_exists; then
        echo "🔄 [FAST POLICY] NanoClaw is installed but stopped. Starting..."
        nanoclaw_start
        echo "✅ NanoClaw started."
        echo "🌐 Web interface: http://${HOST_IP}:${NANOCLAW_PORT}"
        echo "=========================================================="
        [ -x "$SCRIPT_DIR/install-desktop.sh" ] && bash "$SCRIPT_DIR/install-desktop.sh" >/dev/null 2>&1 || true
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
    AGENT_CONTAINERS=$($DOCKER ps -a --format '{{.ID}} {{.Image}}' 2>/dev/null \
        | awk '$2 ~ /^nanoclaw-agent-v2-/ {print $1}')
    if [ -n "$AGENT_CONTAINERS" ]; then
        echo "🐳 Stopping and removing NanoClaw agent containers..."
        echo "$AGENT_CONTAINERS" | xargs "$DOCKER" stop 2>/dev/null || true
        echo "$AGENT_CONTAINERS" | xargs "$DOCKER" rm   2>/dev/null || true
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
    git clone https://github.com/nanocoai/nanoclaw.git "$INSTALL_PATH"
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
[ -x "$SCRIPT_DIR/install-desktop.sh" ] && bash "$SCRIPT_DIR/install-desktop.sh" >/dev/null 2>&1 || true
bash "$SCRIPT_DIR/info.sh" list
