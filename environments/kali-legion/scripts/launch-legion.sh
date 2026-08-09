#!/bin/bash
# Launch the containerized Legion GUI (automated recon/scanning) on the
# host's X11/XWayland display.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gui-launch-lib.sh"
launch_gui_tool "Legion" legion
