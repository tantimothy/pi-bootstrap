#!/usr/bin/env bash
# NanoClaw + Mnemon desktop entries:
#   NanoClaw+Mnemon AI   — launches the environment in a terminal emulator
#   NanoClaw+Mnemon Info — opens the generated post-deploy-info.html

set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="${APPS_DIR:-${HOME}/.local/share/applications}"
REPO_DIR="${REPO_DIR:-$(cd "$ENV_DIR/../.." && pwd)}"
source "$REPO_DIR/lib/desktop-lib.sh"

MENU_ID="nanoclaw-mnemon"
MENU_NAME="NanoClaw + Mnemon"
MENU_ICON="utilities-terminal"

# Container-mode only — unlike the plain nanoclaw environment, there's no
# host/systemd/launchd mode to detect here.
DEPLOYED_CHECK_KIND="container"
DEPLOYED_CHECK_VALUE="nanoclaw-mnemon"

ENTRY_IDS=(pi-bootstrap-nanoclaw-mnemon)
ENTRY_NAMES=("NanoClaw + Mnemon AI")
ENTRY_COMMENTS=("NanoClaw with persistent cross-session memory via mnemon (github.com/mnemon-dev/mnemon)")
ENTRY_ICONS=(utilities-terminal)
ENTRY_KINDS=(exec)
ENTRY_TARGETS=("bash -c \"cd '$ENV_DIR' && REBUILD_POLICY=FAST ./run.sh\"")
ENTRY_TERMINAL=(true)

INFO_ID="pi-bootstrap-nanoclaw-mnemon-info"
INFO_NAME="NanoClaw + Mnemon Info"

run_desktop_install "$@"
