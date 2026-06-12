#!/bin/bash
# ==============================================================================
# SUBFOLDER EXECUTION BLUEPRINT: DRAGONOS SDR CORE WORKSPACE LAYER
# ==============================================================================
# System Architecture Archetype: 1 (Custom Orchestration Shell)
# Mode: Strict Non-Interactive Pipeline Compatible (Daemonized Processing Block)
# Compatibility Layer: Dynamic Rebuild Strategy / TUI Secret Forms Integration
# ==============================================================================

set -eo pipefail

# --- ARCHETYPE RULE 1: INHERITED WRAPPERS ---
# Use dashboard-provided socket/permission definitions; do not call raw docker executable.
DOCKER="\${DOCKER_CMD:-docker}"

# --- ARCHETYPE RULE 3: SECRET ACQUISITION ---
# Search for compiled secrets written by the parent form pre-processor.
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
if [ -f "\${SCRIPT_DIR}/.env" ]; then
    echo "[INFO] Ingesting dynamic environment configurations from local .env context..."
    export \$(grep -v '^#' "\${SCRIPT_DIR}/.env" | xargs)
else
    echo "[WARN] Stale environment reference. Local .env not detected at \${SCRIPT_DIR}/.env"
fi

# Fallback Environment Configurations (Safeguards against uninitialized parameters)
CONTAINER_NAME="\${CONTAINER_NAME:-sdr-dragonos-core}"
DOCKER_IMAGE_TAG="\${DOCKER_IMAGE_TAG:-dragonos-pi}"
DISPLAY="\${DISPLAY:-:0}"
HOST_USB_BUS_PATH="\${HOST_USB_BUS_PATH:-/dev/bus/usb}"
HOST_X11_UNIX_PATH="\${HOST_X11_UNIX_PATH:-/tmp/.X11-unix}"
HOST_SOUND_DEVICE="\${HOST_SOUND_DEVICE:-/dev/snd}"
HOST_PULSE_NATIVE_SOCKET="\${HOST_PULSE_NATIVE_SOCKET:-/run/user/1000/pulse/native}"
HOST_PULSE_COOKIE_PATH="\${HOST_PULSE_COOKIE_PATH:-~/.config/pulse/cookie}"
CONTAINER_ENTRYPOINT_COMMAND="\${CONTAINER_ENTRYPOINT_COMMAND:-/usr/local/bin/sdr-menu.sh}"

# Persistent volume application configurations
HOST_CAPTURES_PATH="\${HOST_CAPTURES_PATH:-./workspace/captures}"
HOST_MSF_DATA_PATH="\${HOST_MSF_DATA_PATH:-./workspace/msf_data}"

# --- ARCHITECTURAL SAFEGUARD: PRE-EMPTIVE VOLUME GENERATION ---
# Explicitly initialize host directory markers using the active executing user context.
# Prevents Docker daemon from implicitly generating paths bound to root ownership levels.
echo "[PRE-FLIGHT] Applying Pre-emptive Directory Creation Constraints on volume paths..."
mkdir -p "\${HOST_CAPTURES_PATH}"
mkdir -p "\${HOST_MSF_DATA_PATH}"

# --- ENGINE DESIGN MATRIX: POLICY AUTOMATION ROUTING ---
POLICY="\${REBUILD_POLICY:-FAST}"
echo "[POLICY] Ingesting central orchestration lifecycle strategy: [\${POLICY}]"

# Retrieve physical container state tracking profiles
CONTAINER_RUNNING=\$("\${DOCKER}" ps --filter "name=^\/\${CONTAINER_NAME}\$" --format "{{.Names}}")
CONTAINER_EXISTS=\$("\${DOCKER}" ps -a --filter "name=^\/\${CONTAINER_NAME}\$" --format "{{.Names}}")
IMAGE_EXISTS=\$("\${DOCKER}" images -q "\${DOCKER_IMAGE_TAG}" 2>/dev/null || true)

if [ "\${POLICY}" = "FAST" ]; then
    # State Pathway A: The Container-Running Shortcut
    if [ -n "\${CONTAINER_RUNNING}" ]; then
        echo "[BYPASS] FAST Policy Engaged: Container '\${CONTAINER_NAME}' is currently active."
        echo "[BYPASS] Terminating initialization workflow immediately to optimize framework uptime."
        exit 0
    fi

    # State Pathway B: The Container-Stopped Shortcut
    if [ -z "\${CONTAINER_RUNNING}" ] && [ -n "\${CONTAINER_EXISTS}" ] && [ -n "\${IMAGE_EXISTS}" ]; then
        echo "[SHORTCUT] FAST Policy Engaged: Dormant container detected with complete cache layers."
        echo "[LIFECYCLE] Executing non-destructive restoration shortcut sequence..."
        "\${DOCKER}" start "\${CONTAINER_NAME}" >/dev/null
        echo "[SUCCESS] SDR Engine container '\${CONTAINER_NAME}' recovered cleanly without rebuild latency."
        exit 0
    fi
fi

# --- STATE TEARDOWN AND IMAGE COMPILE ROUTING ---
if [ "\${POLICY}" = "CLEAN" ]; then
    # State Pathway C: Pristine Rebuild Compilation
    echo "[PURGE] CLEAN Policy Engaged: Deconstructing infrastructure containers and image layers..."
    if [ -n "\${CONTAINER_EXISTS}" ]; then
        "\${DOCKER}" stop "\${CONTAINER_NAME}" >/dev/null 2>&1 || true
        "\${DOCKER}" rm "\${CONTAINER_NAME}" >/dev/null 2>&1 || true
    fi
    if [ -n "\${IMAGE_EXISTS}" ]; then
        echo "[LIFECYCLE] Evicting local image registry cache: \${DOCKER_IMAGE_TAG}"
        "\${DOCKER}" rmi "\${DOCKER_IMAGE_TAG}" >/dev/null 2>&1 || true
    fi
    
    echo "[COMPILE] Triggering pristine, zero-cache compilation block across ARM layers..."
    "\${DOCKER}" build --no-cache -t "\${DOCKER_IMAGE_TAG}" "\${SCRIPT_DIR}"

elif [ "\${POLICY}" = "FAST" ]; then
    # State Pathway D: Standard Cached Compilation (Cache-Miss Recovery)
    if [ -n "\${CONTAINER_EXISTS}" ]; then
        # Flush the lingering dead container node to free up the unique name registry string
        "\${DOCKER}" rm "\${CONTAINER_NAME}" >/dev/null 2>&1 || true
    fi
    
    if [ -z "\${IMAGE_EXISTS}" ]; then
        echo "[COMPILE] Target image layer missing. Launching standard dependency-cached ARM build..."
        "\${DOCKER}" build -t "\${DOCKER_IMAGE_TAG}" "\${SCRIPT_DIR}"
    else
        echo "[INFO] Confirmed presence of functional image layout. Bypassing compilation."
    fi
else
    echo "[FATAL] Invalid framework compilation strategy policy parameter: '\${POLICY}'"
    exit 1
fi

# --- ARCHETYPE RULE 2: STRICT NON-INTERACTIVE BACKGROUND EXECUTION ---
# No TTY initialization (-it, -t, < /dev/tty) allowed. Completely decoupled for pipeline tasks.
# Features automated system daemon recovery hooks via the restart parameter instruction.
echo "[DEPLOY] Provisioning detached background daemon processing layers..."

"\${DOCKER}" run -d \
  --privileged \
  --restart=unless-stopped \
  -v "\${HOST_USB_BUS_PATH}:/dev/bus/usb" \
  -e DISPLAY="\${DISPLAY}" \
  -v "\${HOST_X11_UNIX_PATH}:/tmp/.X11-unix" \
  --net=host \
  --device "\${HOST_SOUND_DEVICE}" \
  -e PULSE_SERVER="unix:\${HOST_PULSE_NATIVE_SOCKET}" \
  -v "\${HOST_PULSE_NATIVE_SOCKET}:\${HOST_PULSE_NATIVE_SOCKET}" \
  -v "\${HOST_PULSE_COOKIE_PATH}:/root/.config/pulse/cookie" \
  -v "\${HOST_CAPTURES_PATH}:/workspace/captures" \
  -v "\${HOST_MSF_DATA_PATH}:/workspace/msf_data" \
  --name "\${CONTAINER_NAME}" \
  --entrypoint "\${CONTAINER_ENTRYPOINT_COMMAND}" \
  "\${DOCKER_IMAGE_TAG}"

echo "[SUCCESS] SDR Automation Layer successfully initialized under background daemon tag: \${CONTAINER_NAME}"
"\${DOCKER}" ps --filter "name=^\/\${CONTAINER_NAME}\$"