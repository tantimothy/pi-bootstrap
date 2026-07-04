#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ACTION="${1:-list}"

[ -f "$SCRIPT_DIR/.env" ] && { set -a; source "$SCRIPT_DIR/.env"; set +a; }

INSTALL_PATH="${NANOCLAW_INSTALL_PATH:-/home/pi/nanoclaw}"

DATA_DIRS=("$INSTALL_PATH/groups" "$INSTALL_PATH/data")
DATA_DESCRIPTIONS=(
    "Per-group files: conversation history, memory wiki, transcripts, CLAUDE.md"
    "Sessions, message DB, task scheduler DB, IPC streams"
)
INSTALL_DIRS=("$INSTALL_PATH")
INSTALL_DESCRIPTIONS=("NanoClaw repo + built binaries (groups/ and data/ live inside here)")
NAMED_VOLUMES=(); NAMED_VOLUME_DESCRIPTIONS=()
DATA_DIRS_LABEL="📁 Persistent Data Directories (back these up):"
INSTALL_DIRS_LABEL="📂 Install Directories (can be re-cloned by CLEAN):"
DELETE_INSTALL_DIRS=false
DELETE_CONFIRM_MSG="All conversation history and memory will be lost."
USEFUL_COMMANDS="   systemctl status nanoclaw                                        # Service status
   journalctl -u nanoclaw -f                                       # Live logs
   sudo systemctl restart nanoclaw                                 # Restart service
   docker ps --filter name=nanoclaw                                # List agent containers
   cd ${INSTALL_PATH} && bash setup/add-whatsapp.sh                # Add WhatsApp channel
   cd ${INSTALL_PATH} && bash setup/add-telegram.sh                # Add Telegram channel
   cd ${INSTALL_PATH} && bash setup/register-claude-token.sh       # Update Anthropic API key"

source "$REPO_DIR/lib/info-lib.sh"
run_info
