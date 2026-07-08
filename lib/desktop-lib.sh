#!/usr/bin/env bash
# Shared helper for all environments' install-desktop.sh scripts (and the
# root install-desktop-entries.sh) — mirrors a just-written application-menu
# entry onto the user's Desktop too, so it shows as a clickable icon there
# and not just in the menu.
#
# The calling script must already have written "$APPS_DIR/<name>.desktop"
# before calling install_desktop_icon <name>.

APPS_DIR="${APPS_DIR:-${HOME}/.local/share/applications}"

DESKTOP_DIR="${DESKTOP_DIR:-}"
[ -z "$DESKTOP_DIR" ] && DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
[ -z "$DESKTOP_DIR" ] && DESKTOP_DIR="${HOME}/Desktop"

# Copies $APPS_DIR/<name>.desktop onto the Desktop, marked executable (and,
# where supported, "trusted" via gio) — most file managers refuse to launch
# a desktop file that isn't both, showing it as inert text or popping a
# "trust this launcher?" confirmation on every single click otherwise.
install_desktop_icon() {
    local name="$1"
    mkdir -p "$DESKTOP_DIR"
    cp -f "$APPS_DIR/${name}.desktop" "$DESKTOP_DIR/${name}.desktop"
    chmod +x "$DESKTOP_DIR/${name}.desktop"
    if command -v gio &>/dev/null; then
        gio set "$DESKTOP_DIR/${name}.desktop" metadata::trusted true 2>/dev/null || true
    fi
}

remove_desktop_icon() {
    local name="$1"
    rm -f "$DESKTOP_DIR/${name}.desktop"
}

# Builds a shell command that tries several launchers in turn for a given
# URL/file. A bare `xdg-open` silently does nothing on some Pi desktop
# images that lack a configured default browser handler, so fall back
# through common alternatives — including the current Raspberry Pi OS
# (Debian Bookworm+) package names, "chromium" and "firefox", not the older
# "chromium-browser" / "firefox-esr" wrapper names some other distros use.
BROWSER_FALLBACKS=(xdg-open x-www-browser sensible-browser chromium-browser chromium firefox-esr firefox)

open_cmd() {
    local url="$1" cmd="" b
    for b in "${BROWSER_FALLBACKS[@]}"; do
        [ -n "$cmd" ] && cmd+=" || "
        cmd+="$b $url 2>/dev/null"
    done
    printf '%s' "$cmd"
}

# Writes (menu + Desktop icon) a shortcut that opens an environment's
# generated post-deploy-info.html report in a browser — data directories,
# useful commands, and any web UI links, all in one place.
install_info_icon() {
    local name="$1" display_name="$2" html_file="$3"
    cat > "$APPS_DIR/${name}.desktop" << EOF
[Desktop Entry]
Name=${display_name}
Comment=Post-deploy info — data directories, useful commands, web UI links
Exec=bash -c "$(open_cmd "file://${html_file}")"
Icon=text-html
Type=Application
Categories=System;
Terminal=false
EOF
    install_desktop_icon "$name"
}
