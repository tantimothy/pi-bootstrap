#!/bin/bash
#
# Installs Herdr (https://herdr.dev) — an agent-aware terminal multiplexer —
# on THIS machine, plus a repo-managed config.toml. Idempotent; safe to
# re-run.
#
# This is a CLIENT-SIDE environment, like mac-terminal-setup: no container,
# nothing to deploy to a remote host. It installs into the current user's
# home and backs up anything it overwrites into
# $HOME/.pi-bootstrap-backups/herdr-client-<timestamp>/.
#
# Firstmate is NOT a dependency and is not installed here. Standalone Herdr
# is a complete, useful setup on its own — see README.md.

# --- CONFIGURATION ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
CONFIG_DIR="$HOME/.config/herdr"
BACKUP_DIR="$HOME/.pi-bootstrap-backups/herdr-client-$(date +%Y%m%d-%H%M%S)"
BACKUP_MADE=false

# deploy_environment() (lib/deploy-lib.sh) deliberately doesn't wrap run.sh
# in its own `script`-based session logging — see that function's comment.
# This environment has no interactive attach (host-only, no container), so
# the whole rest of this script is safe to self-log unconditionally.
source "$REPO_DIR/lib/deploy-lib.sh"
_selflog_start "$SCRIPT_DIR" "${REBUILD_POLICY:-FAST}"

# This script branches on $REBUILD_POLICY below, which is also what makes
# deploy.sh offer STOP/TEARDOWN/CLEAN for this environment at all: it
# decides by grepping run.sh for any POLICY reference rather than by
# hardcoding environment names. Every branch therefore has to do something
# genuinely distinct — see README's "Deployment Policies".
POLICY="${REBUILD_POLICY:-FAST}"

# --- PLATFORM DETECTION ---
# Unlike mac-terminal-setup (Darwin-only, guard-and-exit), this environment
# serves both macOS and Linux, so it detects and branches instead.
OS_NAME="$(uname -s)"
ARCH_NAME="$(uname -m)"
case "$OS_NAME" in
    Darwin) PLATFORM="macos" ;;
    Linux)  PLATFORM="linux" ;;
    *)
        echo "❌ herdr-client supports macOS and Linux only (found $OS_NAME)." >&2
        exit 1
        ;;
esac

# Herdr's release matrix builds aarch64-unknown-linux-musl and the two macOS
# targets. It publishes NO armv7 build, and its installer maps only
# aarch64|arm64 — so a 32-bit Raspberry Pi OS (which reports armv7l) would
# fail obscurely inside the installer. Fail clearly here instead.
if [ "$PLATFORM" = "linux" ]; then
    case "$ARCH_NAME" in
        aarch64|arm64) : ;;
        *)
            echo "❌ Herdr publishes no Linux build for '$ARCH_NAME'." >&2
            echo "   Only aarch64/arm64 is available — a 32-bit Raspberry Pi OS" >&2
            echo "   reports armv7l and is not supported. Reinstall with the" >&2
            echo "   64-bit Raspberry Pi OS, or run herdr-client on a Mac." >&2
            exit 1
            ;;
    esac
fi

# --- .env ---
# deploy.sh copies .env.example to .env and runs its parameters board before
# calling this script, but a direct invocation might not have.
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi
HERDR_VERSION="${HERDR_VERSION:-latest}"

echo "🔄 herdr-client — policy: $POLICY, platform: $PLATFORM/$ARCH_NAME"

# --- HELPERS ---

# Backs up $2 into BACKUP_DIR (preserving its path relative to $HOME) if it
# already exists and differs from $1, then copies $1 over it. Same helper
# mac-terminal-setup uses; see docs/refactoring-opportunities.md for the
# note that these have no shared home yet.
_deploy_file() {
    local src="$1" dest="$2"
    if [ -e "$dest" ] && ! cmp -s "$src" "$dest" 2>/dev/null; then
        local rel="${dest#"$HOME"/}"
        mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
        cp -a "$dest" "$BACKUP_DIR/$rel"
        BACKUP_MADE=true
        echo "   📦 Backed up existing $dest"
    fi
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
}

_herdr_bin() { command -v herdr 2>/dev/null; }

_herdr_installed_version() {
    local bin
    bin="$(_herdr_bin)" || return 1
    [ -n "$bin" ] || return 1
    "$bin" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# Stops the Herdr server if one is running.
#
# NOTE what this costs: Herdr's own docs state that when the server stops
# and starts again "the original pane processes are gone" — it restores the
# saved session SHAPE (workspaces, tabs, panes, cwd, layout, focus) but not
# the processes. In this repo's topology that is cheap on purpose: panes are
# ssh/docker-exec clients into agent containers, so stopping the server
# kills the CLIENT CONNECTIONS, not the agents, which keep running in each
# container's own tmux. Detach (ctrl+b q by default) is the non-destructive
# option and is NOT this.
_herdr_server_stop() {
    local bin
    bin="$(_herdr_bin)"
    if [ -z "$bin" ]; then
        echo "   ℹ️  herdr is not installed — nothing to stop."
        return 0
    fi
    echo "   🛑 Stopping the Herdr server (panes die; saved session shape survives)..."
    "$bin" server stop 2>/dev/null || echo "   ℹ️  No running server, or it had already stopped."
}

# --- INSTALL ---
#
# The official installer is used on both platforms rather than a hand-rolled
# download: it resolves the platform from `uname -m`, then looks up BOTH the
# URL and its SHA-256 in a release manifest and fails loudly when the
# manifest has no entry. So checksum verification is already done upstream —
# an earlier draft of this environment proposed adding our own, which would
# have been redundant.
_install_herdr() {
    local reason="$1"
    echo "   ⬇️  Installing Herdr ($reason)..."
    if ! command -v curl >/dev/null 2>&1; then
        echo "❌ curl is required to install Herdr." >&2
        return 1
    fi
    if [ "$HERDR_VERSION" = "latest" ]; then
        curl -fsSL https://herdr.dev/install.sh | sh
    else
        # The installer reads HERDR_VERSION from the environment for a pinned
        # install. Pinning matters for more than reproducibility here: `herdr
        # machine add` triggers an approval-based setup when client and
        # server versions are incompatible, and that setup offers to STOP the
        # remote server and its panes. Same version everywhere avoids it.
        curl -fsSL https://herdr.dev/install.sh | HERDR_VERSION="$HERDR_VERSION" sh
    fi
}

case "$POLICY" in
    STOP)
        _herdr_server_stop
        echo "✅ herdr-client stopped. Run FAST to reconcile, then launch \`herdr\` to restore the session shape."
        exit 0
        ;;
    TEARDOWN)
        _herdr_server_stop
        BIN="$(_herdr_bin)"
        if [ -n "$BIN" ]; then
            echo "   🗑️  Removing $BIN"
            rm -f "$BIN" 2>/dev/null || sudo rm -f "$BIN"
        fi
        if [ -d "$CONFIG_DIR" ]; then
            mkdir -p "$BACKUP_DIR"
            cp -R "$CONFIG_DIR" "$BACKUP_DIR/herdr-config"
            BACKUP_MADE=true
            echo "   📦 Backed up $CONFIG_DIR"
            rm -rf "$CONFIG_DIR"
        fi
        echo "✅ herdr-client removed. Config backed up under $BACKUP_DIR."
        exit 0
        ;;
    CLEAN)
        # CLEAN force-reinstalls AND stops the server afterwards. That second
        # half is not gratuitous: Herdr's install docs note that
        # package-manager updates do not get live handoff and "the compatible
        # old server keeps running" — you restart it with `herdr server stop`
        # when you want server-side changes from the new release. A CLEAN that
        # upgraded the binary and left the old server running would be exactly
        # the silently-stale-copy failure this repo has been bitten by before.
        _install_herdr "CLEAN — forced reinstall" || exit 1
        _herdr_server_stop
        ;;
    *)
        # FAST: install only if missing or not at the pinned version. Does not
        # start the server — Herdr's server starts when the user runs `herdr`,
        # and restores the saved session shape on that first run.
        CURRENT="$(_herdr_installed_version || true)"
        if [ -z "$(_herdr_bin)" ]; then
            _install_herdr "not installed" || exit 1
        elif [ "$HERDR_VERSION" != "latest" ] && [ "$CURRENT" != "$HERDR_VERSION" ]; then
            _install_herdr "pinned ${HERDR_VERSION}, found ${CURRENT:-unknown}" || exit 1
        else
            echo "   ✅ Herdr already installed (${CURRENT:-version unknown}) — leaving it alone."
        fi
        ;;
esac

# --- CONFIG ---
#
# The prefix override in config.toml is the load-bearing part. See README's
# "Nested tmux" — every agent environment in this repo auto-attaches you to
# a tmux session INSIDE its container, so any Herdr pane into one of them is
# Herdr -> ssh -> tmux, and Herdr's default prefix (ctrl+b) is tmux's
# default too.
echo "   ⚙️  Deploying config.toml to $CONFIG_DIR/"
_deploy_file "$SCRIPT_DIR/config.toml" "$CONFIG_DIR/config.toml"

# --- SUMMARY ---
if [ "$BACKUP_MADE" = true ]; then
    echo "   📦 Backups written to $BACKUP_DIR"
fi

INSTALLED="$(_herdr_installed_version || true)"
echo ""
echo "✅ herdr-client ready — Herdr ${INSTALLED:-(version unknown)} on $PLATFORM/$ARCH_NAME."
echo "   Launch with:  herdr"
echo "   Link another machine:  herdr machine add <host> --label \"...\""
echo "   Generate panes for deployed environments: see the menu action, or"
echo "   bash $SCRIPT_DIR/scripts/generate-session.sh --help"
