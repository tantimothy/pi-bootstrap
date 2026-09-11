#!/usr/bin/env bash
# Data lives in info.yaml; the OS-dependent pieces live here — the one thing
# that cannot be static YAML. See lib/info-lib.sh's _load_info_yaml, and
# environments/internet-pi/info.sh for the same pattern.
#
# What differs by platform: where the Herdr binary lands, and therefore what
# "uninstall it yourself" actually means. Homebrew on macOS puts it under a
# prefix that itself differs between Apple Silicon and Intel; the Linux
# installer drops it on PATH under the user's home.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_DIR/lib/info-lib.sh"

_load_info_yaml "$SCRIPT_DIR" "${1:-list}"

HERDR_BIN="$(command -v herdr 2>/dev/null || true)"

if [ -n "$HERDR_BIN" ]; then
    _HERDR_WHERE="$HERDR_BIN"
else
    case "$(uname -s)" in
        Darwin) _HERDR_WHERE="(not installed — Homebrew would put it under \$(brew --prefix)/bin)" ;;
        *)      _HERDR_WHERE="(not installed — the installer puts it on PATH under \$HOME)" ;;
    esac
fi

# Appended rather than replaced: the YAML's own notes still apply, this just
# adds the two facts that depend on where you are running.
USEFUL_COMMANDS="${USEFUL_COMMANDS}
     ── this machine ──
     Binary:    ${_HERDR_WHERE}
     Uninstall: use TEARDOWN (stops the server, removes binary + config,
                backs the config up first)"

run_info
