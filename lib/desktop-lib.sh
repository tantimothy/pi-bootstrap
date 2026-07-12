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

# REPO_DIR is already set by every caller (install-desktop-entries.sh, each
# environment's install-desktop.sh) before it sources this file.
source "$REPO_DIR/lib/yaml-lib.sh"

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

# Removes every .desktop file (in both $APPS_DIR and $DESKTOP_DIR) tagged
# with a given environment's Categories=, regardless of what that
# environment's install-desktop.sh *currently* declares as its entries.
#
# Deliberately not driven by an ENTRY_IDS list: if an entry was renamed or
# removed since the last successful install (e.g. a service split out into
# its own environment), a list-driven cleanup would never even know that ID
# existed, leaving its .desktop file orphaned forever. The Categories= tag
# already written into every file this environment ever created is a
# reliable, self-healing marker of ownership that doesn't drift.
_desktop_remove_all_for_menu() {
    local menu_id="$1"
    local tag="Categories=X-PiBootstrap-${menu_id};"
    local f
    for f in "$APPS_DIR"/*.desktop "$DESKTOP_DIR"/*.desktop; do
        [ -f "$f" ] || continue
        grep -qF "$tag" "$f" 2>/dev/null && rm -f "$f"
    done
    # Without this, the function's own exit status is whatever the last
    # grep happened to return — 1 ("no match") whenever the very last file
    # in the glob isn't tagged for this environment. Called as a bare
    # statement under set -e, that silently aborts the entire calling
    # script (install-desktop.sh) the moment ANY other environment's
    # desktop entries happen to exist in the same shared $APPS_DIR/
    # $DESKTOP_DIR — which is the normal case with more than one
    # environment installed.
    return 0
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

# macOS's native double-clickable internet-shortcut format — the closest
# equivalent to a Linux Desktop Type=Link .desktop entry. A plain plist
# with one meaningful key (URL); Finder shows it as a bookmark icon and
# opens the URL in the default browser on double-click. No app-menu
# equivalent exists on macOS (Launchpad/Spotlight only index real .app
# bundles, not arbitrary shortcut files), so — unlike install_link_icon,
# which writes both a menu entry and a Desktop icon — this only ever
# writes to $DESKTOP_DIR.
#
# The ownership marker is an XML comment (X-PiBootstrap-MenuID), not an
# extra plist dict key, specifically so it's guaranteed inert to any
# .webloc reader (a stray dict key MacOS's own parser doesn't expect
# might not be — an XML comment definitely is, by spec, for any parser).
# Not verified against a real macOS Finder in this environment — built by
# reading the plist/webloc format spec, not observed firsthand.
install_webloc() {
    local name="$1" url="$2" menu_id="$3"
    mkdir -p "$DESKTOP_DIR"
    cat > "$DESKTOP_DIR/${name}.webloc" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- X-PiBootstrap-MenuID: ${menu_id} -->
<plist version="1.0">
<dict>
	<key>URL</key>
	<string>${url}</string>
</dict>
</plist>
EOF
}

remove_webloc() {
    local name="$1"
    rm -f "$DESKTOP_DIR/${name}.webloc"
}

# .webloc equivalent of _desktop_remove_all_for_menu — same self-healing
# rationale (an entry ID renamed/removed since the last install shouldn't
# leave an orphaned file forever), same content-based ownership check
# rather than a filename or ENTRY_IDS-list match.
_webloc_remove_all_for_menu() {
    local menu_id="$1"
    local f
    for f in "$DESKTOP_DIR"/*.webloc; do
        [ -f "$f" ] || continue
        grep -qF "X-PiBootstrap-MenuID: ${menu_id} -->" "$f" 2>/dev/null && rm -f "$f"
    done
    return 0
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

# Reads a value from $ENV_DIR/.env with a fallback default — used to build
# port-based Exec=/URL= entries that reflect the user's actual configuration
# rather than a hardcoded default. $ENV_DIR must already be set by the
# calling install-desktop.sh (same convention run_desktop_install below
# uses for its other inputs).
env_val() {
    local key="$1" default="$2"
    local val
    val=$(grep "^${key}=" "$ENV_DIR/.env" 2>/dev/null | cut -d= -f2 | tr -d "\"'" | head -1)
    echo "${val:-$default}"
}

# Populates MENU_*/ENTRY_*/INFO_* (everything run_desktop_install needs
# EXCEPT DEPLOYED_CHECK_KIND/VALUE) from $env_dir/desktop-entries.yaml.
# Split out from run_desktop_install_yaml (below) so an environment whose
# deployed-check needs real branching (nanoclaw's host-vs-container
# deploy-mode detection) can call this for the data, set
# DEPLOYED_CHECK_KIND/VALUE itself, and call run_desktop_install directly —
# see nanoclaw/install-desktop.sh.
#
# $env_dir/desktop-entries.yaml schema:
#   menu: {id, name, icon}
#   deployed_check: {kind, value}      # kind: container | marker | systemd
#                                       # — omit if the caller sets these itself
#   entries:                            # list, one per desktop entry
#     - {id, name, comment, icon, kind, target, terminal}
#       # kind: link | exec. terminal is exec-only, optional (default false).
#   info: {id, name}
#
# Any string value may contain ${VAR} / ${VAR:-default} markers, resolved
# by _yaml_expand (lib/yaml-lib.sh) against real bash variables in scope at
# call time: .env is sourced first, and ENV_DIR is set before any
# substitution runs (so "${ENV_DIR}/.deployed" — the marker-file pattern —
# resolves correctly).
_load_desktop_entries_yaml() {
    local env_dir="$1"
    ENV_DIR="$env_dir"
    local yaml="$env_dir/desktop-entries.yaml"

    _require_yq || return 1

    [ -f "$env_dir/.env" ] && { set -a; source "$env_dir/.env"; set +a; }

    MENU_ID=$(_yq '.menu.id' "$yaml")
    MENU_NAME=$(_yq '.menu.name' "$yaml")
    MENU_ICON=$(_yq '.menu.icon // "utilities-terminal"' "$yaml")

    mapfile -t ENTRY_IDS      < <(_yq '.entries[].id' "$yaml")
    mapfile -t ENTRY_NAMES    < <(_yq '.entries[].name' "$yaml")
    mapfile -t ENTRY_COMMENTS < <(_yq '.entries[].comment' "$yaml")
    mapfile -t ENTRY_ICONS    < <(_yq '.entries[].icon' "$yaml")
    mapfile -t ENTRY_KINDS    < <(_yq '.entries[].kind' "$yaml")
    mapfile -t ENTRY_TERMINAL < <(_yq '.entries[].terminal // "false"' "$yaml")

    local _raw_targets i
    mapfile -t _raw_targets < <(_yq '.entries[].target' "$yaml")
    ENTRY_TARGETS=()
    for i in "${!_raw_targets[@]}"; do
        ENTRY_TARGETS[i]="$(_yaml_expand "${_raw_targets[$i]}")"
    done

    INFO_ID=$(_yq '.info.id' "$yaml")
    INFO_NAME=$(_yq '.info.name' "$yaml")
}

# Generic driver for environments with no install-desktop.sh logic beyond
# declaring data: loads desktop-entries.yaml via _load_desktop_entries_yaml
# above, ALSO reads deployed_check from the same file (the common case —
# see _load_desktop_entries_yaml's own comment for the exception), then
# calls run_desktop_install.
run_desktop_install_yaml() {
    local env_dir="$1"; shift
    _load_desktop_entries_yaml "$env_dir" || return 1
    local yaml="$env_dir/desktop-entries.yaml"

    DEPLOYED_CHECK_KIND=$(_yq '.deployed_check.kind' "$yaml")
    DEPLOYED_CHECK_VALUE="$(_yaml_expand "$(_yq '.deployed_check.value' "$yaml")")"

    run_desktop_install "$@"
}

# Generic driver for a per-environment install-desktop.sh — handles
# --uninstall, the "is this actually deployed" check, submenu registration,
# looping over entries, and the info-page hookup, so each environment's own
# install-desktop.sh only needs to declare data and call this once as its
# last line: `run_desktop_install "$@"` (forwarding its own $1 so
# --uninstall keeps working).
#
# The caller sets these before calling:
#
#   MENU_ID, MENU_NAME, MENU_ICON     — passed to register_submenu.
#                                       Categories= is derived from MENU_ID
#                                       automatically — never set it yourself.
#   DEPLOYED_CHECK_KIND               — "container" | "marker" | "systemd"
#   DEPLOYED_CHECK_VALUE              — container name / marker file path /
#                                        systemd unit name, matching the kind
#   NOT_DEPLOYED_MSG                  — optional override for the "skipping"
#                                        message; sensible defaults exist per kind
#
#   Parallel arrays, one row per entry (declare ENTRY_IDS=() if there are
#   none besides the info entry below):
#     ENTRY_IDS, ENTRY_NAMES, ENTRY_COMMENTS, ENTRY_ICONS, ENTRY_KINDS
#     ENTRY_TARGETS   — a URL for "link" entries (→ install_link_icon), or a
#                       full Exec= command string for "exec" entries (→ a
#                       raw Type=Application .desktop file, for anything
#                       that isn't a plain URL open — X11 passthrough,
#                       docker exec, a terminal launcher, etc.)
#     ENTRY_TERMINAL  — exec entries only; "true"/"false", defaults to "false"
#
#   INFO_ID, INFO_NAME                 — this environment's own "<Name> Info" entry
_desktop_is_deployed() {
    case "$DEPLOYED_CHECK_KIND" in
        container) docker ps -a --filter "name=^/${DEPLOYED_CHECK_VALUE}$" -q 2>/dev/null | grep -q . ;;
        marker)    [ -f "$DEPLOYED_CHECK_VALUE" ] ;;
        systemd)   systemctl list-unit-files "$DEPLOYED_CHECK_VALUE" --no-legend 2>/dev/null | grep -q "$DEPLOYED_CHECK_VALUE" ;;
        *)
            echo "run_desktop_install: unknown DEPLOYED_CHECK_KIND '${DEPLOYED_CHECK_KIND:-<unset>}'" >&2
            return 1
            ;;
    esac
}

_desktop_not_deployed_msg() {
    local default_msg
    case "$DEPLOYED_CHECK_KIND" in
        container) default_msg="container '${DEPLOYED_CHECK_VALUE}' not found — skipping (deploy the environment first)" ;;
        systemd)   default_msg="service '${DEPLOYED_CHECK_VALUE}' not found — skipping (deploy the environment first)" ;;
        *)         default_msg="not deployed — skipping (deploy the environment first)" ;;
    esac
    echo "${NOT_DEPLOYED_MSG:-$default_msg}"
}

run_desktop_install() {
    # .desktop files, $APPS_DIR (~/.local/share/applications), and the
    # xdg-desktop-menu submenu machinery below are all Linux/XDG concepts
    # with no macOS equivalent — skip all of that on macOS. Two things
    # this environment produces DO have a real macOS equivalent though,
    # so those still happen: post-deploy-info.html (plain self-contained
    # HTML, no XDG involvement) gets regenerated, and any "link"-kind
    # entries (web UI URLs) get written as .webloc files on the Desktop —
    # macOS's own native double-clickable internet shortcut, see
    # install_webloc's comment. "exec"-kind entries (a terminal command,
    # e.g. launching run.sh) have no equivalent this library builds —
    # there's no macOS analog to a Linux Terminal=true .desktop launcher
    # without wrapping it in a real .app bundle, out of scope here.
    if [[ "$(uname)" == "Darwin" ]]; then
        if [ "${1:-}" = "--uninstall" ]; then
            _webloc_remove_all_for_menu "$MENU_ID"
            return 0
        fi
        if ! _desktop_is_deployed; then
            _webloc_remove_all_for_menu "$MENU_ID"
            echo "  ⚠  ${MENU_ID}: $(_desktop_not_deployed_msg)"
            return 0
        fi
        echo "  ${MENU_ID}: deployed ✓"
        _webloc_remove_all_for_menu "$MENU_ID"

        local i
        for i in "${!ENTRY_IDS[@]}"; do
            case "${ENTRY_KINDS[$i]}" in
                link)
                    install_webloc "${ENTRY_IDS[$i]}" "${ENTRY_TARGETS[$i]}" "$MENU_ID"
                    echo "  ✓  ${ENTRY_NAMES[$i]} (.webloc)"
                    ;;
                exec)
                    echo "  ⏭  ${ENTRY_NAMES[$i]}: skipped (macOS — no clickable-launcher equivalent for exec entries)"
                    ;;
                *)
                    echo "run_desktop_install: unknown ENTRY_KINDS[$i] '${ENTRY_KINDS[$i]}'" >&2
                    ;;
            esac
        done

        bash "$REPO_DIR/lib/run-info.sh" "$ENV_DIR" list >/dev/null 2>&1 || true
        install_webloc "$INFO_ID" "file://$ENV_DIR/post-deploy-info.html" "$MENU_ID"
        echo "  ✓  Info page (.webloc) — generated ${ENV_DIR}/post-deploy-info.html"
        return 0
    fi

    local category="X-PiBootstrap-${MENU_ID};"

    if [ "${1:-}" = "--uninstall" ]; then
        _desktop_remove_all_for_menu "$MENU_ID"
        remove_submenu "$MENU_ID"
        return 0
    fi

    mkdir -p "$APPS_DIR"

    if ! _desktop_is_deployed; then
        _desktop_remove_all_for_menu "$MENU_ID"
        remove_submenu "$MENU_ID"
        echo "  ⚠  ${MENU_ID}: $(_desktop_not_deployed_msg)"
        return 0
    fi
    echo "  ${MENU_ID}: deployed ✓"

    # Sweep before recreating — otherwise an entry ID renamed or removed
    # since the last install (while still deployed, so the branch above
    # never fires) would silently orphan its old .desktop file forever.
    _desktop_remove_all_for_menu "$MENU_ID"

    register_submenu "$MENU_ID" "$MENU_NAME" "${MENU_ICON:-utilities-terminal}"

    local i
    for i in "${!ENTRY_IDS[@]}"; do
        case "${ENTRY_KINDS[$i]}" in
            link)
                install_link_icon "${ENTRY_IDS[$i]}" "${ENTRY_NAMES[$i]}" "${ENTRY_COMMENTS[$i]}" \
                    "${ENTRY_TARGETS[$i]}" "${ENTRY_ICONS[$i]}" "$category"
                ;;
            exec)
                cat > "$APPS_DIR/${ENTRY_IDS[$i]}.desktop" << EOF
[Desktop Entry]
Name=${ENTRY_NAMES[$i]}
Comment=${ENTRY_COMMENTS[$i]}
Exec=${ENTRY_TARGETS[$i]}
Icon=${ENTRY_ICONS[$i]}
Type=Application
Categories=${category}
Terminal=${ENTRY_TERMINAL[$i]:-false}
EOF
                install_desktop_icon "${ENTRY_IDS[$i]}"
                ;;
            *)
                echo "run_desktop_install: unknown ENTRY_KINDS[$i] '${ENTRY_KINDS[$i]}'" >&2
                continue
                ;;
        esac
        echo "  ✓  ${ENTRY_NAMES[$i]}"
    done

    bash "$REPO_DIR/lib/run-info.sh" "$ENV_DIR" list >/dev/null 2>&1 || true
    install_info_icon "$INFO_ID" "$INFO_NAME" "$ENV_DIR/post-deploy-info.html" "$category"
    echo "  ✓  Info page"
}
