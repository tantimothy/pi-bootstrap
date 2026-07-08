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

# Writes (menu + Desktop icon) a Type=Link desktop entry — opens a URL
# directly via the desktop environment's own default handler. No Exec=, no
# shell command, and (unlike Type=Application) most file managers don't
# apply an "untrusted launcher" prompt to these since nothing is executed.
install_link_icon() {
    local name="$1" display_name="$2" comment="$3" url="$4" icon="$5" categories="$6"
    cat > "$APPS_DIR/${name}.desktop" << EOF
[Desktop Entry]
Type=Link
Name=${display_name}
Comment=${comment}
URL=${url}
Icon=${icon}
Categories=${categories}
EOF
    install_desktop_icon "$name"
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
