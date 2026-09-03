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
# below, which on macOS writes those as .webloc/.fileloc shortcuts via
# run_desktop_install() in lib/desktop-lib.sh. An earlier version of this
# script exited entirely on Darwin before ever reaching that loop, which
# meant those shortcuts were never actually produced through this entry
# point despite lib/desktop-lib.sh supporting them.
IS_DARWIN=false
[[ "$(uname)" == "Darwin" ]] && IS_DARWIN=true

# Collects environments whose dispatch failed, so one bad environment neither
# aborts the run nor passes unnoticed. Also gates the orphan sweep below.
FAILED_ENVS=""

ACTION="${1:-install}"

if [ "$ACTION" = "--uninstall" ]; then
    echo "Removing pi-bootstrap desktop entries..."
    if ! $IS_DARWIN; then
        rm -f "$APPS_DIR/pi-bootstrap.desktop"
        remove_desktop_icon "pi-bootstrap"
    fi
    # `if !` rather than a bare call: under `set -e` a single environment
    # exiting non-zero (a malformed desktop-entries.yaml, the wrong yq on
    # $PATH) would abort this loop, silently skipping every environment
    # alphabetically after it — so "uninstall" would remove some environments'
    # entries and leave others behind with no indication which or why. Failures
    # are collected and reported at the end instead.
    for env_dir in "$REPO_DIR"/environments/*/; do
        if ! bash "$REPO_DIR/lib/run-install-desktop.sh" "${env_dir%/}" --uninstall; then
            FAILED_ENVS="${FAILED_ENVS} $(basename "${env_dir%/}")"
        fi
    done
    # The loop above can only reach environments that still exist. Anything
    # left carrying this repo's own markers belongs to one that was deleted
    # since it was installed, and --uninstall means all of it — so sweep by
    # what is actually on disk rather than by what the repo still declares.
    while IFS= read -r menu_id; do
        [ -n "$menu_id" ] || continue
        purge_menu_id "$menu_id"
        echo "  🧹  ${menu_id}: removed leftover entries (not claimed by any current environment)"
    done < <(installed_menu_ids)
    if [ -n "$FAILED_ENVS" ]; then
        echo ""
        echo "⚠️  Could not read these environments:${FAILED_ENVS}"
        echo "   The sweep above removed their entries anyway (it works from what is"
        echo "   installed on disk, not from what those environments declare)."
    fi
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

# Delegate to each environment via the dispatcher. See the uninstall loop's
# comment for why a failure is collected rather than allowed to abort the run.
for env_dir in "$REPO_DIR"/environments/*/; do
    if ! bash "$REPO_DIR/lib/run-install-desktop.sh" "${env_dir%/}"; then
        FAILED_ENVS="${FAILED_ENVS} $(basename "${env_dir%/}")"
        echo "  ❌  $(basename "${env_dir%/}"): could not be read — its entries were left untouched"
    fi
done

# An environment that is merely undeployed has already had its entries swept
# by the loop above (run_desktop_install's not-deployed branch does that). An
# environment whose FOLDER was deleted never enters that loop at all, so its
# entries would otherwise sit there forever, launching containers that no
# longer exist. Compare what is installed against what the repo declares and
# clean up the difference. Both lists are sorted, as comm requires.
#
# Skipped outright if ANY environment above failed to load. This sweep deletes
# whatever the declared set does not account for, so it is only ever as safe as
# that set is complete: one unreadable environment (or a broken yq, which makes
# every one of them unreadable) would otherwise turn a janitor into a shredder
# and delete every entry on the machine. Refusing to guess is the only correct
# behaviour when the comparison's other half is untrustworthy.
if [ -n "$FAILED_ENVS" ]; then
    echo ""
    echo "⚠️  Could not read these environments:${FAILED_ENVS}"
    echo "   Skipping the leftover-entry sweep — with an incomplete picture of what"
    echo "   this repo declares, it could delete entries that are perfectly valid."
else
    while IFS= read -r menu_id; do
        [ -n "$menu_id" ] || continue
        purge_menu_id "$menu_id"
        echo "  🧹  ${menu_id}: environment no longer in this repo — removed its leftover entries"
    done < <(comm -23 <(installed_menu_ids) <(declared_menu_ids))
fi

echo ""
if $IS_DARWIN; then
    echo "✅  Done. Web UI shortcuts (.webloc) and info pages (.fileloc) written to $DESKTOP_DIR"
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

# Non-zero when anything was skipped, so a caller (or a human scrolling past
# the tail of the output) can tell a partial run from a clean one. Every
# in-repo caller invokes this best-effort with `|| true`, so this reports
# rather than breaks anything.
[ -z "$FAILED_ENVS" ]
