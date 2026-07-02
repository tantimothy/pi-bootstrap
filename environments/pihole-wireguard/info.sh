#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${1:-list}"

if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a; source "$SCRIPT_DIR/.env"; set +a
fi

DATA_DIRS=(
    "$SCRIPT_DIR/etc-pihole"
    "$SCRIPT_DIR/etc-wireguard"
)
DATA_DESCRIPTIONS=(
    "Pi-hole config, gravity database, custom blocklists, local DNS records"
    "WireGuard server keys + all peer configs — losing this invalidates every client VPN"
)
USEFUL_COMMANDS=(
    "docker exec -it pihole pihole setpassword                   # Change Pi-hole admin password"
    "docker exec -it wg-easy wg show                             # Show connected WireGuard peers"
    "docker run --rm -it ghcr.io/wg-easy/wg-easy wgpw 'pass'   # Generate new bcrypt hash for PASSWORD_HASH"
    "docker logs -f pihole                                        # Pi-hole live logs"
    "docker logs -f wg-easy                                       # WireGuard live logs"
    "docker compose -f $SCRIPT_DIR/docker-compose.yml ps         # Stack status"
)

# -----------------------------------------------------------------------
if [ "$ACTION" = "list" ]; then
    echo ""
    echo "📁 Persistent Data Directories:"
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
            --yesno "\nThis permanently deletes all listed directories.\nWireGuard peer configs will be unrecoverable.\n\nAre you absolutely sure?" \
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
