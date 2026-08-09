#!/bin/bash
# Shared launcher for GUI tools that run inside the nettools container on
# the host's X11/XWayland display. Sourced by scripts/launch-<tool>.sh, not
# run directly.
#
# Grants ONLY the local root identity used inside this container X access,
# and revokes it when the tool closes — narrower than the common
# `xhost +local:` pattern, which would authorize every local user for the
# rest of the X session.

launch_gui_tool() {
    local display_name="$1"
    local binary="$2"
    shift 2

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    local env_dir
    env_dir="$(cd "$script_dir/.." && pwd)"
    local docker="${DOCKER_CMD:-docker}"

    if [ -f "$env_dir/.env" ]; then
        set -a
        source "$env_dir/.env"
        set +a
    fi

    local container_name="${NETTOOLS_CONTAINER_NAME:-nettools}"
    local display="${DISPLAY:-:0}"
    local host_x11_unix_path="${HOST_X11_UNIX_PATH:-/tmp/.X11-unix}"

    show_gui_error() {
        local message="$1"
        if command -v zenity >/dev/null 2>&1; then
            zenity --error --title="Pi-hole + WireGuard $display_name" --text="$message"
        else
            echo "$display_name: $message" >&2
        fi
    }

    if ! "$docker" ps --format '{{.Names}}' | grep -Fxq "$container_name"; then
        show_gui_error "Container '$container_name' is not running. Deploy this environment with FAST first."
        exit 1
    fi

    if ! "$docker" exec "$container_name" sh -c "command -v $binary" >/dev/null 2>&1; then
        show_gui_error "$display_name is not installed in the active container. Run CLEAN once, then try again."
        exit 1
    fi

    if [ ! -d "$host_x11_unix_path" ]; then
        show_gui_error "The X11 socket directory '$host_x11_unix_path' is unavailable. Launch this from the Pi desktop."
        exit 1
    fi

    if ! command -v xhost >/dev/null 2>&1; then
        show_gui_error "The host 'xhost' command is missing. Install x11-xserver-utils and try again."
        exit 1
    fi

    if ! xhost +SI:localuser:root >/dev/null 2>&1; then
        show_gui_error "Could not authorize the container on display '$display'. Launch this from the active Pi desktop session."
        exit 1
    fi
    trap 'xhost -SI:localuser:root >/dev/null 2>&1 || true' EXIT

    "$docker" exec -e DISPLAY="$display" "$container_name" "$binary" "$@"
}
