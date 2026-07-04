#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ACTION="${1:-list}"
export SCRIPT_DIR

DATA_DIRS=(); DATA_DESCRIPTIONS=()
INSTALL_DIRS=(); INSTALL_DESCRIPTIONS=()
NAMED_VOLUMES=(); NAMED_VOLUME_DESCRIPTIONS=()
NO_DATA_MSG="(none — pi-barebones only installs packages and configures .bashrc)"
NO_DELETE_MSG=$'pi-barebones has no persistent data directories to delete.\n   To undo package installations, remove them manually with:\n   sudo apt-get remove <package>'
ENVSUBST_VARS='${SCRIPT_DIR}'

source "$REPO_DIR/lib/info-lib.sh"
run_info
