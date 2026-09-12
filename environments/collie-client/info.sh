#!/usr/bin/env bash
# Data lives in info.yaml; the OS-dependent pieces live here — the one thing
# that cannot be static YAML. See lib/info-lib.sh's _load_info_yaml, and
# environments/internet-pi/info.sh for the same pattern.
#
# What differs by platform: how `collie start` supervises the bridge, and
# therefore where its log is and what command reads it. Collie writes a
# `systemd --user` unit on Linux and a LaunchAgent plist on macOS, falling
# back to an unsupervised nohup'd background process where neither is
# available — notably a Mac administered only over SSH, which has no
# gui/<uid> domain to load an agent into.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_DIR/lib/info-lib.sh"

_load_info_yaml "$SCRIPT_DIR" "${1:-list}"

COLLIE_BIN_PATH="$(command -v collie 2>/dev/null || true)"
[ -n "$COLLIE_BIN_PATH" ] || COLLIE_BIN_PATH="(not on PATH — run \`collie link\`, or call \$HOME/.local/share/collie/current/bin/collie directly)"

case "$(uname -s)" in
    Darwin)
        _SERVICE_WHAT="launchd LaunchAgent"
        _SERVICE_WHERE="\$HOME/Library/LaunchAgents/ (a Mac reachable only over SSH gets an unsupervised background bridge instead)"
        _SERVICE_LOG="collie logs"
        ;;
    *)
        _SERVICE_WHAT="systemd --user unit"
        _SERVICE_WHERE="\$HOME/.config/systemd/user/collie.service"
        _SERVICE_LOG="journalctl --user -u collie -n 50 -f   (or: collie logs)"
        ;;
esac

# Appended rather than replaced: the YAML's own notes still apply, this just
# adds the facts that depend on where you are running.
USEFUL_COMMANDS="${USEFUL_COMMANDS}
     ── this machine ──
     Binary:    ${COLLIE_BIN_PATH}
     Service:   ${_SERVICE_WHAT} — ${_SERVICE_WHERE}
     Logs:      ${_SERVICE_LOG}
     Uninstall: use TEARDOWN (stops the bridge, withdraws the tailnet
                mapping, removes the service definition, binary and config;
                the config is backed up first, and ~/.local/state/collie —
                pairings and audit.log — is deliberately left alone)"

run_info
