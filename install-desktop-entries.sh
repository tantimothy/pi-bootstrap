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

source "$REPO_DIR/lib/desktop-lib.sh"
export DESKTOP_DIR

# Same reasoning as run_desktop_install()'s own guard in lib/desktop-lib.sh
# (each environment's install-desktop.sh would skip individually anyway) —
# checked here too so this prints one clear message instead of one per
# environment, and so the main dashboard launcher below is never written
# either.
if [[ "$(uname)" == "Darwin" ]]; then
    echo "Desktop entries are Linux-only (XDG .desktop files have no macOS equivalent) — nothing to do here."
    echo "On macOS, just run ./deploy.sh directly, or add it to your Dock/Login Items yourself."
    exit 0
fi

ACTION="${1:-install}"

if [ "$ACTION" = "--uninstall" ]; then
    echo "Removing pi-bootstrap desktop entries..."
    rm -f "$APPS_DIR/pi-bootstrap.desktop"
    remove_desktop_icon "pi-bootstrap"
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
install_desktop_icon "pi-bootstrap"
echo "  ✓  pi-bootstrap (main dashboard)"

# Delegate to each environment's own installer
for script in "$REPO_DIR"/environments/*/install-desktop.sh; do
    if [ -x "$script" ]; then
        "$script"
    fi
done

echo ""
echo "✅  Done. Entries installed to $APPS_DIR"
echo "   ...and mirrored as icons on the Desktop ($DESKTOP_DIR)"
echo ""
echo "Raspberry Pi OS picks up new entries automatically — no refresh needed."
echo "If you're on XFCE or GNOME and an entry doesn't show up right away:"
echo "  XFCE:   xfce4-panel --restart"
echo "  GNOME:  Alt+F2 → r  (or log out/in)"
echo ""
echo "To uninstall:  $0 --uninstall"
