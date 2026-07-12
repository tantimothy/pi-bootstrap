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
# host/systemd/launchd mode to detect here. Mirrors run.sh's own
# CONTAINER_NAME override (defaults to "nanoclaw-mnemon" if unset in .env)
# — hardcoding this independently would silently break the deployed-check
# for anyone who's actually customized it.
DEPLOYED_CHECK_KIND="container"
DEPLOYED_CHECK_VALUE="$(env_val "CONTAINER_NAME" "nanoclaw-mnemon")"

ENTRY_IDS=(pi-bootstrap-nanoclaw-mnemon)
ENTRY_NAMES=("NanoClaw + Mnemon AI")
ENTRY_COMMENTS=("NanoClaw with persistent memory (mnemon), optional Ollama embeddings, and Karpathy wiki scaffolding")
ENTRY_ICONS=(utilities-terminal)
ENTRY_KINDS=(exec)
ENTRY_TARGETS=("bash -c \"cd '$ENV_DIR' && REBUILD_POLICY=FAST ./run.sh\"")
ENTRY_TERMINAL=(true)

INFO_ID="pi-bootstrap-nanoclaw-mnemon-info"
INFO_NAME="NanoClaw + Mnemon Info"

run_desktop_install "$@"
