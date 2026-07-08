#!/usr/bin/env bash
# Shared helpers for all environments' install-desktop.sh scripts (and the
# root install-desktop-entries.sh): registering entries in the application
# menu ($APPS_DIR), mirroring them onto the Desktop ($DESKTOP_DIR) as
# clickable icons, and grouping each environment's entries into their own
# application-menu submenu.
#
# For command-launcher entries (Exec=..., e.g. GQRX, a terminal session),
# write "$APPS_DIR/<name>.desktop" yourself, then call
# install_desktop_icon <name> to mirror it onto the Desktop as-is.
#
# For URL-opening entries (web UIs, the generated info page), call
# install_link_icon/install_info_icon instead — see their comments for why
# they write two different desktop-entry flavors rather than one shared file.

APPS_DIR="${APPS_DIR:-${HOME}/.local/share/applications}"

DESKTOP_DIR="${DESKTOP_DIR:-}"
[ -z "$DESKTOP_DIR" ] && DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
[ -z "$DESKTOP_DIR" ] && DESKTOP_DIR="${HOME}/Desktop"

# Makes a .desktop file launchable from a file manager's Desktop view —
# executable, and where supported, "trusted" via gio. Most file managers
# refuse to launch one that isn't both, showing it as inert text or
# popping a "trust this launcher?" confirmation on every single click
# otherwise. Not needed for the $APPS_DIR copy — application MENUS parse
# .desktop files directly regardless of the executable bit; this only
# matters for the Desktop-icon copy, which a file manager treats as a
# double-clickable file like any other.
_mark_desktop_file_launchable() {
    local file="$1"
    chmod +x "$file"
    if command -v gio &>/dev/null; then
        gio set "$file" metadata::trusted true 2>/dev/null || true
    fi
}

# Copies $APPS_DIR/<name>.desktop onto the Desktop as-is. Used for entries
# where the menu and Desktop-icon versions should be identical (anything
# that runs a command rather than opens a URL — see install_link_icon for
# the URL case, which needs two different flavors instead of a copy).
install_desktop_icon() {
    local name="$1"
    mkdir -p "$DESKTOP_DIR"
    cp -f "$APPS_DIR/${name}.desktop" "$DESKTOP_DIR/${name}.desktop"
    _mark_desktop_file_launchable "$DESKTOP_DIR/${name}.desktop"
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

# Writes a URL-opening shortcut as two different desktop-entry flavors,
# since the two contexts behave differently on this desktop environment:
#   - $APPS_DIR/<name>.desktop: Type=Application + Exec= browser-fallback
#     chain. The application MENU only lists Type=Application entries —
#     Type=Link is valid per spec but gets silently filtered out of the
#     menu here, even though it's the better fit semantically.
#   - $DESKTOP_DIR/<name>.desktop: Type=Link. Opens directly via the
#     desktop's default URL handler with no wrapper script, and (unlike
#     Type=Application) doesn't trigger an "untrusted launcher" prompt on
#     the Desktop icon.
install_link_icon() {
    local name="$1" display_name="$2" comment="$3" url="$4" icon="$5" categories="$6"

    cat > "$APPS_DIR/${name}.desktop" << EOF
[Desktop Entry]
Type=Application
Name=${display_name}
Comment=${comment}
Exec=bash -c "$(open_cmd "$url")"
Icon=${icon}
Categories=${categories}
Terminal=false
EOF

    mkdir -p "$DESKTOP_DIR"
    cat > "$DESKTOP_DIR/${name}.desktop" << EOF
[Desktop Entry]
Type=Link
Name=${display_name}
Comment=${comment}
URL=${url}
Icon=${icon}
Categories=${categories}
EOF
    _mark_desktop_file_launchable "$DESKTOP_DIR/${name}.desktop"
}

# Writes (menu + Desktop icon) a shortcut that opens an environment's
# generated post-deploy-info.html report in a browser — data directories,
# useful commands, and any web UI links, all in one place.
install_info_icon() {
    local name="$1" display_name="$2" html_file="$3" categories="$4"
    install_link_icon "$name" "$display_name" \
        "Post-deploy info — data directories, useful commands, web UI links" \
        "file://${html_file}" "text-html" "$categories"
}

# Registers a custom application-menu submenu for an environment (instead
# of its entries falling into an existing category folder like Internet or
# System Tools), using the standard freedesktop Desktop Menu Specification
# merge mechanism: a .directory file (submenu name/icon) plus a .menu
# fragment that routes any entry tagged with the matching category into it.
# Call once per environment; idempotent (just overwrites both files).
#
# Every .desktop entry for this environment must then use ONLY
# "X-PiBootstrap-<menu_id>;" as its Categories= — mixing in a standard
# category (Network;, System;, ...) would make the entry ALSO show up in
# that standard submenu, not just this one.
register_submenu() {
    local menu_id="$1" display_name="$2" icon="${3:-utilities-terminal}"
    local dir_dirs="${HOME}/.local/share/desktop-directories"
    local menu_dir="${HOME}/.config/menus/applications-merged"
    mkdir -p "$dir_dirs" "$menu_dir"

    cat > "${dir_dirs}/pi-bootstrap-${menu_id}.directory" << EOF
[Desktop Entry]
Type=Directory
Name=${display_name}
Icon=${icon}
EOF

    cat > "${menu_dir}/pi-bootstrap-${menu_id}.menu" << EOF
<!DOCTYPE Menu PUBLIC "-//freedesktop//DTD Menu 1.0//EN"
 "http://www.freedesktop.org/standards/menu-spec/1.0/menu.dtd">
<Menu>
  <Name>Applications</Name>
  <Menu>
    <Name>pi-bootstrap-${menu_id}</Name>
    <Directory>pi-bootstrap-${menu_id}.directory</Directory>
    <Include>
      <Category>X-PiBootstrap-${menu_id}</Category>
    </Include>
  </Menu>
</Menu>
EOF
    _refresh_menu_cache
}

remove_submenu() {
    local menu_id="$1"
    rm -f "${HOME}/.local/share/desktop-directories/pi-bootstrap-${menu_id}.directory"
    rm -f "${HOME}/.config/menus/applications-merged/pi-bootstrap-${menu_id}.menu"
    _refresh_menu_cache
}

# Unlike individual .desktop file changes (which most menu implementations
# pick up via inotify automatically), a new/removed submenu .menu fragment
# often needs an explicit cache rebuild to actually show up. No-op if the
# tool isn't installed or the menu isn't registered yet — non-fatal either way.
_refresh_menu_cache() {
    command -v xdg-desktop-menu &>/dev/null && xdg-desktop-menu forceupdate --mode user 2>/dev/null
    return 0
}
