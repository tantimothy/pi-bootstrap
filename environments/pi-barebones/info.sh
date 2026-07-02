#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${1:-list}"

# pi-barebones installs system packages and configures .bashrc.
# It has no Docker containers and no persistent data directories to delete.
USEFUL_COMMANDS=(
    "cat $SCRIPT_DIR/packages.txt                         # View managed package list"
    "sudo apt list --installed 2>/dev/null | grep -v '^Listing'  # All installed packages"
    "sudo apt-get upgrade -y                              # Upgrade all packages"
    "cat ~/.bashrc                                        # View current .bashrc"
    "source ~/.bashrc                                     # Reload bash config"
    "tmux ls                                              # List active tmux sessions"
    "tmux attach                                          # Attach to most recent tmux session"
)

if [ "$ACTION" = "list" ]; then
    echo ""
    echo "📁 Persistent Data Directories:"
    echo "   (none — pi-barebones only installs packages and configures .bashrc)"
    echo ""
    echo "💡 Useful Commands:"
    for cmd in "${USEFUL_COMMANDS[@]}"; do
        echo "   $cmd"
    done
    echo ""

elif [ "$ACTION" = "delete" ]; then
    echo ""
    echo "ℹ️  pi-barebones has no persistent data directories to delete."
    echo "   To undo package installations, remove them manually with:"
    echo "   sudo apt-get remove <package>"
    echo ""
fi
