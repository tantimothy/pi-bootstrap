#!/bin/bash
set -eo pipefail

# --- ARCHETYPE RULE 1: INHERITED WRAPPERS ---
DOCKER="${DOCKER_CMD:-docker}"

# --- ARCHETYPE RULE 3: SECRET ACQUISITION ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
if [ -f "${SCRIPT_DIR}/.env" ]; then
    set -a
    source "${SCRIPT_DIR}/.env"
    set +a
fi

# This needs its own run.sh rather than a plain docker-compose.yml because
# it hands off to a fully interactive, X11-forwarded, privileged-mode
# `docker run -it --rm` session (GUI window, host audio, host network
# device) — the same shape as dragonos-sdr/kali-pentest, not a background
# service stack.
CONTAINER_NAME="${CONTAINER_NAME:-sheepshaver}"
DOCKER_IMAGE_TAG="${DOCKER_IMAGE_TAG:-pi-bootstrap-sheepshaver}"
DISPLAY="${DISPLAY:-:0}"
HOST_X11_UNIX_PATH="${HOST_X11_UNIX_PATH:-/tmp/.X11-unix}"
HOST_SOUND_DEVICE="${HOST_SOUND_DEVICE:-/dev/snd}"
HOST_PULSE_NATIVE_SOCKET="${HOST_PULSE_NATIVE_SOCKET:-/run/user/$(id -u)/pulse/native}"

SS_DATA_PATH="${SS_DATA_PATH:-${SCRIPT_DIR}/data}"
SS_EXTFS="${SS_EXTFS:-${SCRIPT_DIR}/shared}"
SS_ROM="${SS_ROM:-/data/sheepshaver.rom}"
SS_DISK="${SS_DISK:-/data/disk}"
SS_RAM="${SS_RAM:-268435456}"
SS_WIDTH="${SS_WIDTH:-1024}"
SS_HEIGHT="${SS_HEIGHT:-768}"
SS_NET="${SS_NET:-slirp}"
SS_NO_GUI="${SS_NO_GUI:-false}"
SS_JIT="${SS_JIT:-true}"
# The container runs with --rm, so a lingering image alone doesn't prove
# it was ever launched — touched right before the docker run below, same
# convention as dragonos-sdr/kali-pentest.
DEPLOYED_MARKER="${SCRIPT_DIR}/.deployed"

POLICY="${REBUILD_POLICY:-FAST}"
echo "[POLICY] ${POLICY}"

mkdir -p "${SS_DATA_PATH}" "${SS_EXTFS}"

if [ "${POLICY}" = "STOP" ]; then
    echo "🛑 [STOP] SheepShaver runs as a foreground --rm session (quitting the emulator already removes the container) — stopping it if still up..."
    "${DOCKER}" stop "${CONTAINER_NAME}" 2>/dev/null || true
    exit 0
fi

if [ "${POLICY}" = "TEARDOWN" ]; then
    echo "🗑️  [TEARDOWN] Stopping and removing container: ${CONTAINER_NAME}"
    "${DOCKER}" stop "${CONTAINER_NAME}" 2>/dev/null || true
    "${DOCKER}" rm   "${CONTAINER_NAME}" 2>/dev/null || true
    rm -f "${DEPLOYED_MARKER}"
    bash "$REPO_DIR/lib/run-install-desktop.sh" "$SCRIPT_DIR" >/dev/null 2>&1 || true
    echo "✅ Removed. Your ROM/disk under ${SS_DATA_PATH} are untouched — use WIPE to delete them."
    exit 0
fi

CONTAINER_RUNNING=$("${DOCKER}" ps --filter "name=^/${CONTAINER_NAME}$" --format "{{.Names}}")
if [ -n "${CONTAINER_RUNNING}" ]; then
    echo "✅ '${CONTAINER_NAME}' is already running — SheepShaver is a single interactive session, so there's nothing to reattach to."
    exit 0
fi

IMAGE_EXISTS=$("${DOCKER}" images -q "${DOCKER_IMAGE_TAG}" 2>/dev/null || true)

if [ "${POLICY}" = "CLEAN" ]; then
    echo "🐳 [CLEAN] Building a fresh image before touching anything running..."
    "${DOCKER}" build --no-cache -t "${DOCKER_IMAGE_TAG}" "${SCRIPT_DIR}"
    "${DOCKER}" image prune -f >/dev/null 2>&1 || true
elif [ "${POLICY}" = "FAST" ]; then
    if [ -z "${IMAGE_EXISTS}" ]; then
        echo "🐳 [FAST] No image yet — building ${DOCKER_IMAGE_TAG} (compiles SheepShaver from source under Debian Wheezy + GCC 4.6, this takes a while)..."
        "${DOCKER}" build -t "${DOCKER_IMAGE_TAG}" "${SCRIPT_DIR}"
    fi
else
    echo "❌ [FATAL] Unknown policy: ${POLICY}" >&2
    exit 1
fi

# SS_ROM/SS_DISK are container-side paths under /data (bind-mounted from
# SS_DATA_PATH) — strip that prefix to find the matching host-side file.
SS_ROM_HOST="${SS_DATA_PATH}${SS_ROM#/data}"
if [ ! -f "${SS_ROM_HOST}" ]; then
    echo "⚠️  No ROM found at ${SS_ROM_HOST} — SheepShaver needs a pre-2000 Macintosh ROM file there before it will boot."
    echo "   See README.md for where to find one and how to create a hard disk image."
fi

DEVICE_FLAGS=()
if [ -e "${HOST_SOUND_DEVICE}" ]; then
    DEVICE_FLAGS+=(--device "${HOST_SOUND_DEVICE}")
else
    echo "⚠️  ${HOST_SOUND_DEVICE} not found — running without audio passthrough."
fi

# /dev/sheep_net only exists once the NetDriver kernel module (built from
# https://github.com/cebix/macemu/tree/master/BasiliskII/src/Unix/Linux/NetDriver
# — the same module the macintoshpi environment builds for its own emulators)
# has been loaded on the host. It's only required for --ether (bridged)
# networking; the default here is "slirp", which needs no host device at
# all, so this stays optional rather than a hard requirement.
if [ "${SS_NET}" = "ether" ]; then
    if [ -e /dev/sheep_net ]; then
        DEVICE_FLAGS+=(--device /dev/sheep_net)
    else
        echo "❌ SS_NET=ether requires /dev/sheep_net on the host (build the NetDriver kernel module first) — falling back to SS_NET=slirp for this run."
        SS_NET="slirp"
    fi
fi

PULSE_FLAGS=()
if [ -S "${HOST_PULSE_NATIVE_SOCKET}" ]; then
    PULSE_FLAGS+=(-e "PULSE_SERVER=unix:${HOST_PULSE_NATIVE_SOCKET}" -v "${HOST_PULSE_NATIVE_SOCKET}:${HOST_PULSE_NATIVE_SOCKET}:ro")
else
    echo "⚠️  No PulseAudio socket found at ${HOST_PULSE_NATIVE_SOCKET} — running without host audio."
fi

xhost +local: >/dev/null 2>&1 || echo "⚠️  'xhost' not available/failed — X11 access may not work unless already permitted."

touch "${DEPLOYED_MARKER}"
bash "$REPO_DIR/lib/run-install-desktop.sh" "$SCRIPT_DIR" >/dev/null 2>&1 || true

echo "🚀 Launching SheepShaver (CONTAINER_NAME=${CONTAINER_NAME}, SS_NET=${SS_NET})..."
"${DOCKER}" run -it --rm \
    --privileged \
    --name "${CONTAINER_NAME}" \
    -e "DISPLAY=unix${DISPLAY}" \
    -e "SS_ROM=${SS_ROM}" \
    -e "SS_DISK=${SS_DISK}" \
    -e "SS_RAM=${SS_RAM}" \
    -e "SS_WIDTH=${SS_WIDTH}" \
    -e "SS_HEIGHT=${SS_HEIGHT}" \
    -e "SS_NET=${SS_NET}" \
    -e "SS_NO_GUI=${SS_NO_GUI}" \
    -e "SS_JIT=${SS_JIT}" \
    -v "${HOST_X11_UNIX_PATH}:/tmp/.X11-unix:rw" \
    -v "${SS_DATA_PATH}:/data" \
    -v "${SS_EXTFS}:/shared" \
    "${DEVICE_FLAGS[@]}" \
    "${PULSE_FLAGS[@]}" \
    "${DOCKER_IMAGE_TAG}"

bash "$REPO_DIR/lib/run-info.sh" "$SCRIPT_DIR" list
