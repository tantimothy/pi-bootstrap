#!/usr/bin/env bash
# NanoClaw desktop entries:
#   NanoClaw AI   — launches the environment in a terminal emulator
#   NanoClaw Info — opens the generated post-deploy-info.html

set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="${APPS_DIR:-${HOME}/.local/share/applications}"
REPO_DIR="${REPO_DIR:-$(cd "$ENV_DIR/../.." && pwd)}"
source "$REPO_DIR/lib/desktop-lib.sh"

MENU_ID="nanoclaw"
MENU_NAME="NanoClaw"
MENU_ICON="utilities-terminal"
DEPLOYED_CHECK_KIND="systemd"
DEPLOYED_CHECK_VALUE="nanoclaw.service"

ENTRY_IDS=(pi-bootstrap-nanoclaw)
ENTRY_NAMES=("NanoClaw AI")
ENTRY_COMMENTS=("Local AI tools — Ollama model inference, Whisper speech-to-text, Claude")
ENTRY_ICONS=(utilities-terminal)
ENTRY_KINDS=(exec)
ENTRY_TARGETS=("bash -c \"cd '$ENV_DIR' && REBUILD_POLICY=FAST ./run.sh\"")
ENTRY_TERMINAL=(true)

INFO_ID="pi-bootstrap-nanoclaw-info"
INFO_NAME="NanoClaw Info"

run_desktop_install "$@"
