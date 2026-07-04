#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ACTION="${1:-list}"

DATA_DIRS=(); DATA_DESCRIPTIONS=()
INSTALL_DIRS=(); INSTALL_DESCRIPTIONS=()
NAMED_VOLUMES=(); NAMED_VOLUME_DESCRIPTIONS=()
NO_DATA_MSG="(none — pi-barebones only installs packages and configures .bashrc)"
NO_DELETE_MSG=$'pi-barebones has no persistent data directories to delete.\n   To undo package installations, remove them manually with:\n   sudo apt-get remove <package>'
USEFUL_COMMANDS="   cat ${SCRIPT_DIR}/packages.txt                                   # View managed package list
   sudo apt list --installed 2>/dev/null | grep -v '^Listing'      # All installed packages
   sudo apt-get upgrade -y                                         # Upgrade all packages
   cat ~/.bashrc                                                   # View current .bashrc
   source ~/.bashrc                                                # Reload bash config
   tmux ls                                                         # List active tmux sessions
   tmux attach                                                     # Attach to most recent tmux session"

source "$REPO_DIR/lib/info-lib.sh"
run_info
