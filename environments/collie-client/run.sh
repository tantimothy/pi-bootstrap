#!/bin/bash
#
# Installs Collie (https://colliepwa.dev) — a mobile web interface for
# terminal-based AI agents, served over Tailscale — on THIS machine, and
# seeds its .env.
#
# CLIENT-SIDE, like herdr-client and mac-terminal-setup: no container,
# nothing deployed to a remote host. It installs into the current user's
# home and backs up anything it would overwrite into
# $HOME/.pi-bootstrap-backups/collie-client-<timestamp>/.
#
# ─────────────────────────────────────────────────────────────────────────
# READ THIS BEFORE CHANGING ANYTHING BELOW
#
# Collie is remote shell access to this machine, from a phone, by design.
# Upstream says so in the first line of its own security page: "a single
# Collie API call sends arbitrary keystrokes directly to a live terminal
# pane… treat the URL as a root login."
#
# Chained with Herdr, that is:  phone → Collie → Herdr → every agent pane.
#
# So this script does three things no other environment here does:
#   1. Checks every precondition BEFORE touching anything, and fails with
#      the reason rather than installing a half-working bridge.
#   2. Refuses to proceed while Tailscale Funnel is enabled anywhere on
#      this machine. `serve` is tailnet-only; `funnel` is the open
#      internet. Upstream: "there is no supported use case for running
#      Collie over Funnel."
#   3. Asks for an explicit yes before the first install — the same
#      mechanism mac-terminal-setup uses for its whimsy prompt, but for a
#      security decision.
# ─────────────────────────────────────────────────────────────────────────

# --- CONFIGURATION ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
COLLIE_DIR_DEFAULT="$HOME/.local/share/collie"
COLLIE_CONFIG_DIR="$HOME/.config/collie"
BACKUP_DIR="$HOME/.pi-bootstrap-backups/collie-client-$(date +%Y%m%d-%H%M%S)"
BACKUP_MADE=false

# Same reasoning as herdr-client: host-only, no interactive attach, so the
# whole script is safe to self-log unconditionally.
source "$REPO_DIR/lib/deploy-lib.sh"
_selflog_start "$SCRIPT_DIR" "${REBUILD_POLICY:-FAST}"

# deploy.sh offers STOP/TEARDOWN/CLEAN for an environment by grepping its
# run.sh for any POLICY reference. Every branch below does something
# genuinely distinct — see README's "Deployment Policies".
POLICY="${REBUILD_POLICY:-FAST}"

# --- PLATFORM DETECTION ---
OS_NAME="$(uname -s)"
ARCH_NAME="$(uname -m)"
case "$OS_NAME" in
    Darwin) PLATFORM="macos" ;;
    Linux)  PLATFORM="linux" ;;
    *)
        echo "❌ collie-client supports macOS and Linux only (found $OS_NAME)." >&2
        exit 1
        ;;
esac

# Collie's release workflow ships exactly three payloads — linux-x64,
# linux-arm64 and macos-arm64. macos-x64 is present in the matrix but
# commented out, i.e. deliberately not published. Its installer maps
# x86_64|amd64 -> x64 and aarch64|arm64 -> arm64 and dies on anything else,
# so a 32-bit Raspberry Pi OS (armv7l) fails there. Fail clearly here.
case "$ARCH_NAME" in
    x86_64|amd64|aarch64|arm64) : ;;
    *)
        echo "❌ Collie publishes no binary for '$ARCH_NAME'." >&2
        echo "   Only x86_64 and aarch64/arm64 are built — a 32-bit Raspberry Pi OS" >&2
        echo "   reports armv7l and is not supported. Use the 64-bit Raspberry Pi OS," >&2
        echo "   or run collie-client on a Mac." >&2
        exit 1
        ;;
esac
if [ "$PLATFORM" = "macos" ] && { [ "$ARCH_NAME" = "x86_64" ] || [ "$ARCH_NAME" = "amd64" ]; }; then
    echo "❌ Collie publishes no macOS x86_64 build (the release matrix has the row," >&2
    echo "   commented out). An Intel Mac needs a source build with Bun — out of" >&2
    echo "   scope for this environment." >&2
    exit 1
fi

# --- .env ---
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi
COLLIE_TAG="${COLLIE_TAG:-latest}"
COLLIE_INSTALL_DIR="${COLLIE_INSTALL_DIR:-$COLLIE_DIR_DEFAULT}"
COLLIE_PORT="${COLLIE_PORT:-8787}"
COLLIE_TRUSTED_USER="${COLLIE_TRUSTED_USER:-}"
COLLIE_ACK_REMOTE_SHELL="${COLLIE_ACK_REMOTE_SHELL:-}"
COLLIE_ALLOW_EXISTING_FUNNEL="${COLLIE_ALLOW_EXISTING_FUNNEL:-}"

COLLIE_BIN=""
_collie_bin() {
    if [ -x "$COLLIE_INSTALL_DIR/current/bin/collie" ]; then
        printf '%s' "$COLLIE_INSTALL_DIR/current/bin/collie"
        return 0
    fi
    command -v collie 2>/dev/null
}

echo "🔄 collie-client — policy: $POLICY, platform: $PLATFORM/$ARCH_NAME"

# --- HELPERS ---

_backup_path() {
    local target="$1" rel
    [ -e "$target" ] || return 0
    rel="${target#"$HOME"/}"
    mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
    cp -a "$target" "$BACKUP_DIR/$rel"
    BACKUP_MADE=true
    echo "   📦 Backed up $target"
}

# Appends KEY=VALUE to Collie's .env only when KEY is absent entirely.
#
# NEVER rewrites a key that is already there. That is not politeness: this
# is the same file `collie push-keys` writes the VAPID keypair into, and
# `collie start` writes COLLIE_MUX into. Clobbering it would silently
# destroy push notifications and the multiplexer choice. A differing value
# is reported and left alone — the operator decides.
_ensure_env_key() {
    local file="$1" key="$2" value="$3" existing
    if grep -qE "^[[:space:]]*${key}=" "$file" 2>/dev/null; then
        existing="$(grep -E "^[[:space:]]*${key}=" "$file" | tail -1)"
        existing="${existing#*=}"
        if [ "$existing" != "$value" ]; then
            echo "   ℹ️  ${key} is already set to '${existing}' in $file — leaving it."
            echo "      (this environment's .env says '${value}'; edit one of them if that is wrong)"
        fi
        return 0
    fi
    printf '%s=%s\n' "$key" "$value" >> "$file"
    echo "   ✚ ${key}=${value}"
}

# --- PRECONDITIONS ---
#
# Checked before anything is installed, and each failure names the fix.
# This is the repo's "anchors are checked before use, never guessed" rule
# applied to a security-sensitive install.
_check_preconditions() {
    local fatal=0

    # 1. Herdr. Collie mirrors ONE multiplexer per install; this repo drives
    #    it at Herdr, which is what herdr-client installs.
    if ! command -v herdr >/dev/null 2>&1; then
        echo "❌ herdr is not installed." >&2
        echo "   Collie bridges a multiplexer's socket; this repo points it at Herdr." >&2
        echo "   Deploy the 'herdr-client' environment first." >&2
        fatal=1
    fi

    # 2. Tailscale. Skippable only when the operator has deliberately opted
    #    into a reverse proxy instead (Collie's own COLLIE_SKIP_SERVE).
    if [ "${COLLIE_SKIP_SERVE:-}" = "1" ]; then
        echo "   ⚠️  COLLIE_SKIP_SERVE=1 — Tailscale checks skipped."
        echo "      Collie will publish NOTHING; your own reverse proxy is the front"
        echo "      door and its auth is the only thing between a phone and your shell."
    elif ! command -v tailscale >/dev/null 2>&1; then
        echo "❌ tailscale is not installed." >&2
        echo "   Collie's default front door is 'tailscale serve' — tailnet-only HTTPS." >&2
        echo "   Install Tailscale and log in, or set COLLIE_SKIP_SERVE=1 in .env if" >&2
        echo "   you are deliberately fronting it with your own reverse proxy." >&2
        fatal=1
    elif ! tailscale status >/dev/null 2>&1; then
        echo "❌ tailscale is installed but this machine is not logged in / not running." >&2
        echo "   Run 'tailscale up' first, then deploy again." >&2
        fatal=1
    fi

    # 3. Funnel. The one thing upstream says never to do.
    #
    #    This refuses on ANY funnel enabled on this machine, not just one
    #    pointed at Collie's port: matching a funnel to a backend port means
    #    parsing Tailscale's JSON without jq, and a wrong parse here fails
    #    open, which is the wrong direction for this particular check. If
    #    you funnel something unrelated, set COLLIE_ALLOW_EXISTING_FUNNEL=1
    #    — that is a statement that you have checked it yourself.
    if command -v tailscale >/dev/null 2>&1; then
        local serve_json
        serve_json="$(tailscale serve status --json 2>/dev/null || true)"
        if printf '%s' "$serve_json" | tr -d '[:space:]' | grep -q '"AllowFunnel":{[^}]*true'; then
            if [ "$COLLIE_ALLOW_EXISTING_FUNNEL" = "1" ]; then
                echo "   ⚠️  Tailscale Funnel is enabled on this machine."
                echo "      COLLIE_ALLOW_EXISTING_FUNNEL=1 says you have checked it is not"
                echo "      pointed at Collie. Verify with: tailscale funnel status"
            else
                echo "❌ Tailscale Funnel is enabled on this machine." >&2
                echo "   'funnel' publishes to the open INTERNET; 'serve' is tailnet-only." >&2
                echo "   Collie is remote shell access — upstream states there is no" >&2
                echo "   supported use case for running it over Funnel." >&2
                echo "" >&2
                echo "   Check what is funnelled:  tailscale funnel status" >&2
                echo "   Turn one off:             tailscale funnel <port> off" >&2
                echo "" >&2
                echo "   If the funnel is for something else entirely and you have" >&2
                echo "   verified it does not reach Collie's port (${COLLIE_PORT}), set" >&2
                echo "   COLLIE_ALLOW_EXISTING_FUNNEL=1 in this environment's .env." >&2
                fatal=1
            fi
        fi
    fi

    [ "$fatal" -eq 0 ]
}

# --- CONSENT ---
#
# Asked once, before the first install only. Re-running FAST against an
# existing install does not re-prompt — the decision has been made and
# nagging teaches people to type y without reading.
_confirm_remote_shell() {
    if [ "$COLLIE_ACK_REMOTE_SHELL" = "1" ]; then
        echo "   ✅ COLLIE_ACK_REMOTE_SHELL=1 — install acknowledged in .env."
        return 0
    fi
    echo ""
    echo "   ⚠️  ─────────────────────────────────────────────────────────────"
    echo "   ⚠️   Collie is REMOTE SHELL ACCESS to this machine, from a phone."
    echo "   ⚠️"
    echo "   ⚠️   Anyone who can reach the URL can read every pane — source,"
    echo "   ⚠️   secrets, environment variables, agent output — and run any"
    echo "   ⚠️   command as $(whoami). There is no sandbox and no allow-list."
    echo "   ⚠️   With herdr-client deployed, the chain is:"
    echo "   ⚠️"
    echo "   ⚠️       phone → Collie → Herdr → every agent pane"
    echo "   ⚠️"
    echo "   ⚠️   Mitigations, in the order they matter:"
    echo "   ⚠️     • tailnet-only (this script refuses to run alongside Funnel)"
    echo "   ⚠️     • 'collie pair' — the write credential, do this immediately"
    echo "   ⚠️     • COLLIE_TRUSTED_USER — reject any other tailnet login"
    echo "   ⚠️ ─────────────────────────────────────────────────────────────"
    echo ""
    if [ ! -t 0 ]; then
        echo "❌ Not an interactive terminal, and COLLIE_ACK_REMOTE_SHELL is not set." >&2
        echo "   This one install asks out loud on purpose. Either deploy from a" >&2
        echo "   terminal, or set COLLIE_ACK_REMOTE_SHELL=1 in this environment's" >&2
        echo "   .env to record that you have read the above." >&2
        return 1
    fi
    local answer
    read -rp "   Install Collie on this machine? [y/N]: " answer
    case "$answer" in
        [Yy]*) return 0 ;;
        *) echo "   Cancelled — nothing installed."; return 1 ;;
    esac
}

# --- INSTALL ---
#
# The official installer is used rather than a hand-rolled download: it
# downloads the release tarball AND its .sha256 sidecar and refuses to
# install anything it cannot verify, never asks for sudo, and writes only
# inside $COLLIE_DIR and ~/.local/bin. Adding our own checksum step would
# be redundant — the same conclusion herdr-client reached.
#
# Two behaviours worth knowing, both read out of scripts/install.sh:
#   * UNPINNED over an existing install: it prints "leaving it alone" and
#     exits 0. That is what makes FAST naturally idempotent.
#   * PINNED (COLLIE_TAG): it lays that version down BESIDE the existing one
#     and flips `current`. Not a clobber, and the rescue path when the
#     installed version is itself the broken thing.
_install_collie() {
    local reason="$1"
    echo "   ⬇️  Installing Collie ($reason)..."
    if ! command -v curl >/dev/null 2>&1; then
        echo "❌ curl is required to install Collie." >&2
        return 1
    fi
    if [ "$COLLIE_TAG" = "latest" ]; then
        curl -fsSL https://colliepwa.dev/install.sh | COLLIE_DIR="$COLLIE_INSTALL_DIR" sh
    else
        curl -fsSL https://colliepwa.dev/install.sh | COLLIE_DIR="$COLLIE_INSTALL_DIR" COLLIE_TAG="$COLLIE_TAG" sh
    fi
}

# Stops the bridge AND withdraws the tailscale serve mapping.
#
# Both halves matter. `collie stop` pauses the bridge but leaves the serve
# mapping published, so the tailnet URL stays mapped to a dead port —
# "stopped" would mean "broken", not "unreachable". `collie unserve` takes
# the mapping down, and only ever one Collie created.
_collie_stop() {
    local bin
    bin="$(_collie_bin)"
    if [ -z "$bin" ]; then
        echo "   ℹ️  collie is not installed — nothing to stop."
        return 0
    fi
    echo "   🛑 Stopping the Collie bridge..."
    "$bin" stop 2>/dev/null || echo "   ℹ️  Bridge was not running."
    echo "   🚪 Withdrawing the tailscale serve mapping..."
    "$bin" unserve 2>/dev/null || echo "   ℹ️  No mapping of Collie's to withdraw."
}

case "$POLICY" in
    STOP)
        _collie_stop
        echo "✅ collie-client stopped — the bridge is down AND the tailnet URL is withdrawn."
        echo "   Start it again with:  collie start"
        exit 0
        ;;
    TEARDOWN)
        _collie_stop
        BIN="$(_collie_bin)"
        if [ -n "$BIN" ]; then
            # `collie uninstall` removes the service definition (systemd --user
            # unit on Linux, LaunchAgent plist on macOS) and the serve mapping.
            # It deliberately keeps .env and the install tree; we remove those.
            echo "   🧹 collie uninstall (service definition + serve mapping)..."
            "$BIN" uninstall 2>/dev/null || echo "   ℹ️  Nothing for uninstall to remove."
        fi
        _backup_path "$COLLIE_CONFIG_DIR"
        rm -rf "$COLLIE_CONFIG_DIR"
        if [ -d "$COLLIE_INSTALL_DIR" ]; then
            echo "   🗑️  Removing $COLLIE_INSTALL_DIR"
            rm -rf "$COLLIE_INSTALL_DIR"
        fi
        # The PATH symlink `collie link` published, only if it still points
        # at the tree we just removed.
        if [ -L "$HOME/.local/bin/collie" ] && [ ! -e "$HOME/.local/bin/collie" ]; then
            rm -f "$HOME/.local/bin/collie"
            echo "   🗑️  Removed the dangling ~/.local/bin/collie symlink"
        fi
        echo ""
        echo "✅ collie-client removed. Config backed up under $BACKUP_DIR."
        echo "   NOT removed — delete by hand if you want them gone:"
        echo "     ${COLLIE_STATE_DIR:-$HOME/.local/state/collie}  (pairings, beacons, uploads, audit.log)"
        exit 0
        ;;
    CLEAN|FAST|*)
        _check_preconditions || exit 1
        EXISTING="$(_collie_bin)"
        if [ -z "$EXISTING" ]; then
            _confirm_remote_shell || exit 1
            _install_collie "not installed" || exit 1
        elif [ "$POLICY" = "CLEAN" ]; then
            # CLEAN stops first, then moves the version. Upstream is explicit
            # that a replaced-on-disk Collie "keeps serving the old build on a
            # deleted binary until you restart it" — exactly the
            # silently-stale-copy failure this repo has been bitten by before
            # (docs/lessons-learned/nanoclaw-mnemon.md). Stopping first makes
            # that impossible rather than merely unlikely.
            _collie_stop
            if [ "$COLLIE_TAG" = "latest" ]; then
                # The installer no-ops over an existing install; `collie update`
                # is upstream's own forward path and keeps the previous version
                # staged for `collie update --rollback`.
                echo "   ⬆️  collie update (unpinned — tracking the newest stable release)..."
                "$EXISTING" update || exit 1
            else
                _install_collie "CLEAN — pinned $COLLIE_TAG" || exit 1
            fi
        else
            echo "   ✅ Collie already installed — leaving it alone."
            echo "      (CLEAN moves it forward; this is FAST.)"
        fi
        ;;
esac

# --- CONFIG ---
#
# Seeded, never overwritten. See _ensure_env_key's comment: this is the same
# file `collie push-keys` and `collie start` write into.
mkdir -p "$COLLIE_CONFIG_DIR"
COLLIE_ENV="$COLLIE_CONFIG_DIR/.env"
if [ ! -f "$COLLIE_ENV" ]; then
    echo "   ⚙️  Seeding $COLLIE_ENV"
    cat > "$COLLIE_ENV" <<'SEED'
# Seeded by pi-bootstrap's collie-client environment.
# Collie reads this only at startup — run `collie restart` after editing.
# Every option: https://github.com/AltanS/collie/blob/main/.env.example
SEED
else
    echo "   ⚙️  $COLLIE_ENV exists — adding only the keys it does not have."
fi

# COLLIE_MUX: Collie mirrors ONE multiplexer per install and refuses to
# guess when it can see more than one. This repo's answer is always herdr.
_ensure_env_key "$COLLIE_ENV" COLLIE_MUX herdr
_ensure_env_key "$COLLIE_ENV" COLLIE_PORT "$COLLIE_PORT"
if [ -n "$COLLIE_TRUSTED_USER" ]; then
    _ensure_env_key "$COLLIE_ENV" COLLIE_TRUSTED_USER "$COLLIE_TRUSTED_USER"
else
    echo "   ⚠️  COLLIE_TRUSTED_USER is unset — Collie runs in open single-user"
    echo "      mode and anyone on your tailnet who reaches the URL has full"
    echo "      control. Set it in this environment's .env and redeploy."
fi

# --- SUMMARY ---
COLLIE_BIN="$(_collie_bin)"
[ "$BACKUP_MADE" = true ] && echo "   📦 Backups written to $BACKUP_DIR"

echo ""
echo "✅ collie-client ready — Collie $("${COLLIE_BIN:-true}" version 2>/dev/null | head -1) on $PLATFORM/$ARCH_NAME."
echo ""
echo "   Not started. Collie publishes a URL the moment it starts, so that"
echo "   is your call, not a deploy's:"
echo ""
echo "     collie start        # build if needed, serve, print the tailnet URL"
echo "     collie pair         # ⚠️  DO THIS NEXT — the write credential"
echo "     collie qr           # the URL as a scannable code"
echo "     collie status       # readiness, version, URLs"
echo ""
# The socket, not a `herdr server status` call: Collie's own .env.example
# documents ~/.config/herdr/herdr.sock as HERDR_SOCKET_PATH's default, so the
# socket's existence is a verified fact about Herdr. The exact spelling of a
# herdr status subcommand is not, and this repo does not guess CLI syntax.
if [ ! -S "${HERDR_SOCKET_PATH:-$HOME/.config/herdr/herdr.sock}" ]; then
    echo "   ℹ️  No Herdr socket at ${HERDR_SOCKET_PATH:-$HOME/.config/herdr/herdr.sock}."
    echo "      Collie bridges it, so start Herdr first:  herdr"
    echo ""
fi
echo "   Full notes: $SCRIPT_DIR/README.md"
