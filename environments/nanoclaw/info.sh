#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ACTION="${1:-list}"

[ -f "$SCRIPT_DIR/.env" ] && { set -a; source "$SCRIPT_DIR/.env"; set +a; }

INSTALL_PATH="${NANOCLAW_INSTALL_PATH:-/home/pi/nanoclaw}"
NANOCLAW_PORT="${NANOCLAW_PORT:-3080}"

OS_TYPE="linux"
if [[ "$(uname)" == "Darwin" ]]; then OS_TYPE="macos"; fi

# Resolve the host's LAN IP so this URL is actually usable from another
# device — "localhost" only means something on the Pi's own terminal.
HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
[ -z "$HOST_IP" ] && HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$HOST_IP" ] && HOST_IP="localhost"

if [ "$OS_TYPE" = "macos" ]; then
    SERVICE_COMMANDS="   tail -f ${INSTALL_PATH}/logs/nanoclaw.log                        # Live logs"
else
    SERVICE_COMMANDS="   systemctl status nanoclaw                                        # Service status
   journalctl -u nanoclaw -f                                       # Live logs
   sudo systemctl restart nanoclaw                                 # Restart service"
fi

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
USEFUL_COMMANDS="🌐 Web interface: http://${HOST_IP}:${NANOCLAW_PORT}

${SERVICE_COMMANDS}
   docker ps --filter name=nanoclaw                                # List agent containers
   cd ${INSTALL_PATH} && bash setup/add-whatsapp.sh                # Add WhatsApp channel
   cd ${INSTALL_PATH} && bash setup/add-telegram.sh                # Add Telegram channel
   cd ${INSTALL_PATH} && bash setup/add-discord.sh                 # Add Discord channel
   cd ${INSTALL_PATH} && bash setup/add-imessage.sh                # Add iMessage channel
   cd ${INSTALL_PATH} && bash setup/register-claude-token.sh       # Update Anthropic API key

📌 Notes:
   🐳 NanoClaw manages its own Docker containers per conversation group.
      Use the Docker Manager in the deploy menu to view or delete them."

source "$REPO_DIR/lib/info-lib.sh"
run_info
