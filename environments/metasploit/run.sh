#!/bin/bash

DOCKER=${DOCKER_CMD:-docker}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_DIR/lib/custom-docker-run-lib.sh"

IMAGE_NAME="pi-metasploit:latest"

# Marks that this environment has actually been launched at least once.
# A lingering docker image alone (e.g. left over from a one-off build/test,
# or TEARDOWN having removed the container but not the image) isn't a
# reliable "deployed" signal — install-desktop.sh checks this marker instead.
DEPLOYED_MARKER="$SCRIPT_DIR/.deployed"

_custom_run_source_env

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
_custom_run_config_hash "${IMAGE_NAME}|${START_METASPLOIT_DB:-true}|${FINAL_MSF_DATA_PATH}|${DISPLAY}|${HOST_X11_UNIX_PATH}"

POLICY="${REBUILD_POLICY:-FAST}"

# deploy_environment() (lib/deploy-lib.sh) deliberately doesn't wrap run.sh
# in its own `script`-based session logging — see that function's own
# comment. This environment has no interactive attach of its own
# (msfconsole/Armitage are each reachable via a custom_action, not from
# here), so the whole rest of this script is safe to self-log unconditionally.
source "$REPO_DIR/lib/deploy-lib.sh"
_selflog_start "$SCRIPT_DIR" "$POLICY"

echo "📋 Active Environment Deployment Strategy: [$POLICY]"

_custom_run_handle_stop_teardown
_custom_run_query_state

# FAST optimization shortcut: container already running.
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
    _custom_run_mark_deployed
    _selflog_stop  # INFO summary itself is unlogged, same as the outer INFO policy
    bash "$REPO_DIR/lib/run-info.sh" "$SCRIPT_DIR" list
    exit 0
fi

_custom_run_teardown_conflicting

# Switch working context directory to find local Dockerfiles cleanly
cd "$SCRIPT_DIR" || exit 1

_custom_run_build_image

echo "📁 Pre-emptively provisioning host volume directories to preserve local permissions..."
mkdir -p "$FINAL_MSF_DATA_PATH"

# Container startup (headless — no interactive attach, see the FAST
# shortcut's own comment above for why).

# Record that this environment has actually been launched, and refresh its
# desktop entries now that the container (and its launch-armitage.sh entry) is about
# to actually exist. Best-effort: never blocks the deploy.
_custom_run_mark_deployed

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
