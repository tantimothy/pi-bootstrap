#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${1:-list}"

if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a; source "$SCRIPT_DIR/.env"; set +a
fi

INSTALL_PATH="${NANOCLAW_INSTALL_PATH:-/home/pi/nanoclaw}"

DATA_DIRS=(
    "$INSTALL_PATH/groups"
    "$INSTALL_PATH/data"
)
DATA_DESCRIPTIONS=(
    "Per-group files: conversation history, memory wiki, transcripts, CLAUDE.md"
    "Sessions, message DB, task scheduler DB, IPC streams"
)
INSTALL_DIRS=(
    "$INSTALL_PATH"
)
INSTALL_DESCRIPTIONS=(
    "NanoClaw repo + built binaries (groups/ and data/ live inside here)"
)
USEFUL_COMMANDS=(
    "systemctl status nanoclaw                             # Service status"
    "journalctl -u nanoclaw -f                            # Live logs"
    "sudo systemctl restart nanoclaw                      # Restart service"
    "docker ps --filter name=nanoclaw                     # List agent containers"
    "cd $INSTALL_PATH && bash setup/add-whatsapp.sh       # Add WhatsApp channel"
    "cd $INSTALL_PATH && bash setup/add-telegram.sh       # Add Telegram channel"
    "cd $INSTALL_PATH && bash setup/register-claude-token.sh  # Update Anthropic API key"
)

# -----------------------------------------------------------------------
if [ "$ACTION" = "list" ]; then
    echo ""
    echo "📁 Persistent Data Directories (back these up):"
    for i in "${!DATA_DIRS[@]}"; do
        dir="${DATA_DIRS[$i]}"
        if [ -d "$dir" ]; then
            size=$(du -sh "$dir" 2>/dev/null | cut -f1)
            echo "   $dir  ($size)"
        else
            echo "   $dir  (not yet created)"
        fi
        echo "     → ${DATA_DESCRIPTIONS[$i]}"
    done
    echo ""
    echo "📂 Install Directories (can be re-cloned by CLEAN):"
    for i in "${!INSTALL_DIRS[@]}"; do
        dir="${INSTALL_DIRS[$i]}"
        if [ -d "$dir" ]; then
            size=$(du -sh "$dir" 2>/dev/null | cut -f1)
            echo "   $dir  ($size)"
        else
            echo "   $dir  (not yet created)"
        fi
        echo "     → ${INSTALL_DESCRIPTIONS[$i]}"
    done
    echo ""
    echo "💡 Useful Commands:"
    for cmd in "${USEFUL_COMMANDS[@]}"; do
        echo "   $cmd"
    done
    echo ""

elif [ "$ACTION" = "delete" ]; then
    echo ""
    echo "⚠️  The following directories will be PERMANENTLY DELETED:"
    echo ""
    DIRS_EXIST=false
    for i in "${!DATA_DIRS[@]}"; do
        dir="${DATA_DIRS[$i]}"
        if [ -d "$dir" ]; then
            size=$(du -sh "$dir" 2>/dev/null | cut -f1)
            echo "   🗑️  $dir  ($size)"
            echo "       → ${DATA_DESCRIPTIONS[$i]}"
            DIRS_EXIST=true
        else
            echo "   ⬜  $dir  (does not exist)"
        fi
    done
    echo ""
    if [ "$DIRS_EXIST" = "false" ]; then
        echo "ℹ️  No data directories exist. Nothing to delete."
        exit 0
    fi
    if command -v dialog &>/dev/null; then
        dialog --clear --title " ⚠️  Delete Persistent Data " \
            --yesno "\nThis permanently deletes all listed directories.\nAll conversation history and memory will be lost.\n\nAre you absolutely sure?" \
            10 62
        CONFIRM=$?; clear
    else
        read -rp "Type 'yes' to confirm permanent deletion: " CONFIRM_TEXT
        [ "$CONFIRM_TEXT" = "yes" ] && CONFIRM=0 || CONFIRM=1
    fi
    if [ "$CONFIRM" -eq 0 ]; then
        for dir in "${DATA_DIRS[@]}"; do
            [ -d "$dir" ] && rm -rf "$dir" && echo "🗑️  Deleted: $dir"
        done
        echo "✅ Done."
    else
        echo "❌ Deletion cancelled."
    fi
fi
