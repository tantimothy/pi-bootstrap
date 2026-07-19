#!/usr/bin/env bash
# install-desktop-entries.sh
# Thin orchestrator — discovers each environment directory and dispatches
# to lib/run-install-desktop.sh for each (which calls that environment's
# own install-desktop.sh override if it has one, else the generic
# YAML-driven driver directly — see that file's own comment).
#
# Usage:
#   ./install-desktop-entries.sh            # install all
#   ./install-desktop-entries.sh --uninstall # remove all

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Force a UTF-8 locale before any emoji-laden output below prints — see
# lib/locale-lib.sh's own comment for why. `|| true` because a failed/
# missing-locale outcome there returns non-zero, which `set -e` above
# would otherwise treat as this whole script failing.
source "$REPO_DIR/lib/locale-lib.sh" || true

export APPS_DIR="${HOME}/.local/share/applications"
export REPO_DIR

source "$REPO_DIR/lib/desktop-lib.sh"
export DESKTOP_DIR

# The main dashboard launcher below (an XDG .desktop app-menu entry) has
# no macOS equivalent, so it's skipped there — but per-environment web UI
# shortcuts and info pages still get delegated to run-install-desktop.sh
# below, which on macOS writes those as .webloc files via
# run_desktop_install() in lib/desktop-lib.sh. An earlier version of this
# script exited entirely on Darwin before ever reaching that loop, which
# meant .webloc files were never actually produced through this entry
# point despite lib/desktop-lib.sh supporting them.
IS_DARWIN=false
[[ "$(uname)" == "Darwin" ]] && IS_DARWIN=true

ACTION="${1:-install}"

if [ "$ACTION" = "--uninstall" ]; then
    echo "Removing pi-bootstrap desktop entries..."
    if ! $IS_DARWIN; then
        rm -f "$APPS_DIR/pi-bootstrap.desktop"
        remove_desktop_icon "pi-bootstrap"
    fi
    for env_dir in "$REPO_DIR"/environments/*/; do
        bash "$REPO_DIR/lib/run-install-desktop.sh" "${env_dir%/}" --uninstall
    done
    echo "Done."
    exit 0
fi

echo "Installing pi-bootstrap desktop entries..."
echo ""

if $IS_DARWIN; then
    echo "  ⏭  pi-bootstrap (main dashboard): skipped (macOS — no app-menu equivalent; run ./deploy.sh directly, or add it to your Dock/Login Items)"
else
    mkdir -p "$APPS_DIR"
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
fi

# Delegate to each environment via the dispatcher
for env_dir in "$REPO_DIR"/environments/*/; do
    bash "$REPO_DIR/lib/run-install-desktop.sh" "${env_dir%/}"
done

echo ""
if $IS_DARWIN; then
    echo "✅  Done. Web UI shortcuts and info pages written as .webloc files to $DESKTOP_DIR"
else
    echo "✅  Done. Entries installed to $APPS_DIR"
    echo "   ...and mirrored as icons on the Desktop ($DESKTOP_DIR)"
    echo ""
    echo "Raspberry Pi OS picks up new entries automatically — no refresh needed."
    echo "If you're on XFCE or GNOME and an entry doesn't show up right away:"
    echo "  XFCE:   xfce4-panel --restart"
    echo "  GNOME:  Alt+F2 → r  (or log out/in)"
fi
echo ""
echo "To uninstall:  $0 --uninstall"
