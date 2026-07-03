#!/usr/bin/env bash
# DragonOS SDR desktop entries:
#   GQRX                — X11 window via socket passthrough
#   GNU Radio Companion — X11 window via socket passthrough
#   SDR Tools Menu      — TUI launcher in a terminal emulator

set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="${APPS_DIR:-${HOME}/.local/share/applications}"
REPO_DIR="${REPO_DIR:-$(cd "$ENV_DIR/../.." && pwd)}"

ENTRIES=(
    pi-bootstrap-gqrx
    pi-bootstrap-gnuradio
    pi-bootstrap-sdr-menu
)

if [ "${1:-}" = "--uninstall" ]; then
    for e in "${ENTRIES[@]}"; do rm -f "$APPS_DIR/${e}.desktop"; done
    exit 0
fi

mkdir -p "$APPS_DIR"

ENV_FILE="$ENV_DIR/.env"

# Resolve image name before deployment check
SDR_IMAGE="dragonos-pi"
if [ -f "$ENV_FILE" ]; then
    _i=$(grep '^DOCKER_IMAGE_TAG=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 | tr -d "\"'"); [ -n "$_i" ] && SDR_IMAGE=$_i
fi

# Only install entries if the environment has been built
if ! docker images -q "$SDR_IMAGE" 2>/dev/null | grep -q .; then
    echo "  ⚠  dragonos-sdr: image '$SDR_IMAGE' not found — skipping (deploy the environment first)"
    exit 0
fi

echo "  dragonos-sdr: deployed ✓"
SDR_CONTAINER="sdr-dragonos-core"
if [ -f "$ENV_FILE" ]; then
    _c=$(grep '^CONTAINER_NAME=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 | tr -d "\"'"); [ -n "$_c" ] && SDR_CONTAINER=$_c
fi

# X11 flags: mount the host X socket and pass DISPLAY=:0 (standard for Pi desktop).
# If running over SSH with X forwarding, edit these entries and replace :0 with $DISPLAY.
X11="--rm -e DISPLAY=:0 -v /tmp/.X11-unix:/tmp/.X11-unix --device /dev/bus/usb"

cat > "$APPS_DIR/pi-bootstrap-gqrx.desktop" << EOF
[Desktop Entry]
Name=GQRX
Comment=Software Defined Radio receiver — spectrum waterfall, FM/AM/SSB/CW demodulation
Exec=bash -c "xhost +local: >/dev/null 2>&1; docker run $X11 $SDR_IMAGE gqrx"
Icon=gqrx
Type=Application
Categories=HamRadio;Science;
Terminal=false
EOF
echo "  ✓  GQRX (DragonOS)"

cat > "$APPS_DIR/pi-bootstrap-gnuradio.desktop" << EOF
[Desktop Entry]
Name=GNU Radio Companion
Comment=Visual signal processing flowgraph editor
Exec=bash -c "xhost +local: >/dev/null 2>&1; docker run $X11 $SDR_IMAGE gnuradio-companion"
Icon=gnuradio-grc
Type=Application
Categories=HamRadio;Science;
Terminal=false
EOF
echo "  ✓  GNU Radio Companion (DragonOS)"

# Attach to a running container if available; otherwise launch fresh
cat > "$APPS_DIR/pi-bootstrap-sdr-menu.desktop" << EOF
[Desktop Entry]
Name=SDR Tools Menu
Comment=Interactive SDR launcher — rtl_fm, dump1090, hackrf, APRS, ACARS and more
Exec=bash -c "docker exec -it $SDR_CONTAINER /usr/local/bin/sdr-menu.sh 2>/dev/null || docker run -it --rm --device /dev/bus/usb $SDR_IMAGE"
Icon=utilities-terminal
Type=Application
Categories=HamRadio;Science;
Terminal=true
EOF
echo "  ✓  SDR Tools Menu (DragonOS)"
