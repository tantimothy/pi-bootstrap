#!/usr/bin/env bash
# install-desktop-entries.sh
# Thin orchestrator — discovers and calls each environment's own install-desktop.sh.
#
# Usage:
#   ./install-desktop-entries.sh            # install all
#   ./install-desktop-entries.sh --uninstall # remove all

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export APPS_DIR="${HOME}/.local/share/applications"
export REPO_DIR

ACTION="${1:-install}"

if [ "$ACTION" = "--uninstall" ]; then
    echo "Removing pi-bootstrap desktop entries..."
    rm -f "$APPS_DIR/pi-bootstrap.desktop"
    for script in "$REPO_DIR"/environments/*/install-desktop.sh; do
        [ -x "$script" ] && "$script" --uninstall
    done
    echo "Done."
    exit 0
fi

mkdir -p "$APPS_DIR"
echo "Installing pi-bootstrap desktop entries..."
echo ""

# Main dashboard launcher
cat > "$APPS_DIR/pi-bootstrap.desktop" << EOF
[Desktop Entry]
Name=Pi Bootstrap
Comment=Raspberry Pi Docker environment launcher
Exec=bash -c "cd '$REPO_DIR' && ./deploy.sh"
Icon=utilities-terminal
Type=Application
Categories=System;
Terminal=true
EOF
echo "  ✓  pi-bootstrap (main dashboard)"

# Delegate to each environment's own installer
for script in "$REPO_DIR"/environments/*/install-desktop.sh; do
    if [ -x "$script" ]; then
        "$script"
    fi
done

echo ""
echo "✅  Done. Entries installed to $APPS_DIR"
echo ""
echo "Raspberry Pi OS picks up new entries automatically — no refresh needed."
echo "If you're on XFCE or GNOME and an entry doesn't show up right away:"
echo "  XFCE:   xfce4-panel --restart"
echo "  GNOME:  Alt+F2 → r  (or log out/in)"
echo ""
echo "To uninstall:  $0 --uninstall"
