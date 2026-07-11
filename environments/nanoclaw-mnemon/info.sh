#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ACTION="${1:-list}"

[ -f "$SCRIPT_DIR/.env" ] && { set -a; source "$SCRIPT_DIR/.env"; set +a; }

INSTALL_PATH="${NANOCLAW_INSTALL_PATH:-/home/pi/nanoclaw-mnemon}"
NANOCLAW_PORT="${NANOCLAW_PORT:-3081}"

# Resolve the host's LAN IP so this URL is actually usable from another
# device — "localhost" only means something on the Pi/Mac's own terminal.
HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
[ -z "$HOST_IP" ] && HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$HOST_IP" ] && HOST_IP="localhost"

DATA_DIRS=("$INSTALL_PATH/groups" "$INSTALL_PATH/data")
DATA_DESCRIPTIONS=(
    "Per-group files: conversation history, mnemon's persistent memory graph (nested under each group's .claude/mnemon/), transcripts, CLAUDE.md"
    "Sessions, message DB, task scheduler DB, IPC streams"
)
INSTALL_DIRS=("$INSTALL_PATH")
INSTALL_DESCRIPTIONS=("NanoClaw + mnemon repo/binaries (groups/ and data/ live inside here)")
NAMED_VOLUMES=(); NAMED_VOLUME_DESCRIPTIONS=()
DATA_DIRS_LABEL="📁 Persistent Data Directories (back these up):"
INSTALL_DIRS_LABEL="📂 Install Directories (can be re-cloned by CLEAN):"
DELETE_INSTALL_DIRS=false
DELETE_CONFIRM_MSG="All conversation history and mnemon's persistent memory graph will be lost."
WEB_UI_NAMES=("NanoClaw Web Interface")
WEB_UI_URLS=("http://${HOST_IP}:${NANOCLAW_PORT}")
USEFUL_COMMANDS="   docker ps --filter name=nanoclaw-mnemon                         # Orchestrator status
   docker logs -f nanoclaw-mnemon                                  # Orchestrator live logs
   docker restart nanoclaw-mnemon                                  # Restart after a config change
   docker ps --filter name=nanoclaw-agent                          # List agent containers (both nanoclaw environments, if both deployed)
   docker exec -it nanoclaw-mnemon bash -lc \"cd \$NANOCLAW_INSTALL_PATH && bash setup/add-whatsapp.sh\"   # Add WhatsApp channel
   docker exec -it nanoclaw-mnemon bash -lc \"cd \$NANOCLAW_INSTALL_PATH && bash setup/add-telegram.sh\"   # Add Telegram channel
   docker exec -it nanoclaw-mnemon bash -lc \"cd \$NANOCLAW_INSTALL_PATH && bash setup/add-discord.sh\"    # Add Discord channel
   docker exec -it nanoclaw-mnemon bash -lc \"cd \$NANOCLAW_INSTALL_PATH && bash setup/register-claude-token.sh\"   # Update Anthropic API key

📌 Notes:
   🧠 mnemon (github.com/mnemon-dev/mnemon) is patched into NanoClaw's own agent
      sandbox image — persistent, cross-session graph memory per conversation
      group. Patched idempotently on every deploy; see run.sh's apply_mnemon_patch.
   🐳 NanoClaw manages its own Docker containers per conversation group.
      Use the Docker Manager in the deploy menu to view or delete them.
   ❌ iMessage isn't offered — this environment is container-mode only (see
      the README's \"Deployment Modes\" section for why)."

source "$REPO_DIR/lib/info-lib.sh"
run_info
