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
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
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
# .env.example's own literal default (/home/pi/nanoclaw-mnemon) is
# Pi-appropriate for this repo's primary target, but deploy.sh's TUI config
# form always writes a value for every .env.example key — even one nobody
# edited — so ${NANOCLAW_INSTALL_PATH:-$HOME/nanoclaw-mnemon} above never
# actually triggers for anyone going through the TUI: NANOCLAW_INSTALL_PATH
# is never empty once .env exists. On macOS /home/pi doesn't exist at all
# (no `pi` user, no /home), so accepting that default as-is means every
# mkdir/git-clone below fails — worth catching explicitly given this
# environment is specifically documented as Mac-first (see the header
# comment above). Only overrides the exact, unmodified default — a
# deliberate custom path (even a Linux-style one) is left alone.
if [[ "$(uname)" == "Darwin" ]] && [ "$INSTALL_PATH" = "/home/pi/nanoclaw-mnemon" ]; then
    INSTALL_PATH="$HOME/nanoclaw-mnemon"
    echo "⚠️  NANOCLAW_INSTALL_PATH was still the Pi-only default (/home/pi/nanoclaw-mnemon), which doesn't exist on macOS."
    echo "   Switching to \$HOME/nanoclaw-mnemon ($INSTALL_PATH) and updating .env to match."
    # Persisted, not just overridden in-memory for this run — otherwise
    # info.yaml's own display of this same path (and any future run before
    # the override logic above re-runs) would still show the broken /home/pi
    # path even though this run actually installs somewhere else.
    # -i.bak (suffix attached, no space) is the one `sed -i` form GNU and
    # BSD/macOS sed both accept identically.
    if [ -f "$ENV_FILE" ] && grep -q "^NANOCLAW_INSTALL_PATH=" "$ENV_FILE"; then
        sed -i.bak "s#^NANOCLAW_INSTALL_PATH=.*#NANOCLAW_INSTALL_PATH='${INSTALL_PATH}'#" "$ENV_FILE"
        rm -f "${ENV_FILE}.bak"
    fi
fi
NANOCLAW_PORT="${NANOCLAW_PORT:-3081}"
MNEMON_VERSION="${MNEMON_VERSION:-0.1.1}"
# Opt-in — mnemon's own optional hybrid graph+vector recall (unset by
# default, matching the plain nanoclaw environment's own OLLAMA_HOST stub
# in .env.example: commented out until you actually have Ollama running
# somewhere reachable). Left blank, mnemon runs graph-only, which is its
# own documented default behavior, not a degraded mode.
MNEMON_EMBED_ENDPOINT="${MNEMON_EMBED_ENDPOINT:-}"
MNEMON_EMBED_MODEL="${MNEMON_EMBED_MODEL:-}"
CONTAINER_NAME="${CONTAINER_NAME:-nanoclaw-mnemon}"
IMAGE_TAG="nanoclaw-mnemon-orchestrator:latest"

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
            # NanoClaw's own container-runner.ts unconditionally injects
            # HTTPS_PROXY (+ certs) into every agent container for OneCLI's
            # credential injection — verified directly against its source.
            # That only affects https:// URLs by proxy-env-var convention,
            # so our http:// default is unaffected, but if someone points
            # this at an HTTPS endpoint instead, it would otherwise get
            # silently routed through a proxy that isn't built to pass
            # arbitrary traffic through. NO_PROXY/no_proxy sidesteps that —
            # same fix /add-ollama-provider's own SKILL.md applies for its
            # analogous ANTHROPIC_BASE_URL-redirection case. Set
            # unconditionally (not just for https://) since it's a no-op
            # for plain HTTP and this is cheap insurance either way.
            local embed_host
            embed_host=$(printf '%s' "$MNEMON_EMBED_ENDPOINT" | sed -E 's#^[a-zA-Z]+://##; s#[:/].*$##')
            if [ -n "$embed_host" ]; then
                embed_env="${embed_env}
ENV NO_PROXY=${embed_host}
ENV no_proxy=${embed_host}"
            fi
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

# ---------------------------------------------------------------------------------------
# Only runs at all if MNEMON_EMBED_ENDPOINT is set — mnemon's embeddings are
# opt-in (see .env.example), and this environment never touches Ollama
# otherwise. Best-effort throughout: every failure path warns and returns 0
# rather than aborting the deploy, since embeddings are optional — mnemon
# itself falls back to graph-only recall if this endpoint stays unreachable.
# Installation is gated behind an explicit y/N prompt; pulling a model is
# not (lower-risk, and mirrors mnemon's own binary being auto-downloaded).
# ---------------------------------------------------------------------------------------
ensure_ollama_ready() {
    [ -z "$MNEMON_EMBED_ENDPOINT" ] && return 0

    local model="${MNEMON_EMBED_MODEL:-nomic-embed-text}"
    local endpoint="$MNEMON_EMBED_ENDPOINT"
    local is_local=false
    case "$endpoint" in
        *host.docker.internal*|*localhost*|*127.0.0.1*) is_local=true ;;
    esac

    echo "🔎 Checking Ollama at $endpoint (mnemon embeddings are enabled in .env)..."

    if ! curl -fsS "${endpoint}/api/tags" >/dev/null 2>&1; then
        if [ "$is_local" != "true" ]; then
            echo "⚠️  $endpoint isn't reachable, and isn't a local address this script manages." >&2
            echo "   mnemon will run graph-only until that endpoint is reachable — nothing else to do here." >&2
            return 0
        fi

        if ! command -v ollama >/dev/null 2>&1; then
            echo "⚠️  Ollama isn't installed on this host."
            local reply=""
            # `read -p`'s own prompt text goes to stderr, not stdout — and
            # the `2>/dev/null` below (there to quietly handle hosts with
            # no /dev/tty at all, e.g. a non-interactive curl|bash install)
            # was silencing that prompt right along with it. Confirmed
            # directly: a real deploy looked "stuck" right after the
            # "isn't installed" line, with no visible question at all,
            # even though it was genuinely just waiting on stdin the whole
            # time. Printing the question via a plain `echo` first — never
            # subject to that redirect — means it's always visible
            # regardless of whether /dev/tty exists.
            if [[ "$(uname)" == "Darwin" ]]; then
                echo "   Install it now via Homebrew? [y/N] "
            else
                echo "   Install it now via the official installer (curl | sh)? [y/N] "
            fi
            read -r reply < /dev/tty 2>/dev/null || true
            if [[ "$reply" =~ ^[Yy]$ ]]; then
                if [[ "$(uname)" == "Darwin" ]]; then
                    if command -v brew >/dev/null 2>&1; then
                        brew install ollama || echo "⚠️  brew install failed — install manually: https://ollama.com/download" >&2
                    else
                        echo "⚠️  Homebrew not found — install manually: https://ollama.com/download" >&2
                    fi
                else
                    curl -fsSL https://ollama.com/install.sh | sh || echo "⚠️  Installer failed — install manually: https://ollama.com/download" >&2
                fi
            else
                echo "   Skipping — mnemon will run graph-only until Ollama is reachable at $endpoint." >&2
                return 0
            fi
        fi

        if command -v ollama >/dev/null 2>&1 && ! curl -fsS "${endpoint}/api/tags" >/dev/null 2>&1; then
            echo "🚀 Starting Ollama..."
            if [[ "$(uname)" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
                brew services start ollama >/dev/null 2>&1 || (nohup ollama serve >/dev/null 2>&1 &)
            else
                (nohup ollama serve >/dev/null 2>&1 &)
            fi
            local tries=0
            while [ "$tries" -lt 10 ] && ! curl -fsS "${endpoint}/api/tags" >/dev/null 2>&1; do
                sleep 1
                tries=$((tries + 1))
            done
        fi

        if ! curl -fsS "${endpoint}/api/tags" >/dev/null 2>&1; then
            echo "⚠️  Still couldn't reach Ollama at $endpoint — mnemon will run graph-only for now." >&2
            return 0
        fi
    fi

    echo "✅ Ollama is reachable."

    if curl -fsS "${endpoint}/api/tags" 2>/dev/null | grep -q "\"name\":\"${model}"; then
        echo "✅ Model '$model' already pulled."
    elif [ "$is_local" = "true" ] && command -v ollama >/dev/null 2>&1; then
        echo "📥 Pulling '$model' (this can take a while the first time)..."
        OLLAMA_HOST="${endpoint#http://}" ollama pull "$model" || echo "⚠️  Pull failed — mnemon will run graph-only until '$model' is available." >&2
    else
        echo "⚠️  '$model' isn't pulled on $endpoint and it's not a local daemon this script manages — pull it there yourself." >&2
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
    bash "$REPO_DIR/lib/run-install-desktop.sh" "$SCRIPT_DIR" >/dev/null 2>&1 || true
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

# Best-effort — only does anything if MNEMON_EMBED_ENDPOINT is set in .env.
# Runs before the patch below so any warnings surface before the build
# proceeds, though the patch itself doesn't depend on the outcome here —
# the ENV lines get baked in regardless, this just tries to make sure
# there's something actually listening on the other end.
ensure_ollama_ready

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
    # /tmp:/tmp — same reasoning as NANOCLAW_INSTALL_PATH's identical-path
    # bind mount above (see the README's "Deployment Modes" section): any
    # path this container passes as a bind-mount *source* when spawning its
    # own sibling agent containers (via the shared docker.sock) is resolved
    # by the HOST's Docker daemon against the real host filesystem, not
    # this container's own view of it. OneCLI's SDK writes its per-agent CA
    # cert to a fixed /tmp path from inside this process, then bind-mounts
    # that same path into each new agent container — without /tmp shared
    # identically here, the write lands in this container's own private,
    # disconnected /tmp, while the daemon resolves the mount source against
    # the real host's (empty) /tmp instead, silently creating an empty
    # directory there. Confirmed directly against a live install: the cert
    # path inside a spawned agent container was an empty directory, not the
    # PEM file, causing every API call through the OneCLI proxy to fail
    # self-signed-certificate verification.
    $DOCKER run -d --name "$CONTAINER_NAME" --restart unless-stopped \
        -e NANOCLAW_INSTALL_PATH="$INSTALL_PATH" \
        -e CONTAINER_NAME="$CONTAINER_NAME" \
        -v "$INSTALL_PATH:$INSTALL_PATH" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v /tmp:/tmp \
        -p "$NANOCLAW_PORT:$NANOCLAW_PORT" \
        "$IMAGE_TAG" >/dev/null
fi

# Agent containers NanoClaw spawns reach the OneCLI gateway via Docker's
# `--add-host=host.docker.internal:host-gateway` convention, which OrbStack
# resolves to its own broken pseudo-address instead of the real bridge
# gateway (see patch-host-gateway.cjs's own header for the full story and
# how this was confirmed against a live install). Patch it every run —
# cheap and idempotent — piped straight into `node` inside the already-
# running container rather than baked into the image, so it applies
# immediately with no rebuild required. Exit code 2 means it just now
# freshly patched a previously-unpatched source tree; if dist/index.js was
# already built from that old source (an existing install, not a fresh
# one), rebuild and restart so the running service actually picks it up —
# otherwise the patched source just sits there unused until some other
# rebuild happens to come along.
# Exit-code capture must happen inside the `if` itself, not via a bare
# `cmd; rc=$?` pair — this script runs under `set -e`, which aborts on ANY
# nonzero exit that isn't already inside a conditional, and the patch
# script's own "freshly patched" signal (exit 2) is exactly that: a
# nonzero exit that isn't a real error. Confirmed the hard way: a CLEAN
# run died silently right after the patch's own success message, with no
# further output, because `set -e` killed the script before `patch_rc=$?`
# on the next line ever got a chance to run.
if $DOCKER exec -i "$CONTAINER_NAME" node - "$INSTALL_PATH" < "$SCRIPT_DIR/patch-host-gateway.cjs"; then
    patch_rc=0
else
    patch_rc=$?
fi
if [ "$patch_rc" -eq 2 ] && [ -f "${INSTALL_PATH}/dist/index.js" ]; then
    echo "🔄 Rebuilding NanoClaw to pick up the OrbStack host-gateway patch..."
    $DOCKER exec "$CONTAINER_NAME" bash -lc "cd '$INSTALL_PATH' && pnpm run build"
    $DOCKER exec "$CONTAINER_NAME" bash -lc "cd '$INSTALL_PATH' && bash start-nanoclaw.sh"
fi

# NanoClaw's own nohup fallback (setup/service.ts, used whenever there's no
# systemd/launchd — always true here) writes start-nanoclaw.sh but never
# runs it, so the wizard's own later steps (e.g. the cli-agent step, which
# pings data/cli.sock) hit a manual dead end mid-setup, every single fresh
# install — see patch-nohup-autostart.cjs's own header for the full story.
# setup/ scripts run directly via tsx with no build step, so this needs no
# rebuild to take effect, unlike the host-gateway patch above — applying it
# now, before any wizard run, is enough.
$DOCKER exec -i "$CONTAINER_NAME" node - "$INSTALL_PATH" < "$SCRIPT_DIR/patch-nohup-autostart.cjs" || true

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
    # nanoclaw.sh builds its own agent-sandbox image from inside this
    # container, over the mounted host docker.sock — its Dockerfile uses
    # --mount=type=cache, which needs BuildKit. `docker exec` never
    # forwards the host's DOCKER_BUILDKIT env var on its own, so without
    # this the docker CLI inside the container silently falls back to the
    # legacy builder and that build step fails outright.
    $DOCKER exec -it -e DOCKER_BUILDKIT=1 "$CONTAINER_NAME" bash -lc "cd '$INSTALL_PATH' && bash nanoclaw.sh"

    # NanoClaw's own setup, on any platform without systemd or launchd —
    # always true here, since this container has no init system at all
    # (see entrypoint.sh) — only *writes* start-nanoclaw.sh; its own
    # setupNohupFallback() explicitly reports SERVICE_LOADED: false and
    # stops there, verified directly against its source (setup/service.ts).
    # Nothing else in its setup flow ever actually runs that script, so
    # left alone the background service never starts and the wizard's own
    # first "ping/pong" health check fails before the service gets a
    # chance to. Start it ourselves once the wizard hands control back.
    if [ -f "${INSTALL_PATH}/start-nanoclaw.sh" ]; then
        echo "🚀 Starting NanoClaw's background service (nohup fallback)..."
        $DOCKER exec "$CONTAINER_NAME" bash -lc "cd '$INSTALL_PATH' && bash start-nanoclaw.sh"
    fi
fi

echo "ℹ️  NanoClaw has no web UI by default — describe problems in chat instead."
echo "   Want one? Its optional /add-dashboard skill reserves port ${NANOCLAW_PORT} for it."
echo "=========================================================="
bash "$REPO_DIR/lib/run-install-desktop.sh" "$SCRIPT_DIR" >/dev/null 2>&1 || true
bash "$REPO_DIR/lib/run-info.sh" "$SCRIPT_DIR" list
