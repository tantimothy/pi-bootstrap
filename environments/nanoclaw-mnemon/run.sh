#!/usr/bin/env bash

# =======================================================================================
# NANOCLAW + MNEMON ENVIRONMENT ORCHESTRATOR (run.sh)
# Same NanoClaw orchestrator as the plain `nanoclaw` environment, but with
# github.com/mnemon-dev/mnemon patched into NanoClaw's own per-conversation-
# group agent sandbox for persistent, cross-session graph memory — following
# the exact steps in NanoClaw's own .claude/skills/add-mnemon/SKILL.md, not
# a reimplementation of it. This is a fully independent environment (own
# install path, own container name) — it does not share files, containers,
# or state with the plain `nanoclaw` environment, so both can coexist on the
# same machine without colliding.
#
# Container deploy mode only (see the plain `nanoclaw` environment for the
# host/systemd/launchd mode and the reasoning behind the split) — this
# environment exists specifically for the Mac-first, filesystem-sandboxed
# use case, so there's no host-mode branch here to keep in sync.
#
# What mnemon adds: a four-graph (temporal/entity/causal/semantic) memory
# store per conversation group, written to that group's own `.claude/`
# mount — see the README's "Mnemon Integration" section for the full
# picture, including what this does and doesn't change about the
# orchestrator's own trust boundary (it doesn't: mnemon runs inside the
# already-sandboxed per-group agent containers, which never held the
# Docker socket to begin with).
# =======================================================================================

set -euo pipefail

DOCKER="${DOCKER_CMD:-docker}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
POLICY="${REBUILD_POLICY:-FAST}"

echo "=========================================================="
echo "🧠 NanoClaw + Mnemon Deployment Pipeline"
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

INSTALL_PATH="${NANOCLAW_INSTALL_PATH:-$HOME/nanoclaw-mnemon}"
NANOCLAW_PORT="${NANOCLAW_PORT:-3081}"
MNEMON_VERSION="${MNEMON_VERSION:-0.1.1}"
# Opt-in — mnemon's own optional hybrid graph+vector recall (unset by
# default, matching the plain nanoclaw environment's own OLLAMA_HOST stub
# in .env.example: commented out until you actually have Ollama running
# somewhere reachable). Left blank, mnemon runs graph-only, which is its
# own documented default behavior, not a degraded mode.
MNEMON_EMBED_ENDPOINT="${MNEMON_EMBED_ENDPOINT:-}"
MNEMON_EMBED_MODEL="${MNEMON_EMBED_MODEL:-}"
CONTAINER_NAME="nanoclaw-mnemon"
IMAGE_TAG="nanoclaw-mnemon-orchestrator:latest"

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

# ---------------------------------------------------------------------------------------
# Agent containers spawned by NanoClaw are all named/imaged nanoclaw-agent-v2-*
# regardless of which install produced them — matching just that prefix
# would sweep up the plain `nanoclaw` environment's own agent containers
# too, if both are ever deployed on the same machine. Scope the sweep to
# containers whose bind mounts actually trace back to THIS install path.
# ---------------------------------------------------------------------------------------
sweep_agent_container_ids() {
    local ids id mounts
    ids=$($DOCKER ps -a --format '{{.ID}} {{.Image}}' 2>/dev/null | awk '$2 ~ /^nanoclaw-agent-v2-/ {print $1}')
    [ -z "$ids" ] && return 0
    for id in $ids; do
        mounts=$($DOCKER inspect "$id" --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' 2>/dev/null)
        if echo "$mounts" | grep -qF "$INSTALL_PATH"; then
            echo "$id"
        fi
    done
}

remove_agent_containers() {
    local ids; ids=$(sweep_agent_container_ids)
    if [ -n "$ids" ]; then
        echo "🐳 Removing this install's agent containers..."
        echo "$ids" | xargs "$DOCKER" stop 2>/dev/null || true
        echo "$ids" | xargs "$DOCKER" rm   2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------------------
# mnemon patch — adds github.com/mnemon-dev/mnemon persistent memory to
# NanoClaw's own container/Dockerfile and container/entrypoint.sh, following
# the exact steps documented in NanoClaw's own
# .claude/skills/add-mnemon/SKILL.md (verified against the actual skill
# file at https://github.com/nanocoai/nanoclaw/blob/main/.claude/skills/add-mnemon/SKILL.md,
# not guessed). Idempotent, matching that skill's own "already applied"
# checks — safe to call on every deploy, including CLEAN's fresh re-clone.
# ---------------------------------------------------------------------------------------
apply_mnemon_patch() {
    local dockerfile="${INSTALL_PATH}/container/Dockerfile"
    local entry="${INSTALL_PATH}/container/entrypoint.sh"

    if [ ! -f "$dockerfile" ] || [ ! -f "$entry" ]; then
        echo "⚠️  Couldn't find container/Dockerfile or container/entrypoint.sh under $INSTALL_PATH" >&2
        echo "   — NanoClaw's own layout may have changed upstream. Skipping the mnemon patch;" >&2
        echo "   apply it manually per https://github.com/mnemon-dev/mnemon/blob/master/README.md#nanoclaw" >&2
        return 1
    fi

    if grep -q 'MNEMON_VERSION' "$dockerfile"; then
        echo "✅ mnemon already patched into container/Dockerfile."
    else
        echo "🧠 Patching mnemon binary install into container/Dockerfile..."
        local anchor
        anchor=$(grep -n '^# ---- Bun runtime' "$dockerfile" | head -1 | cut -d: -f1)
        if [ -z "$anchor" ]; then
            echo "❌ Couldn't find the '# ---- Bun runtime' anchor in container/Dockerfile." >&2
            echo "   NanoClaw's Dockerfile may have changed upstream — skipping the mnemon patch;" >&2
            echo "   apply it manually per https://github.com/mnemon-dev/mnemon/blob/master/README.md#nanoclaw" >&2
            return 1
        fi
        # Both opt-in and unset by default — see MNEMON_EMBED_ENDPOINT's own
        # comment above. Baked into the image as plain ENV (not forwarded
        # per-container-spawn like /add-ollama-tool's OLLAMA_HOST) because
        # mnemon runs inside NanoClaw's own container-runner.ts, which this
        # environment doesn't patch — an image-level ENV is the only hook
        # available without touching NanoClaw's TypeScript source.
        local embed_env=""
        if [ -n "$MNEMON_EMBED_ENDPOINT" ]; then
            embed_env="ENV MNEMON_EMBED_ENDPOINT=${MNEMON_EMBED_ENDPOINT}"
            if [ -n "$MNEMON_EMBED_MODEL" ]; then
                embed_env="${embed_env}
ENV MNEMON_EMBED_MODEL=${MNEMON_EMBED_MODEL}"
            fi
        fi
        local tmp; tmp=$(mktemp)
        {
            head -n "$((anchor - 1))" "$dockerfile"
            cat <<MNEMON_DOCKER_BLOCK
# ---- mnemon — persistent agent memory ----------------------------------------
ARG MNEMON_VERSION=${MNEMON_VERSION}
RUN ARCH=\$(dpkg --print-architecture) && \\
    curl -fsSL "https://github.com/mnemon-dev/mnemon/releases/download/v\${MNEMON_VERSION}/mnemon_\${MNEMON_VERSION}_linux_\${ARCH}.tar.gz" \\
    | tar -xz -C /usr/local/bin mnemon && \\
    chmod +x /usr/local/bin/mnemon

ENV MNEMON_DATA_DIR=/home/node/.claude/mnemon
${embed_env}

MNEMON_DOCKER_BLOCK
            tail -n "+${anchor}" "$dockerfile"
        } > "$tmp"
        mv "$tmp" "$dockerfile"
    fi

    if grep -q 'mnemon setup' "$entry"; then
        echo "✅ mnemon already wired into container/entrypoint.sh."
    else
        echo "🧠 Wiring mnemon setup into container/entrypoint.sh..."
        local anchor
        anchor=$(grep -n '^set -e$' "$entry" | head -1 | cut -d: -f1)
        if [ -z "$anchor" ]; then
            echo "❌ Couldn't find 'set -e' in container/entrypoint.sh — skipping the mnemon patch;" >&2
            echo "   apply it manually per https://github.com/mnemon-dev/mnemon/blob/master/README.md#nanoclaw" >&2
            return 1
        fi
        local tmp; tmp=$(mktemp)
        {
            head -n "$anchor" "$entry"
            echo ""
            echo 'mnemon setup --target claude-code --yes --global >/dev/stderr 2>&1'
            tail -n "+$((anchor + 1))" "$entry"
        } > "$tmp"
        mv "$tmp" "$entry"
    fi
}

# Mounted at the SAME absolute path both on the host and inside the
# orchestrator container — not remapped to some internal path like
# /workspace. NanoClaw spawns per-conversation-group agent containers
# itself via the bind-mounted Docker socket (Docker-outside-of-Docker:
# those containers are siblings of this one, not nested inside it) — any
# path it passes to `docker run -v <path>:...` is resolved by the HOST's
# Docker daemon against the real host filesystem, not the orchestrator
# container's view of it. Keeping the path identical on both sides is what
# makes a path NanoClaw computes relative to its own install directory
# valid in both contexts at once.
if [ ! -d "$INSTALL_PATH" ]; then
    echo "📁 Creating install path: $INSTALL_PATH"
    mkdir -p "$INSTALL_PATH"
fi

if [ "$POLICY" = "STOP" ]; then
    echo "🛑 [STOP] Pausing NanoClaw+Mnemon container (agent containers preserved)..."
    $DOCKER stop "$CONTAINER_NAME" 2>/dev/null || true
    echo "✅ Container paused. Run with FAST to resume."
    exit 0
fi

if [ "$POLICY" = "TEARDOWN" ]; then
    echo "🗑️  [TEARDOWN] Stopping and removing the orchestrator container and this install's agent containers..."
    $DOCKER stop "$CONTAINER_NAME" 2>/dev/null || true
    $DOCKER rm   "$CONTAINER_NAME" 2>/dev/null || true
    remove_agent_containers
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
    echo "🛑 Fresh image ready — tearing down the previous container and this install's agent containers..."
    $DOCKER stop "$CONTAINER_NAME" 2>/dev/null || true
    $DOCKER rm   "$CONTAINER_NAME" 2>/dev/null || true
    remove_agent_containers
    echo "🗑️  Removing install directory for a fresh clone: $INSTALL_PATH"
    rm -rf "$INSTALL_PATH"
    mkdir -p "$INSTALL_PATH"
    $DOCKER image prune -f >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------------------
# Clone or update NanoClaw's own source directly on the host — a plain
# filesystem/git operation, no container runtime needed for this part, and
# $INSTALL_PATH is a normal host directory regardless of deploy mode.
# nanocoai/nanoclaw is the current canonical location (GitHub redirects the
# older qwibitai/nanoclaw URL the plain `nanoclaw` environment still uses,
# but this environment clones the canonical one directly).
# ---------------------------------------------------------------------------------------
if [ ! -f "${INSTALL_PATH}/nanoclaw.sh" ]; then
    echo "📥 Cloning NanoClaw repository to $INSTALL_PATH ..."
    git clone https://github.com/nanocoai/nanoclaw.git "$INSTALL_PATH"
    echo "✅ Clone complete."
else
    echo "📦 Install path exists. Pulling latest changes..."
    git -C "$INSTALL_PATH" pull --ff-only || echo "⚠️  Git pull skipped (local changes or detached HEAD)."
fi

# Patch mnemon in BEFORE the orchestrator container ever builds NanoClaw's
# own agent-sandbox image, so the very first build already includes it —
# no separate rebuild step needed afterward, unlike applying this skill to
# an already-running install.
apply_mnemon_patch

# ---------------------------------------------------------------------------------------
# Build the orchestrator image if missing, then start/create the container.
# ---------------------------------------------------------------------------------------
if [ -z "$($DOCKER images -q "$IMAGE_TAG" 2>/dev/null)" ]; then
    echo "🛠️  Building the orchestrator image (first run)..."
    $DOCKER build -t "$IMAGE_TAG" "$SCRIPT_DIR"
fi

if $DOCKER ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "✅ [FAST POLICY] NanoClaw+Mnemon container is already running."
elif $DOCKER ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "🔄 [FAST POLICY] Container exists but is stopped. Starting..."
    $DOCKER start "$CONTAINER_NAME" >/dev/null
else
    echo "🚀 Launching the NanoClaw+Mnemon orchestrator container..."
    $DOCKER run -d --name "$CONTAINER_NAME" --restart unless-stopped \
        -e NANOCLAW_INSTALL_PATH="$INSTALL_PATH" \
        -v "$INSTALL_PATH:$INSTALL_PATH" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -p "$NANOCLAW_PORT:$NANOCLAW_PORT" \
        "$IMAGE_TAG" >/dev/null
fi

# Checked directly on the host, not via `docker exec` — $INSTALL_PATH is
# the identical path on both sides of the mount, so this doesn't need the
# container to already be running to answer correctly.
if [ ! -f "${INSTALL_PATH}/dist/index.js" ]; then
    echo ""
    echo "🧙 Handing off to the NanoClaw interactive setup wizard (inside the container)..."
    echo "   The wizard will ask for your Anthropic API key, channel setup, and more."
    echo "   Its first build already includes mnemon, patched in above."
    echo "   iMessage isn't offered in container mode — see the plain nanoclaw environment's README."
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
