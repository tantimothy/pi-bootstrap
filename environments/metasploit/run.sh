#!/bin/bash

# ==============================================================================
# PIPELINE ARCHITECTURE INHERITANCE & WRAPPERS
# ==============================================================================
# Inherit root permission wrappers natively
DOCKER=${DOCKER_CMD:-docker}

# Determine script context execution paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Target Image Assignment
IMAGE_NAME="pi-metasploit:latest"

# Marks that this environment has actually been launched at least once.
# A lingering docker image alone (e.g. left over from a one-off build/test,
# or TEARDOWN having removed the container but not the image) isn't a
# reliable "deployed" signal — install-desktop.sh checks this marker instead.
DEPLOYED_MARKER="$SCRIPT_DIR/.deployed"

# ==============================================================================
# CONFIGURATION ACQUISITION & POLICY EXTRACTION
# ==============================================================================
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
else
    echo "❌ Error: .env file missing." >&2
    echo "   Copy .env.example to .env and fill in the values, then re-run." >&2
    exit 1
fi

# Ensure CONTAINER_NAME variable was correctly ingested from workspace settings
if [ -z "$CONTAINER_NAME" ]; then
    CONTAINER_NAME="running-metasploit-rig"
fi

# Resolved early (rather than just before the docker run below) so the config
# drift fingerprint further down can include them.
FINAL_MSF_DATA_PATH="${HOST_MSF_DATA_PATH:-$SCRIPT_DIR/.msf4}"
DISPLAY="${DISPLAY:-:0}"
HOST_X11_UNIX_PATH="${HOST_X11_UNIX_PATH:-/tmp/.X11-unix}"

# --- CONFIG DRIFT DETECTION ---
# Fingerprints the values that feed into the `docker run` invocation at the
# bottom of this script. FAST's shortcut below reattaches to an already-
# running container without recreating it — if one of these values changed
# since that container was created, the existing container would otherwise
# silently keep running with stale config. This hash lets FAST notice that.
CONFIG_HASH_FILE="$SCRIPT_DIR/.container-config-hash"
CONFIG_FINGERPRINT="${IMAGE_NAME}|${START_METASPLOIT_DB:-true}|${FINAL_MSF_DATA_PATH}|${DISPLAY}|${HOST_X11_UNIX_PATH}"
CONFIG_HASH=$(printf '%s' "$CONFIG_FINGERPRINT" | sha256sum | awk '{print $1}')
CONFIG_DRIFTED=false
if [ -f "$CONFIG_HASH_FILE" ] && [ "$(cat "$CONFIG_HASH_FILE")" != "$CONFIG_HASH" ]; then
    CONFIG_DRIFTED=true
fi

# Determine active state processing choice (Fallback safely to FAST)
POLICY="${REBUILD_POLICY:-FAST}"

# deploy_environment() (lib/deploy-lib.sh) deliberately doesn't wrap run.sh
# in its own `script`-based session logging — see that function's own
# comment. This environment has no interactive attach of its own
# (msfconsole/Armitage are each reachable via a custom_action, not from
# here), so the whole rest of this script is safe to self-log unconditionally.
source "$REPO_DIR/lib/deploy-lib.sh"
_selflog_start "$SCRIPT_DIR" "$POLICY"

echo "📋 Active Environment Deployment Strategy: [$POLICY]"

# STOP: pause container (keep it, FAST can resume)
if [ "$POLICY" = "STOP" ]; then
    echo "🛑 [STOP] Pausing container: $CONTAINER_NAME"
    $DOCKER stop "$CONTAINER_NAME" 2>/dev/null || true
    echo "✅ Container paused. Run with FAST to resume."
    exit 0
fi

# TEARDOWN: stop + remove container, no reinstall
if [ "$POLICY" = "TEARDOWN" ]; then
    echo "🗑️  [TEARDOWN] Stopping and removing container: $CONTAINER_NAME"
    $DOCKER stop "$CONTAINER_NAME" 2>/dev/null || true
    $DOCKER rm   "$CONTAINER_NAME" 2>/dev/null || true
    rm -f "$DEPLOYED_MARKER"
    rm -f "$CONFIG_HASH_FILE"
    # Best-effort — immediately removes now-stale desktop entries rather than
    # leaving them until the next manual install-desktop-entries.sh run.
    bash "$REPO_DIR/lib/run-install-desktop.sh" "$SCRIPT_DIR" >/dev/null 2>&1 || true
    echo "✅ Container removed."
    exit 0
fi

# ==============================================================================
# ENGINE STATE INVENTORY SURVEYS
# ==============================================================================
CONTAINER_RUNNING=$($DOCKER ps -q -f name=^/${CONTAINER_NAME}$)
CONTAINER_EXISTS=$($DOCKER ps -a -q -f name=^/${CONTAINER_NAME}$)
IMAGE_EXISTS=$($DOCKER images -q "$IMAGE_NAME" 2>/dev/null)

# ==============================================================================
# POLICY ROUTING STATE MACHINE
# ==============================================================================

# POLICY CHOICE: FAST optimization shortcut (Container actively alive)
# No interactive attach here — msfconsole and Armitage are each reachable
# through their own custom_action ("Metasploit Framework (Console)",
# "Launch Armitage (GUI)") instead of an in-container menu, so this
# environment behaves like the generic docker-compose.yml/Dockerfile
# fallback archetype: deploy or reconcile, print the INFO summary, then
# return to deploy.sh's own menu.
if [ "$POLICY" = "FAST" ] && [ -n "$CONTAINER_RUNNING" ]; then
    if [ "$CONFIG_DRIFTED" = "true" ]; then
        echo "⚠️  [DRIFT] run.sh config (DISPLAY, X11 socket path, etc.) has changed since this container was created."
        echo "   Not killing your active session automatically — run TEARDOWN then FAST (or CLEAN) to pick up the new config."
    fi
    echo "✅ [FAST Policy] Container '$CONTAINER_NAME' is already running."
    _selflog_stop  # INFO summary itself is unlogged, same as the outer INFO policy
    bash "$REPO_DIR/lib/run-info.sh" "$SCRIPT_DIR" list
    exit 0
fi

# ==============================================================================
# DEPLOYMENT TEARDOWN LAYER (non-CLEAN/REBUILD only)
# ==============================================================================
# For CLEAN and REBUILD this is deferred until after a successful build
# below, so a failed build doesn't leave nothing running at all — the
# previous working container stays up until the replacement is ready.
if [ "$POLICY" != "CLEAN" ] && [ "$POLICY" != "REBUILD" ] && [ -n "$CONTAINER_EXISTS" ]; then
    echo "🛑 Tearing down conflicting container instances of $CONTAINER_NAME..."
    $DOCKER stop "$CONTAINER_NAME" >/dev/null 2>&1
    $DOCKER rm "$CONTAINER_NAME" >/dev/null 2>&1
fi

# Switch working context directory to find local Dockerfiles cleanly
cd "$SCRIPT_DIR" || exit 1

# ==============================================================================
# ADVANCED SYSTEM COMPILATION BRANCHING
# ==============================================================================
# REBUILD sits between FAST (never builds once an image exists) and CLEAN
# (--no-cache, reinstalls every apt package from scratch): it's a normal
# cached `docker build`, so Docker only replays layers from the first
# changed instruction onward. Use it for entrypoint.sh/run.sh edits; reach
# for CLEAN only when the Dockerfile's own package list changed.
if [ "$POLICY" = "CLEAN" ] || [ "$POLICY" = "REBUILD" ]; then
    if [ "$POLICY" = "CLEAN" ]; then
        echo "🛠️ [CLEAN Policy] Triggering pristine, zero-cache structural compilation..."
        $DOCKER build --no-cache -t "$IMAGE_NAME" .
    else
        echo "🔧 [REBUILD Policy] Rebuilding with Docker's layer cache (menu/script edits only)..."
        $DOCKER build -t "$IMAGE_NAME" .
    fi
    BUILD_STATUS=$?

    if [ "$BUILD_STATUS" -eq 0 ] && [ -n "$CONTAINER_EXISTS" ]; then
        # Build succeeded — safe to tear down the previous container now.
        # (The build already retagged $IMAGE_NAME onto the new image,
        # leaving the old one dangling rather than deleting it.)
        echo "🛑 Tearing down previous container instance of $CONTAINER_NAME..."
        $DOCKER stop "$CONTAINER_NAME" >/dev/null 2>&1
        $DOCKER rm "$CONTAINER_NAME" >/dev/null 2>&1
    fi

    # Cleans up the now-dangling previous image retagged over above. -f only
    # removes untagged images, never anything still referenced by a container.
    $DOCKER image prune -f >/dev/null 2>&1 || true

elif [ -z "$IMAGE_EXISTS" ]; then
    echo "⚠️ Target image cache empty. Executing standard local layer compilation..."
    $DOCKER build -t "$IMAGE_NAME" .
    BUILD_STATUS=$?
else
    echo "📦 [FAST Policy] Found matching cached image layers. Bypassing compilation array!"
    BUILD_STATUS=0
fi

# Handle build failure gates safely
if [ "$BUILD_STATUS" -ne 0 ]; then
    echo "❌ ERROR: Local architecture compilation failed!"
    exit 1
fi

# ==============================================================================
# PRE-EMPTIVE USER VOLUME STORAGE PROVISIONING
# ==============================================================================
echo "📁 Pre-emptively provisioning host volume directories to preserve local permissions..."
mkdir -p "$FINAL_MSF_DATA_PATH"

# ==============================================================================
# CONTAINER STARTUP (headless — no interactive attach, see the FAST
# shortcut's own comment above for why)
# ==============================================================================

# Record that this environment has actually been launched (see DEPLOYED_MARKER above)
touch "$DEPLOYED_MARKER"

# Refresh desktop entries now that the container (and its launch-armitage.sh
# entry) is about to actually exist. Best-effort: never blocks the deploy.
bash "$REPO_DIR/lib/run-install-desktop.sh" "$SCRIPT_DIR" >/dev/null 2>&1 || true

# Record the config this container is about to be launched with (see CONFIG
# DRIFT DETECTION above) so a future FAST run can tell if run.sh's settings
# have changed since.
echo "$CONFIG_HASH" > "$CONFIG_HASH_FILE"

# No --rm: this container persists across FAST reconciles, and
# STOP/TEARDOWN/CLEAN already manage its removal explicitly. Its real
# ENTRYPOINT (the sleep loop in the Dockerfile) just keeps it alive for
# `docker exec` (the "Metasploit Framework (Console)"/"Open Bash Shell"/
# "Launch Armitage (GUI)" actions) to reach later.
$DOCKER run -d \
  --net=host \
  -e DISPLAY="${DISPLAY}" \
  -v "${HOST_X11_UNIX_PATH}:/tmp/.X11-unix" \
  -v "$FINAL_MSF_DATA_PATH:/root/.msf4" \
  -e START_METASPLOIT_DB="${START_METASPLOIT_DB:-true}" \
  --name "$CONTAINER_NAME" \
  "$IMAGE_NAME" >/dev/null
START_STATUS=$?

if [ "$START_STATUS" -ne 0 ]; then
    echo "❌ ERROR: Failed to start container." >&2
    exit "$START_STATUS"
fi

echo "🚀 Container '$CONTAINER_NAME' is running."
_selflog_stop  # INFO summary itself is unlogged, same as the outer INFO policy
bash "$REPO_DIR/lib/run-info.sh" "$SCRIPT_DIR" list
exit 0
