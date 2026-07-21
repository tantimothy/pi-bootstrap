#!/usr/bin/env bash

# =======================================================================================
# NANOCLAW ENVIRONMENT ORCHESTRATOR (run.sh)
# NanoClaw is a host-level Node.js service — it manages its own Docker containers
# per conversation group. This script handles install, start, and rebuild lifecycle.
#
# Two deployment modes for the orchestrator process itself (NANOCLAW_DEPLOY_MODE):
#   "host"      — bare systemd (Linux) / launchd (macOS) service, full access to
#                 whatever the OS user account can read/write. Supports iMessage
#                 on macOS (the /add-imessage skill needs real Messages.app/TCC
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
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
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
# .env.example's own literal default (/home/pi/nanoclaw) is Pi-appropriate
# for this repo's primary target, but deploy.sh's TUI config form always
# writes a value for every .env.example key — even one nobody edited — so
# ${NANOCLAW_INSTALL_PATH:-$HOME/nanoclaw} above never actually triggers
# for anyone going through the TUI: NANOCLAW_INSTALL_PATH is never empty
# once .env exists. On macOS /home/pi doesn't exist at all (no `pi` user,
# no /home), so accepting that default as-is means every mkdir/git-clone
# below fails. Only overrides the exact, unmodified default — a deliberate
# custom path (even a Linux-style one) is left alone.
if [[ "$(uname)" == "Darwin" ]] && [ "$INSTALL_PATH" = "/home/pi/nanoclaw" ]; then
    INSTALL_PATH="$HOME/nanoclaw"
    echo "⚠️  NANOCLAW_INSTALL_PATH was still the Pi-only default (/home/pi/nanoclaw), which doesn't exist on macOS."
    echo "   Switching to \$HOME/nanoclaw ($INSTALL_PATH) and updating .env to match."
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
NANOCLAW_PORT="${NANOCLAW_PORT:-3080}"

DEPLOY_MODE="${NANOCLAW_DEPLOY_MODE:-}"
if [ -z "$DEPLOY_MODE" ]; then
    if [ "$OS_TYPE" = "macos" ]; then DEPLOY_MODE="container"; else DEPLOY_MODE="host"; fi
fi
echo "📦 Deploy mode: ${DEPLOY_MODE} (set NANOCLAW_DEPLOY_MODE in .env to override)"

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
        echo "🛑 Fresh image ready — tearing down the previous container and agent containers..."
        $DOCKER stop "$CONTAINER_NAME" 2>/dev/null || true
        $DOCKER rm   "$CONTAINER_NAME" 2>/dev/null || true
        AGENT_CONTAINERS=$($DOCKER ps -a --format '{{.ID}} {{.Image}}' 2>/dev/null \
            | awk '$2 ~ /^nanoclaw-agent-v2-/ {print $1}')
        if [ -n "$AGENT_CONTAINERS" ]; then
            echo "$AGENT_CONTAINERS" | xargs "$DOCKER" stop 2>/dev/null || true
            echo "$AGENT_CONTAINERS" | xargs "$DOCKER" rm   2>/dev/null || true
        fi
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
        # /tmp:/tmp — same reasoning as NANOCLAW_INSTALL_PATH's identical-
        # path bind mount above (see the README's "Deployment Modes"
        # section): any path this container passes as a bind-mount
        # *source* when spawning its own sibling agent containers (via the
        # shared docker.sock) is resolved by the HOST's Docker daemon
        # against the real host filesystem, not this container's own view
        # of it. OneCLI's SDK writes its per-agent CA cert to a fixed /tmp
        # path from inside this process, then bind-mounts that same path
        # into each new agent container — without /tmp shared identically
        # here, the write lands in this container's own private,
        # disconnected /tmp, while the daemon resolves the mount source
        # against the real host's (empty) /tmp instead, silently creating
        # an empty directory there. Confirmed directly against a live
        # install: the cert path inside a spawned agent container was an
        # empty directory, not the PEM file, causing every API call
        # through the OneCLI proxy to fail self-signed-certificate
        # verification.
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
    # `--add-host=host.docker.internal:host-gateway` convention, which
    # OrbStack resolves to its own broken pseudo-address instead of the real
    # bridge gateway (see patch-host-gateway.cjs's own header for the full
    # story and how this was confirmed against a live install). Patch it
    # every run — cheap and idempotent — piped straight into `node` inside
    # the already-running container rather than baked into the image, so it
    # applies immediately with no rebuild required. Covers an EXISTING
    # install here (src/ already cloned from a previous run); a fresh
    # install's own clone happens further down, with its own patch call
    # right after, since this one will just no-op (source not cloned yet).
    if $DOCKER exec "$CONTAINER_NAME" test -f "$INSTALL_PATH/src/container-runtime.ts" 2>/dev/null; then
        # Exit-code capture must happen inside the `if` itself, not via a
        # bare `cmd; rc=$?` pair — this script runs under `set -e`, which
        # aborts on ANY nonzero exit that isn't already inside a
        # conditional, and the patch script's own "freshly patched" signal
        # (exit 2) is exactly that: a nonzero exit that isn't a real error.
        # Confirmed the hard way: a CLEAN run died silently right after the
        # patch's own success message, with no further output, because
        # `set -e` killed the script before `patch_rc=$?` on the next line
        # ever got a chance to run.
        if $DOCKER exec -i "$CONTAINER_NAME" node - "$INSTALL_PATH" < "$SCRIPT_DIR/scripts/patch-host-gateway.cjs"; then
            patch_rc=0
        else
            patch_rc=$?
        fi

        # requestApproval() (src/modules/approvals/primitive.ts) silently
        # drops an approval card — logging apparent success — whenever
        # getDeliveryAdapter() returns falsy, instead of failing loudly.
        # Same bug, same fix, same idempotent patch mechanism as the
        # host-gateway patch just above — see
        # patch-approval-delivery.cjs's own header (and
        # nanoclaw-mnemon/run.sh, where this was actually found and fixed
        # first) for the full investigation.
        if $DOCKER exec -i "$CONTAINER_NAME" node - "$INSTALL_PATH" < "$SCRIPT_DIR/scripts/patch-approval-delivery.cjs"; then
            approval_patch_rc=0
        else
            approval_patch_rc=$?
        fi

        if [ "$patch_rc" -eq 2 ] || [ "$approval_patch_rc" -eq 2 ]; then
            echo "🔄 Rebuilding NanoClaw to pick up patched source (host-gateway and/or approval-delivery fix)..."
            $DOCKER exec "$CONTAINER_NAME" bash -lc "cd '$INSTALL_PATH' && pnpm run build"
            $DOCKER exec "$CONTAINER_NAME" bash -lc "cd '$INSTALL_PATH' && bash start-nanoclaw.sh"
        fi
        # NanoClaw's own nohup fallback (setup/service.ts) writes
        # start-nanoclaw.sh but never runs it, so the wizard's own later
        # steps (e.g. the cli-agent step, which pings data/cli.sock) hit a
        # manual dead end mid-setup, every single fresh install — see
        # patch-nohup-autostart.cjs's own header for the full story. No
        # rebuild needed (setup/ scripts run directly via tsx).
        $DOCKER exec -i "$CONTAINER_NAME" node - "$INSTALL_PATH" < "$SCRIPT_DIR/scripts/patch-nohup-autostart.cjs" || true
    fi

    # Sync NanoClaw's own source. A fresh install (no nanoclaw.sh yet)
    # always clones. An existing install: CLEAN hard-syncs to latest
    # upstream — replacing what used to be a `rm -rf "$INSTALL_PATH"` above
    # (see the CLEAN policy block higher up) that destroyed groups/, data/,
    # store/, and .env right along with the source, none of which are
    # NanoClaw's own source — matching the fix already applied to the
    # nanoclaw-mnemon environment (see that environment's run.sh for the
    # fuller writeup). FAST leaves an already-cloned install's source
    # alone entirely, same as before.
    SOURCE_SYNCED=false
    if [ ! -f "$INSTALL_PATH/nanoclaw.sh" ]; then
        echo "📥 Cloning NanoClaw repository to $INSTALL_PATH ..."
        git clone https://github.com/nanocoai/nanoclaw.git "$INSTALL_PATH"
        echo "✅ Clone complete."
        SOURCE_SYNCED=true
    elif [ ! -d "$INSTALL_PATH/.git" ]; then
        # Some backup/restore tools (confirmed: Time Machine) skip
        # invisible files/directories, so a restored install path can
        # have all its visible NanoClaw source back with no .git at
        # all — git refuses to `pull`/`reset` a directory that isn't
        # actually a repository. A fresh clone is the only fix;
        # preserve what actually matters by hand across it, since
        # there's no git history/.gitignore here to protect it.
        echo "⚠️  $INSTALL_PATH exists but has no .git directory — not a real git checkout. Re-cloning fresh, preserving .env/groups/data/store first..."
        PRESERVE_TMP=$(mktemp -d)
        for item in .env groups data store; do
            [ -e "${INSTALL_PATH}/${item}" ] && mv "${INSTALL_PATH}/${item}" "${PRESERVE_TMP}/${item}"
        done
        rm -rf "$INSTALL_PATH"
        git clone https://github.com/nanocoai/nanoclaw.git "$INSTALL_PATH"
        for item in .env groups data store; do
            [ -e "${PRESERVE_TMP}/${item}" ] && mv "${PRESERVE_TMP}/${item}" "${INSTALL_PATH}/${item}"
        done
        rmdir "$PRESERVE_TMP" 2>/dev/null || true
        echo "✅ Fresh clone complete, preserved data restored."
        echo "⚠️  If the same restore skipped invisible files/dirs, that applies inside groups/ too —"
        echo "   check groups/<group>/.env and groups/<group>/.claude/ for anything that may not"
        echo "   have actually come back with the rest."
        SOURCE_SYNCED=true
    elif [ "$POLICY" = "CLEAN" ]; then
        # Any channel/provider skill (e.g. /add-telegram, /add-whatsapp) wires
        # itself in by editing TRACKED trunk files — a self-registration
        # import appended to src/channels/index.ts, plus a new dependency
        # line in package.json (and pnpm-lock.yaml, if the skill's own
        # installer ran `pnpm install` afterward) — alongside copying in new
        # (untracked) source files for the channel itself. `reset --hard`
        # below only discards uncommitted changes to TRACKED files; it can't
        # touch those untracked new files at all. Confirmed the hard way on
        # nanoclaw-mnemon's identical setup: a live Telegram channel went
        # silently dead after a CLEAN — every telegram.ts-etc. file was still
        # on disk, but the barrel import wiring it in, and the package.json
        # dependency entry, had both been silently reverted, with no error
        # anywhere.
        #
        # Snapshot those local edits as a patch before the reset, then try
        # to reapply it afterward — restores the wiring automatically in
        # the common case (nothing upstream touched the same lines). Falls
        # back to the old warn-only behavior if the patch doesn't apply
        # cleanly rather than forcing a conflict onto an unattended CLEAN.
        CHANNEL_SKILL_MODS=$(git -C "$INSTALL_PATH" status --porcelain 2>/dev/null | grep -v '^??' || true)
        CHANNEL_SKILL_PATCH=""
        if [ -n "$CHANNEL_SKILL_MODS" ]; then
            echo "⚠️  CLEAN is about to discard local edits to these tracked files — likely a channel/provider skill's own wiring (e.g. /add-telegram's import in src/channels/index.ts or its package.json dependency):"
            echo "$CHANNEL_SKILL_MODS" | sed 's/^/     /'
            _tmp_patch=$(mktemp)
            if git -C "$INSTALL_PATH" diff HEAD > "$_tmp_patch" 2>/dev/null && [ -s "$_tmp_patch" ]; then
                CHANNEL_SKILL_PATCH="$_tmp_patch"
                echo "   Saved a patch of these edits — will try to reapply them automatically after the sync."
            else
                rm -f "$_tmp_patch"
            fi
        fi
        echo "🔄 [CLEAN POLICY] Hard-syncing NanoClaw source to latest upstream (your data — .env, groups/, data/, any scaffolded wiki — is untouched; only git-tracked source files are reset)..."
        git -C "$INSTALL_PATH" fetch origin
        git -C "$INSTALL_PATH" reset --hard '@{u}'
        if [ -n "$CHANNEL_SKILL_PATCH" ]; then
            if git -C "$INSTALL_PATH" apply --check "$CHANNEL_SKILL_PATCH" 2>/dev/null; then
                git -C "$INSTALL_PATH" apply "$CHANNEL_SKILL_PATCH"
                echo "✅ Reapplied the local edits CLEAN would otherwise have discarded (channel/provider skill wiring) on top of the freshly-synced source."
                rm -f "$CHANNEL_SKILL_PATCH"
            else
                echo "⚠️  Couldn't automatically reapply those edits — upstream likely changed the same lines. Re-run the relevant channel/provider skill (e.g. /add-telegram) to restore it manually. The saved patch is still at: $CHANNEL_SKILL_PATCH"
            fi
        fi
        SOURCE_SYNCED=true
    fi

    if [ "$SOURCE_SYNCED" = "true" ]; then
        $DOCKER exec -i "$CONTAINER_NAME" node - "$INSTALL_PATH" < "$SCRIPT_DIR/scripts/patch-host-gateway.cjs" || true
        $DOCKER exec -i "$CONTAINER_NAME" node - "$INSTALL_PATH" < "$SCRIPT_DIR/scripts/patch-approval-delivery.cjs" || true
        $DOCKER exec -i "$CONTAINER_NAME" node - "$INSTALL_PATH" < "$SCRIPT_DIR/scripts/patch-nohup-autostart.cjs" || true
    fi

    # If this sync updated an install that was already built, rebuild from
    # the fresh source and restart in place — otherwise the newly-synced
    # code just sits there unused. The wizard block below only ever
    # triggers on a truly fresh install (dist/index.js still missing).
    if [ "$SOURCE_SYNCED" = "true" ] && $DOCKER exec "$CONTAINER_NAME" test -f "$INSTALL_PATH/dist/index.js" 2>/dev/null; then
        echo "🔄 [CLEAN POLICY] Rebuilding NanoClaw from the freshly-synced source..."
        $DOCKER exec "$CONTAINER_NAME" bash -lc "cd '$INSTALL_PATH' && pnpm install && pnpm run build"
        $DOCKER exec "$CONTAINER_NAME" bash -lc "cd '$INSTALL_PATH' && bash start-nanoclaw.sh"

        # The rebuild above only covers NanoClaw's own orchestrator (`pnpm
        # run build` — a plain `tsc` compile of the host-side TS). It does
        # NOT rebuild the agent-sandbox Docker image
        # (`nanoclaw-agent-v2-<slug>:latest`, built from
        # container/Dockerfile) — a completely separate artifact. A fresh
        # install's own nanoclaw.sh wizard builds that once during
        # first-time setup, but re-syncing an EXISTING install's source
        # here just leaves whatever upstream changed in container/Dockerfile
        # (new tools, base-image bumps, security fixes) sitting unused —
        # every group's agent containers keep spawning from the image that
        # was built the last time this actually ran. See the equivalent
        # comment in nanoclaw-mnemon's run.sh (where this was actually
        # caught, via its own Dockerfile patches silently never taking
        # effect) for the full story. container/build.sh is NanoClaw's own
        # sanctioned entry point for this — its provider-switch step in
        # setup/auto.ts calls it the same way when it needs to rebuild
        # post-container-step.
        if [ -f "${INSTALL_PATH}/container/build.sh" ]; then
            echo "🛠️  Rebuilding the NanoClaw agent-sandbox image..."
            # BuildKit cache mounts in container/Dockerfile need
            # DOCKER_BUILDKIT=1 — docker exec never forwards the host's env
            # on its own (same reasoning as the nanoclaw.sh wizard call
            # further below).
            $DOCKER exec -e DOCKER_BUILDKIT=1 "$CONTAINER_NAME" bash -lc "bash '$INSTALL_PATH/container/build.sh'" \
                || echo "⚠️  Agent-sandbox image rebuild failed — upstream Dockerfile changes won't take effect until this succeeds. See the build output above." >&2
        else
            echo "⚠️  ${INSTALL_PATH}/container/build.sh not found — skipping the agent-sandbox image rebuild." >&2
        fi
    fi

    if ! $DOCKER exec "$CONTAINER_NAME" test -f "$INSTALL_PATH/dist/index.js" 2>/dev/null; then
        echo ""
        echo "🧙 Handing off to the NanoClaw interactive setup wizard (inside the container)..."
        echo "   The wizard will ask for your Anthropic API key, channel setup, and more."
        echo "   iMessage isn't offered in container mode — see the README."
        echo ""
        exec 0< /dev/tty
        exec 1> /dev/tty
        exec 2> /dev/tty
        # nanoclaw.sh builds its own agent-sandbox image from inside this
        # container, over the mounted host docker.sock — its Dockerfile uses
        # --mount=type=cache, which needs BuildKit. `docker exec` never
        # forwards the host's DOCKER_BUILDKIT env var on its own, so without
        # this the docker CLI inside the container silently falls back to
        # the legacy builder and that build step fails outright.
        $DOCKER exec -it -e DOCKER_BUILDKIT=1 "$CONTAINER_NAME" bash -lc "cd '$INSTALL_PATH' && bash nanoclaw.sh"

        # NanoClaw's own setup, on any platform without systemd or launchd
        # — always true here, since this container has no init system at
        # all (see entrypoint.sh) — only *writes* start-nanoclaw.sh; its
        # own setupNohupFallback() explicitly reports SERVICE_LOADED: false
        # and stops there, verified directly against its source
        # (setup/service.ts). Nothing else in its setup flow ever actually
        # runs that script, so left alone the background service never
        # starts and the wizard's own first "ping/pong" health check fails
        # before the service gets a chance to. Start it ourselves once the
        # wizard hands control back.
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
    bash "$REPO_DIR/lib/run-install-desktop.sh" "$SCRIPT_DIR" >/dev/null 2>&1 || true
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
        echo "ℹ️  NanoClaw has no web UI by default — describe problems in chat instead."
        echo "   Want one? Its optional /add-dashboard skill reserves port ${NANOCLAW_PORT} for it."
        echo "=========================================================="
        # Best-effort refresh in case NANOCLAW_PORT (or anything else read
        # from .env) changed since entries were last installed.
        bash "$REPO_DIR/lib/run-install-desktop.sh" "$SCRIPT_DIR" >/dev/null 2>&1 || true
        exit 0
    fi

    # Service registered but not running — start it
    if nanoclaw_service_exists; then
        echo "🔄 [FAST POLICY] NanoClaw is installed but stopped. Starting..."
        nanoclaw_start
        echo "✅ NanoClaw started."
        echo "ℹ️  NanoClaw has no web UI by default — describe problems in chat instead."
        echo "   Want one? Its optional /add-dashboard skill reserves port ${NANOCLAW_PORT} for it."
        echo "=========================================================="
        bash "$REPO_DIR/lib/run-install-desktop.sh" "$SCRIPT_DIR" >/dev/null 2>&1 || true
        exit 0
    fi
fi

# ---------------------------------------------------------------------------------------
# 4. CLEAN policy: stop service, remove agent containers
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

    echo "✅ Service and agent containers stopped. Source sync happens below."
fi

# ---------------------------------------------------------------------------------------
# 5. Clone or sync NanoClaw's own source, then run the interactive nanoclaw.sh wizard
#
# This used to `rm -rf "$INSTALL_PATH"` in the CLEAN block above, then
# unconditionally clone fresh here — destroying groups/, data/, store/, and
# .env right along with the source, none of which are NanoClaw's own
# source. Matches the fix already applied to the container-mode branch
# above and to the nanoclaw-mnemon environment: CLEAN now hard-syncs via
# `git reset --hard` instead, which only ever touches git-tracked files.
# ---------------------------------------------------------------------------------------
if [ ! -d "$INSTALL_PATH" ] || [ ! -f "$INSTALL_PATH/nanoclaw.sh" ]; then
    echo "📥 Cloning NanoClaw repository to $INSTALL_PATH ..."
    git clone https://github.com/nanocoai/nanoclaw.git "$INSTALL_PATH"
    echo "✅ Clone complete."
elif [ ! -d "$INSTALL_PATH/.git" ]; then
    # Some backup/restore tools (confirmed: Time Machine) skip invisible
    # files/directories, so a restored install path can have all its
    # visible NanoClaw source back with no .git at all — git refuses to
    # `pull`/`reset` a directory that isn't actually a repository. A fresh
    # clone is the only fix; preserve what actually matters by hand across
    # it, since there's no git history/.gitignore here to protect it.
    echo "⚠️  $INSTALL_PATH exists but has no .git directory — not a real git checkout. Re-cloning fresh, preserving .env/groups/data/store first..."
    PRESERVE_TMP=$(mktemp -d)
    for item in .env groups data store; do
        [ -e "${INSTALL_PATH}/${item}" ] && mv "${INSTALL_PATH}/${item}" "${PRESERVE_TMP}/${item}"
    done
    rm -rf "$INSTALL_PATH"
    git clone https://github.com/nanocoai/nanoclaw.git "$INSTALL_PATH"
    for item in .env groups data store; do
        [ -e "${PRESERVE_TMP}/${item}" ] && mv "${PRESERVE_TMP}/${item}" "${INSTALL_PATH}/${item}"
    done
    rmdir "$PRESERVE_TMP" 2>/dev/null || true
    echo "✅ Fresh clone complete, preserved data restored."
    echo "⚠️  If the same restore skipped invisible files/dirs, that applies inside groups/ too —"
    echo "   check groups/<group>/.env and groups/<group>/.claude/ for anything that may not"
    echo "   have actually come back with the rest."
elif [ "$POLICY" = "CLEAN" ]; then
    # Any channel/provider skill (e.g. /add-telegram, /add-whatsapp) wires
    # itself in by editing TRACKED trunk files — a self-registration import
    # appended to src/channels/index.ts, plus a new dependency line in
    # package.json (and pnpm-lock.yaml, if the skill's own installer ran
    # `pnpm install` afterward) — alongside copying in new (untracked)
    # source files for the channel itself. `reset --hard` below only
    # discards uncommitted changes to TRACKED files; it can't touch those
    # untracked new files at all. Confirmed the hard way on
    # nanoclaw-mnemon's identical setup: a live Telegram channel went
    # silently dead after a CLEAN — every telegram.ts-etc. file was still
    # on disk, but the barrel import wiring it in, and the package.json
    # dependency entry, had both been silently reverted, with no error
    # anywhere.
    #
    # Snapshot those local edits as a patch before the reset, then try to
    # reapply it afterward — restores the wiring automatically in the
    # common case (nothing upstream touched the same lines). Falls back to
    # the old warn-only behavior if the patch doesn't apply cleanly rather
    # than forcing a conflict onto an unattended CLEAN.
    CHANNEL_SKILL_MODS=$(git -C "$INSTALL_PATH" status --porcelain 2>/dev/null | grep -v '^??' || true)
    CHANNEL_SKILL_PATCH=""
    if [ -n "$CHANNEL_SKILL_MODS" ]; then
        echo "⚠️  CLEAN is about to discard local edits to these tracked files — likely a channel/provider skill's own wiring (e.g. /add-telegram's import in src/channels/index.ts or its package.json dependency):"
        echo "$CHANNEL_SKILL_MODS" | sed 's/^/     /'
        _tmp_patch=$(mktemp)
        if git -C "$INSTALL_PATH" diff HEAD > "$_tmp_patch" 2>/dev/null && [ -s "$_tmp_patch" ]; then
            CHANNEL_SKILL_PATCH="$_tmp_patch"
            echo "   Saved a patch of these edits — will try to reapply them automatically after the sync."
        else
            rm -f "$_tmp_patch"
        fi
    fi
    echo "🔄 [CLEAN POLICY] Hard-syncing NanoClaw source to latest upstream (your data — .env, groups/, data/, any scaffolded wiki — is untouched; only git-tracked source files are reset)..."
    git -C "$INSTALL_PATH" fetch origin
    git -C "$INSTALL_PATH" reset --hard '@{u}'
    if [ -n "$CHANNEL_SKILL_PATCH" ]; then
        if git -C "$INSTALL_PATH" apply --check "$CHANNEL_SKILL_PATCH" 2>/dev/null; then
            git -C "$INSTALL_PATH" apply "$CHANNEL_SKILL_PATCH"
            echo "✅ Reapplied the local edits CLEAN would otherwise have discarded (channel/provider skill wiring) on top of the freshly-synced source."
            rm -f "$CHANNEL_SKILL_PATCH"
        else
            echo "⚠️  Couldn't automatically reapply those edits — upstream likely changed the same lines. Re-run the relevant channel/provider skill (e.g. /add-telegram) to restore it manually. The saved patch is still at: $CHANNEL_SKILL_PATCH"
        fi
    fi
else
    echo "📦 Install path exists. Pulling latest changes..."
    git -C "$INSTALL_PATH" pull --ff-only || echo "⚠️  Git pull skipped (local changes or detached HEAD)."
fi

# requestApproval() (src/modules/approvals/primitive.ts) silently drops an
# approval card — logging apparent success — whenever getDeliveryAdapter()
# returns falsy, instead of failing loudly. Same bug as the container-mode
# branch above patches (see patch-approval-delivery.cjs's own header, and
# nanoclaw-mnemon/run.sh where this was actually found and fixed first) —
# plain application logic, not container/OrbStack-specific, so host mode
# needs it too. No `docker exec` wrapper here: NanoClaw's own orchestrator
# process isn't containerized in host mode, so this runs directly against
# $INSTALL_PATH on the host, the same place `bash nanoclaw.sh` below will
# build from. No separate rebuild/restart dance needed either — the wizard
# call right after this always (re)builds from whatever's on disk.
node "$SCRIPT_DIR/scripts/patch-approval-delivery.cjs" "$INSTALL_PATH" || true

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
bash "$REPO_DIR/lib/run-install-desktop.sh" "$SCRIPT_DIR" >/dev/null 2>&1 || true
bash "$REPO_DIR/lib/run-info.sh" "$SCRIPT_DIR" list
