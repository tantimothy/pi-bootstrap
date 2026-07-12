#!/usr/bin/env bash
# NanoClaw + Mnemon desktop entries — data lives in desktop-entries.yaml, not here.
#   NanoClaw+Mnemon AI   — launches the environment in a terminal emulator
#   NanoClaw+Mnemon Info — opens the generated post-deploy-info.html

set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="${APPS_DIR:-${HOME}/.local/share/applications}"
REPO_DIR="${REPO_DIR:-$(cd "$ENV_DIR/../.." && pwd)}"
source "$REPO_DIR/lib/desktop-lib.sh"

run_desktop_install_yaml "$ENV_DIR" "$@"
