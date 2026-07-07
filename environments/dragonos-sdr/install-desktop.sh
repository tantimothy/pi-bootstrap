#!/usr/bin/env bash
# DragonOS SDR desktop entries:
#   GQRX                — X11 window via socket passthrough
#   GNU Radio Companion — X11 window via socket passthrough
#   SDR Tools Menu      — TUI launcher in a terminal emulator
#   DragonOS SDR Info   — opens the generated post-deploy-info.html

set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="${APPS_DIR:-${HOME}/.local/share/applications}"
REPO_DIR="${REPO_DIR:-$(cd "$ENV_DIR/../.." && pwd)}"
source "$REPO_DIR/lib/desktop-lib.sh"

ENTRIES=(
    pi-bootstrap-gqrx
    pi-bootstrap-gnuradio
    pi-bootstrap-sdr-menu
    pi-bootstrap-dragonos-sdr-info
)

if [ "${1:-}" = "--uninstall" ]; then
    for e in "${ENTRIES[@]}"; do rm -f "$APPS_DIR/${e}.desktop"; remove_desktop_icon "$e"; done
    exit 0
fi

mkdir -p "$APPS_DIR"

ENV_FILE="$ENV_DIR/.env"

# Resolve image name before deployment check
SDR_IMAGE="dragonos-pi"
if [ -f "$ENV_FILE" ]; then
    _i=$(grep '^DOCKER_IMAGE_TAG=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 | tr -d "\"'"); [ -n "$_i" ] && SDR_IMAGE=$_i
fi

# Only install entries if the environment has actually been launched at least
# once (run.sh touches .deployed right before it runs the container). A
# lingering docker image alone isn't enough — the image can survive a one-off
# build/test long after the user stops using the environment, since it's not
# removed by anything short of a manual `docker rmi` or CLEAN policy.
# If it hasn't been launched (or the marker was cleared by TEARDOWN since),
# clean up any stale entries too.
if [ ! -f "$ENV_DIR/.deployed" ]; then
    for e in "${ENTRIES[@]}"; do rm -f "$APPS_DIR/${e}.desktop"; remove_desktop_icon "$e"; done
    echo "  ⚠  dragonos-sdr: not deployed — skipping (deploy the environment first)"
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
install_desktop_icon "pi-bootstrap-gqrx"
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
install_desktop_icon "pi-bootstrap-gnuradio"
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
install_desktop_icon "pi-bootstrap-sdr-menu"
echo "  ✓  SDR Tools Menu (DragonOS)"

# Ensure post-deploy-info.html exists even if INFO has never been opened
# from the menu yet (this is a cheap, idempotent safety net).
bash "$ENV_DIR/info.sh" list >/dev/null 2>&1 || true
install_info_icon "pi-bootstrap-dragonos-sdr-info" "DragonOS SDR Info" "$ENV_DIR/post-deploy-info.html"
echo "  ✓  Info page (DragonOS SDR)"
