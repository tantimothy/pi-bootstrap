#!/bin/bash
# Launch the containerized Armitage GUI (Metasploit front-end) on the host's
# X11/XWayland display. Armitage prompts to start/connect to Metasploit's RPC
# server itself on launch — run menu option 2 (Metasploit Framework) at least
# once first so the database is initialized.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gui-launch-lib.sh"
launch_gui_tool "Armitage" armitage
