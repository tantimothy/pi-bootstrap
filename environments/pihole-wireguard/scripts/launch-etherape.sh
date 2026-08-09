#!/bin/bash
# Launch the containerized EtherApe GUI (live, color-coded traffic map) on
# the host's X11/XWayland display.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gui-launch-lib.sh"
launch_gui_tool "EtherApe" etherape
