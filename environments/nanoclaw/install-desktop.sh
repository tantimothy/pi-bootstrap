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

# Deployed-check depends on which deploy mode is actually configured —
# mirrors run.sh's own OS-based default + .env override, since there's no
# systemd unit at all in container mode (and no "nanoclaw" container in
# host mode either).
NANOCLAW_DEPLOY_MODE=$(env_val "NANOCLAW_DEPLOY_MODE" "")
if [ -z "$NANOCLAW_DEPLOY_MODE" ]; then
    if [[ "$(uname)" == "Darwin" ]]; then NANOCLAW_DEPLOY_MODE="container"; else NANOCLAW_DEPLOY_MODE="host"; fi
fi

if [ "$NANOCLAW_DEPLOY_MODE" = "container" ]; then
    DEPLOYED_CHECK_KIND="container"
    DEPLOYED_CHECK_VALUE="nanoclaw"
else
    DEPLOYED_CHECK_KIND="systemd"
    DEPLOYED_CHECK_VALUE="nanoclaw.service"
fi

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
