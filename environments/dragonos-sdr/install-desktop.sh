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

MENU_ID="dragonos-sdr"
MENU_NAME="DragonOS SDR"
MENU_ICON="gqrx"
# .env.example ships no persistent container_name — the environment runs
# with --rm, so a lingering image alone doesn't prove it was ever launched.
# run.sh touches .deployed right before it runs the container instead.
DEPLOYED_CHECK_KIND="marker"
DEPLOYED_CHECK_VALUE="$ENV_DIR/.deployed"

SDR_IMAGE=$(env_val "DOCKER_IMAGE_TAG" "dragonos-pi")
SDR_CONTAINER=$(env_val "CONTAINER_NAME" "sdr-dragonos-core")

# X11 flags: mount the host X socket and pass DISPLAY=:0 (standard for Pi desktop).
# If running over SSH with X forwarding, edit these entries and replace :0 with $DISPLAY.
X11="--rm -e DISPLAY=:0 -v /tmp/.X11-unix:/tmp/.X11-unix --device /dev/bus/usb"

ENTRY_IDS=(pi-bootstrap-gqrx pi-bootstrap-gnuradio pi-bootstrap-sdr-menu)
ENTRY_NAMES=("GQRX" "GNU Radio Companion" "SDR Tools Menu")
ENTRY_COMMENTS=(
    "Software Defined Radio receiver — spectrum waterfall, FM/AM/SSB/CW demodulation"
    "Visual signal processing flowgraph editor"
    "Interactive SDR launcher — rtl_fm, dump1090, hackrf, APRS, ACARS and more"
)
ENTRY_ICONS=(gqrx gnuradio-grc utilities-terminal)
ENTRY_KINDS=(exec exec exec)
ENTRY_TARGETS=(
    "bash -c \"xhost +local: >/dev/null 2>&1; docker run $X11 $SDR_IMAGE gqrx\""
    "bash -c \"xhost +local: >/dev/null 2>&1; docker run $X11 $SDR_IMAGE gnuradio-companion\""
    # Attach to a running container if available; otherwise launch fresh.
    "bash -c \"docker exec -it $SDR_CONTAINER /usr/local/bin/sdr-menu.sh 2>/dev/null || docker run -it --rm --device /dev/bus/usb $SDR_IMAGE\""
)
ENTRY_TERMINAL=(false false true)

INFO_ID="pi-bootstrap-dragonos-sdr-info"
INFO_NAME="DragonOS SDR Info"

run_desktop_install "$@"
