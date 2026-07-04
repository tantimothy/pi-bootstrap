#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${1:-list}"
export SCRIPT_DIR

# pi-barebones installs system packages and configures .bashrc.
# It has no Docker containers and no persistent data directories to delete.

if [ "$ACTION" = "list" ]; then
    echo ""
    echo "📁 Persistent Data Directories:"
    echo "   (none — pi-barebones only installs packages and configures .bashrc)"
    echo ""
    echo "💡 Useful Commands:"
    envsubst '${SCRIPT_DIR}' < "$SCRIPT_DIR/useful-commands.txt"
    echo ""

elif [ "$ACTION" = "delete" ]; then
    echo ""
    echo "ℹ️  pi-barebones has no persistent data directories to delete."
    echo "   To undo package installations, remove them manually with:"
    echo "   sudo apt-get remove <package>"
    echo ""
fi
