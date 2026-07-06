#!/bin/bash
# ==============================================================================
# SUBFOLDER EXECUTION BLUEPRINT: DRAGONOS SDR CORE WORKSPACE LAYER
# ==============================================================================
# System Architecture Archetype: 1 (Custom Orchestration Shell)
# Mode: Dynamic Interactive Framework / Pipeline Overridden TTY Compatible
# Compatibility Layer: Dynamic Rebuild Strategy / TUI Secret Forms Integration
# ==============================================================================

set -eo pipefail

# --- ARCHETYPE RULE 1: INHERITED WRAPPERS ---
DOCKER="${DOCKER_CMD:-docker}"

# --- ARCHETYPE RULE 3: SECRET ACQUISITION ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/.env" ]; then
    echo "[INFO] Ingesting dynamic environment configurations from local .env context..."
    set -a
    source "${SCRIPT_DIR}/.env"
    set +a
else
    echo "[WARN] No .env found at ${SCRIPT_DIR}/.env — using built-in defaults."
    echo "       To customise, copy .env.example to .env and fill in the values."
fi

# Fallback Environment Configurations
CONTAINER_NAME="${CONTAINER_NAME:-sdr-dragonos-core}"
DOCKER_IMAGE_TAG="${DOCKER_IMAGE_TAG:-dragonos-pi}"
# Marks that this environment has actually been launched at least once.
# Containers here run with --rm, so a lingering docker image (which can be
# left over from a one-off build/test) isn't a reliable "deployed" signal —
# install-desktop.sh checks this marker instead.
DEPLOYED_MARKER="${SCRIPT_DIR}/.deployed"
DISPLAY="${DISPLAY:-:0}"
HOST_USB_BUS_PATH="${HOST_USB_BUS_PATH:-/dev/bus/usb}"
HOST_X11_UNIX_PATH="${HOST_X11_UNIX_PATH:-/tmp/.X11-unix}"
HOST_SOUND_DEVICE="${HOST_SOUND_DEVICE:-/dev/snd}"
HOST_PULSE_NATIVE_SOCKET="${HOST_PULSE_NATIVE_SOCKET:-/run/user/1000/pulse/native}"
HOST_PULSE_COOKIE_PATH="${HOST_PULSE_COOKIE_PATH:-~/.config/pulse/cookie}"
CONTAINER_ENTRYPOINT_COMMAND="${CONTAINER_ENTRYPOINT_COMMAND:-/usr/local/bin/sdr-menu.sh}"

# Persistent volume application configurations
HOST_CAPTURES_PATH="${HOST_CAPTURES_PATH:-./workspace/captures}"
HOST_MSF_DATA_PATH="${HOST_MSF_DATA_PATH:-./workspace/msf_data}"

# --- CONFIG DRIFT DETECTION ---
# Fingerprints the values that feed into the `docker run` invocation at the
# bottom of this script. FAST's shortcuts below normally reattach to (or
# `docker start`) an existing container without recreating it — if one of
# these values changed since that container was created (a different USB
# bus path, sound device, entrypoint, etc.), the existing container would
# otherwise silently keep running with stale config. This hash lets FAST
# notice that and reconcile instead.
CONFIG_HASH_FILE="${SCRIPT_DIR}/.container-config-hash"
CONFIG_FINGERPRINT="${DOCKER_IMAGE_TAG}|${HOST_USB_BUS_PATH}|${DISPLAY}|${HOST_X11_UNIX_PATH}|${HOST_SOUND_DEVICE}|${HOST_PULSE_NATIVE_SOCKET}|${HOST_PULSE_COOKIE_PATH}|${CONTAINER_ENTRYPOINT_COMMAND}|${HOST_CAPTURES_PATH}|${HOST_MSF_DATA_PATH}"
CONFIG_HASH=$(printf '%s' "${CONFIG_FINGERPRINT}" | sha256sum | awk '{print $1}')
CONFIG_DRIFTED=false
if [ -f "${CONFIG_HASH_FILE}" ] && [ "$(cat "${CONFIG_HASH_FILE}")" != "${CONFIG_HASH}" ]; then
    CONFIG_DRIFTED=true
fi

# --- ARCHITECTURAL SAFEGUARD: PRE-EMPTIVE VOLUME GENERATION ---
echo "[PRE-FLIGHT] Applying Pre-emptive Directory Creation Constraints on volume paths..."
mkdir -p "${HOST_CAPTURES_PATH}"
mkdir -p "${HOST_MSF_DATA_PATH}"

# --- ENGINE DESIGN MATRIX: POLICY AUTOMATION ROUTING ---
POLICY="${REBUILD_POLICY:-FAST}"
echo "[POLICY] Ingesting central orchestration lifecycle strategy: [${POLICY}]"

# STOP: pause container (keep it, FAST can resume)
if [ "${POLICY}" = "STOP" ]; then
    echo "🛑 [STOP] Pausing container: ${CONTAINER_NAME}"
    "${DOCKER}" stop "${CONTAINER_NAME}" 2>/dev/null || true
    echo "✅ Container paused. Run with FAST to resume."
    exit 0
fi

# TEARDOWN: stop + remove container, no reinstall
if [ "${POLICY}" = "TEARDOWN" ]; then
    echo "🗑️  [TEARDOWN] Stopping and removing container: ${CONTAINER_NAME}"
    "${DOCKER}" stop "${CONTAINER_NAME}" 2>/dev/null || true
    "${DOCKER}" rm   "${CONTAINER_NAME}" 2>/dev/null || true
    rm -f "${DEPLOYED_MARKER}"
    rm -f "${CONFIG_HASH_FILE}"
    echo "✅ Container removed."
    exit 0
fi

CONTAINER_RUNNING=$("${DOCKER}" ps --filter "name=^\/${CONTAINER_NAME}$" --format "{{.Names}}")
CONTAINER_EXISTS=$("${DOCKER}" ps -a --filter "name=^\/\${CONTAINER_NAME}$" --format "{{.Names}}")
IMAGE_EXISTS=$("${DOCKER}" images -q "${DOCKER_IMAGE_TAG}" 2>/dev/null || true)

if [ "${POLICY}" = "FAST" ]; then
    if [ -n "${CONTAINER_RUNNING}" ]; then
        if [ "${CONFIG_DRIFTED}" = "true" ]; then
            echo "[DRIFT] ⚠️  run.sh config (USB/audio/display paths, entrypoint, etc.) has changed since this container was created."
            echo "[DRIFT]    Not killing your active session automatically — run TEARDOWN then FAST (or CLEAN) to pick up the new config."
        fi
        echo "[BYPASS] FAST Policy Engaged: Container '${CONTAINER_NAME}' is currently active."
        echo "[LIFECYCLE] Attaching your session to the existing interactive container environment..."
        exec "${DOCKER}" exec -it "${CONTAINER_NAME}" "${CONTAINER_ENTRYPOINT_COMMAND}"
        exit 0
    fi

    # A dormant (stopped, not removed) container isn't actively attached to
    # anyone, so it's safe to reconcile automatically rather than just warn.
    if [ -n "${CONTAINER_EXISTS}" ] && [ "${CONFIG_DRIFTED}" = "true" ]; then
        echo "[DRIFT] run.sh config changed since this dormant container was created — recreating with current settings..."
        "${DOCKER}" rm "${CONTAINER_NAME}" >/dev/null 2>&1 || true
        CONTAINER_EXISTS=""
    fi

    if [ -z "${CONTAINER_RUNNING}" ] && [ -n "${CONTAINER_EXISTS}" ] && [ -n "${IMAGE_EXISTS}" ]; then
        echo "[SHORTCUT] FAST Policy Engaged: Dormant container detected with complete cache layers."
        echo "[LIFECYCLE] Executing non-destructive restoration shortcut sequence..."
        "${DOCKER}" start "${CONTAINER_NAME}" >/dev/null
        exec "${DOCKER}" attach "${CONTAINER_NAME}"
        exit 0
    fi
fi

# --- STATE TEARDOWN AND IMAGE COMPILE ROUTING ---
if [ "${POLICY}" = "CLEAN" ]; then
    echo "[PURGE] CLEAN Policy Engaged: Compiling a fresh image before touching the existing container..."
    echo "[COMPILE] Triggering pristine, zero-cache compilation block across ARM layers..."
    "${DOCKER}" build --no-cache -t "${DOCKER_IMAGE_TAG}" "${SCRIPT_DIR}"

    # Only tear down the existing container AFTER a successful build (the
    # build above already retags ${DOCKER_IMAGE_TAG} onto the new image,
    # leaving the previous image dangling rather than deleting it — set -eo
    # pipefail means a failed build exits before we ever reach this point,
    # so the previous working container is left untouched instead of
    # leaving nothing running at all).
    if [ -n "${CONTAINER_EXISTS}" ]; then
        "${DOCKER}" stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
        "${DOCKER}" rm "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    fi

elif [ "${POLICY}" = "FAST" ]; then
    if [ -n "${CONTAINER_EXISTS}" ]; then
        "${DOCKER}" rm "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    fi
    if [ -z "${IMAGE_EXISTS}" ]; then
        echo "[COMPILE] Target image layer missing. Launching standard dependency-cached ARM build..."
        "${DOCKER}" build -t "${DOCKER_IMAGE_TAG}" "${SCRIPT_DIR}"
    fi
else
    echo "[FATAL] Invalid framework compilation strategy policy parameter: '${POLICY}'"
    exit 1
fi

# --- ARCHETYPE RULE 1: PIPELINE TTY OVERRIDE ---
# Forcefully attach standard input streams directly back to the physical terminal socket.
# This prevents pipeline streams (like curl | bash) from crashing interactive dialog commands.
exec < /dev/tty

echo "[DEPLOY] Provisioning interactive foreground container environment..."

# Ensure the host pulse cookie directory and file exist prior to mounting
mkdir -p "$HOME/.config/pulse"
touch "$HOME/.config/pulse/cookie"

# Record that this environment has actually been launched (see DEPLOYED_MARKER above)
touch "${DEPLOYED_MARKER}"

# Record the config this container is about to be launched with (see CONFIG
# DRIFT DETECTION above) so a future FAST run can tell if run.sh's settings
# have changed since.
echo "${CONFIG_HASH}" > "${CONFIG_HASH_FILE}"

# Changed from '-d' to '-it' and removed background restart policies to allow true interaction
"${DOCKER}" run -it --rm \
  --privileged \
  -v "${HOST_USB_BUS_PATH}:/dev/bus/usb" \
  -e DISPLAY="${DISPLAY}" \
  -v "${HOST_X11_UNIX_PATH}:/tmp/.X11-unix" \
  --net=host \
  --device "${HOST_SOUND_DEVICE}" \
  -e PULSE_SERVER="unix:${HOST_PULSE_NATIVE_SOCKET}" \
  -v "${HOST_PULSE_NATIVE_SOCKET}:${HOST_PULSE_NATIVE_SOCKET}" \
  -v "$HOME/.config/pulse/cookie:/root/.config/pulse/cookie" \
  -v "${HOST_CAPTURES_PATH}:/workspace/captures" \
  -v "${HOST_MSF_DATA_PATH}:/workspace/msf_data" \
  --name "${CONTAINER_NAME}" \
  --entrypoint "${CONTAINER_ENTRYPOINT_COMMAND}" \
  "${DOCKER_IMAGE_TAG}"