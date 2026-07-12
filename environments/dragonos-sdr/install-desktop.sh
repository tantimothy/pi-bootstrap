#!/usr/bin/env bash
# DragonOS SDR desktop entries — data lives in desktop-entries.yaml, not here.
#   GQRX                — X11 window via socket passthrough
#   GNU Radio Companion — X11 window via socket passthrough
#   SDR Tools Menu      — TUI launcher in a terminal emulator
#   DragonOS SDR Info   — opens the generated post-deploy-info.html

set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="${APPS_DIR:-${HOME}/.local/share/applications}"
REPO_DIR="${REPO_DIR:-$(cd "$ENV_DIR/../.." && pwd)}"
source "$REPO_DIR/lib/desktop-lib.sh"

run_desktop_install_yaml "$ENV_DIR" "$@"
