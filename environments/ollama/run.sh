#!/usr/bin/env bash
#
# Installs and starts one native Ollama daemon shared by every AI environment
# in this repository. Idempotent and safe to re-run.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
[ -f "$SCRIPT_DIR/.env" ] && { set -a; source "$SCRIPT_DIR/.env"; set +a; }

# Two different meanings, one variable name — the distinction is the whole
# point of keeping these separate, and conflating them was a real bug (see
# ollama-watchdog.sh's restart_ollama() and
# docs/lessons-learned/general.md):
#   OLLAMA_HOST       what THIS SCRIPT probes — a full URL.
#   OLLAMA_SERVE_HOST what `ollama serve` BINDS to — a host:port, no scheme.
# Ollama's own default bind is 127.0.0.1:11434, which answers on this host and
# refuses every container: traffic arriving via host.docker.internal is
# external as far as a loopback listener is concerned. Set OLLAMA_SERVE_HOST
# to 0.0.0.0:11434 if anything containerised needs this daemon — that also
# exposes it to your local network, so it stays opt-in.
OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
OLLAMA_SERVE_HOST="${OLLAMA_SERVE_HOST:-}"
OLLAMA_CMD="${OLLAMA_CMD:-ollama}"
POLICY="${REBUILD_POLICY:-FAST}"

source "$REPO_DIR/lib/locale-lib.sh" || true

_healthy() {
    curl -fsS --max-time 5 "$OLLAMA_HOST/api/tags" >/dev/null 2>&1
}

_install_ollama() {
    case "$(uname -s)" in
        Darwin)
            if ! command -v brew >/dev/null 2>&1; then
                echo "❌ Homebrew is required for the automated macOS install." >&2
                echo "   Install it from https://brew.sh or install Ollama from https://ollama.com/download"
                return 1
            fi
            brew install ollama
            ;;
        Linux)
            case "$(uname -m)" in
                aarch64|arm64|x86_64|amd64) ;;
                *)
                    echo "❌ Ollama requires a 64-bit Linux OS; found architecture $(uname -m)." >&2
                    echo "   Raspberry Pi users should install 64-bit Raspberry Pi OS." >&2
                    return 1
                    ;;
            esac
            if ! command -v curl >/dev/null 2>&1; then
                echo "❌ curl is required by Ollama's official Linux installer." >&2
                return 1
            fi
            curl -fsSL https://ollama.com/install.sh | sh
            ;;
        *)
            echo "❌ Automated Ollama setup supports macOS and Linux only." >&2
            return 1
            ;;
    esac
}

# Starts `ollama serve` with OLLAMA_SERVE_HOST as its bind address when one is
# set, and otherwise strips OLLAMA_HOST from the child's environment entirely.
# That strip is not optional: sourcing .env above with `set -a` exports
# OLLAMA_HOST, and `ollama serve` reads that name as its BIND address — so
# without this it would bind to the probe URL (http://localhost:11434), i.e.
# loopback, which is exactly the failure this variable exists to prevent.
_serve_bare() {
    if [ -n "$OLLAMA_SERVE_HOST" ]; then
        OLLAMA_HOST="$OLLAMA_SERVE_HOST" nohup "$OLLAMA_CMD" serve >> "$HOME/.ollama-server.log" 2>&1 &
    else
        env -u OLLAMA_HOST nohup "$OLLAMA_CMD" serve >> "$HOME/.ollama-server.log" 2>&1 &
    fi
}

# brew services and Ollama.app both launch through launchd, which does NOT
# inherit this shell's environment — the only supported way to reach them is
# launchctl's own session environment. This is Ollama's own documented macOS
# procedure, not a workaround, but it does set the variable for the whole
# login session rather than just this daemon, so it is announced rather than
# done silently.
_apply_macos_serve_host() {
    [ -z "$OLLAMA_SERVE_HOST" ] && return 0
    echo "🔧 Setting OLLAMA_HOST=${OLLAMA_SERVE_HOST} in the launchd session so Ollama binds there."
    echo "   (Session-wide and not persistent across reboots — see this environment's README.)"
    launchctl setenv OLLAMA_HOST "$OLLAMA_SERVE_HOST" 2>/dev/null || true
}

_start_ollama() {
    case "$(uname -s)" in
        Darwin)
            if command -v brew >/dev/null 2>&1 && brew list ollama >/dev/null 2>&1; then
                _apply_macos_serve_host
                brew services start ollama
            elif [ -d "/Applications/Ollama.app" ]; then
                _apply_macos_serve_host
                open -a Ollama
            else
                _serve_bare
            fi
            ;;
        Linux)
            if command -v systemctl >/dev/null 2>&1 &&
               systemctl list-unit-files 2>/dev/null | grep -q '^ollama\.service'; then
                if [ -n "$OLLAMA_SERVE_HOST" ]; then
                    echo "ℹ️  OLLAMA_SERVE_HOST is set, but ollama.service's environment is owned by systemd, not this script." >&2
                    echo "   Apply it once with:  sudo systemctl edit ollama" >&2
                    echo "   adding:              Environment=\"OLLAMA_HOST=${OLLAMA_SERVE_HOST}\"" >&2
                    echo "   then:                sudo systemctl restart ollama" >&2
                fi
                sudo systemctl enable --now ollama
            else
                _serve_bare
            fi
            ;;
    esac
}

# Reports what Ollama is ACTUALLY listening on once it's up, and warns when
# that's loopback-only. Worth doing unconditionally rather than only when
# OLLAMA_SERVE_HOST is set: a loopback bind is invisible to every check this
# script otherwise performs (they all probe localhost, which succeeds either
# way), and it silently breaks every containerised consumer. That gap cost
# five rounds of misdiagnosis — see docs/lessons-learned/nanoclaw-mnemon.md.
_report_bind_address() {
    local listeners=""
    if command -v lsof >/dev/null 2>&1; then
        listeners=$(lsof -nP -iTCP:11434 -sTCP:LISTEN 2>/dev/null \
            | awk 'NR>1 { for (i = 1; i <= NF; i++) if ($i ~ /[.:]11434$/) print $i }')
    elif command -v ss >/dev/null 2>&1; then
        listeners=$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep ':11434$' || true)
    elif command -v netstat >/dev/null 2>&1; then
        listeners=$(netstat -an 2>/dev/null | awk '/LISTEN/ {print $4}' | grep '[.:]11434$' || true)
    fi
    [ -z "$listeners" ] && return 0

    echo "🔌 Listening on:"
    printf '%s\n' "$listeners" | sed 's/^/     /'

    local loopback non_loopback
    loopback=$(printf '%s\n' "$listeners" | grep -c -e '^127\.0\.0\.1' -e '^\[::1\]' -e '^::1' -e '^localhost' || true)
    non_loopback=$(printf '%s\n' "$listeners" | grep -vc -e '^127\.0\.0\.1' -e '^\[::1\]' -e '^::1' -e '^localhost' || true)

    # Both kinds present means more than one Ollama is running — one bound
    # wide, one on loopback. Seen for real: a manual restart bound *:11434 over
    # IPv6 while a second process (the watchdog's) held 127.0.0.1:11434 over
    # IPv4, and containers stayed refused because they connect over IPv4 and
    # the only IPv4 listener was the loopback one. A naive "is anything bound
    # wide?" check calls that healthy, so it gets its own warning.
    if [ "$loopback" -gt 0 ] && [ "$non_loopback" -gt 0 ]; then
        echo "" >&2
        echo "⚠️  Both a loopback and a non-loopback listener are present on 11434." >&2
        echo "   That means more than one Ollama process is running. Containers may" >&2
        echo "   still be refused, depending on which address family they connect over" >&2
        echo "   — a wide IPv6 listener does not help a container dialling IPv4." >&2
        echo "   Stop them all and start one:  pkill -x ollama" >&2
        echo "   then redeploy this environment with OLLAMA_SERVE_HOST set." >&2
        echo "" >&2
        return 0
    fi

    if [ "$non_loopback" -gt 0 ]; then
        return 0
    fi
    echo "" >&2
    echo "⚠️  Loopback only — this host can reach Ollama, containers cannot." >&2
    echo "   Anything reaching it via host.docker.internal:11434 will be REFUSED," >&2
    echo "   which shows up as mnemon reporting 'ollama_available: false' and as" >&2
    echo "   agent-side Ollama tools failing, with no error on this side." >&2
    echo "   To fix: set OLLAMA_SERVE_HOST=0.0.0.0:11434 in this environment's .env" >&2
    echo "   and redeploy. Note that also exposes Ollama to your local network." >&2
    echo "" >&2
}

_stop_ollama() {
    case "$(uname -s)" in
        Darwin)
            if command -v brew >/dev/null 2>&1 && brew list ollama >/dev/null 2>&1; then
                brew services stop ollama >/dev/null 2>&1 || true
            fi
            pgrep -x "Ollama" >/dev/null 2>&1 && killall Ollama 2>/dev/null || true
            pgrep -x "ollama" >/dev/null 2>&1 && pkill -x ollama 2>/dev/null || true
            ;;
        Linux)
            if command -v systemctl >/dev/null 2>&1 &&
               systemctl list-unit-files 2>/dev/null | grep -q '^ollama\.service'; then
                sudo systemctl stop ollama
            else
                pgrep -x "ollama" >/dev/null 2>&1 && pkill -x ollama 2>/dev/null || true
            fi
            ;;
    esac
    echo "✅ Shared Ollama daemon stopped. Downloaded models are unchanged."
}

# Removes the native runtime installed by this environment while deliberately
# preserving model data (~/.ollama on macOS/user-mode Linux and
# /usr/share/ollama for the official Linux system service). WIPE is not exposed
# for this environment; models are removed one at a time through the Delete
# action instead.
_teardown_ollama() {
    local ollama_bin=""
    local ollama_lib=""

    _stop_ollama
    case "$(uname -s)" in
        Darwin)
            if command -v brew >/dev/null 2>&1 && brew list ollama >/dev/null 2>&1; then
                brew uninstall ollama
            elif [ -d "/Applications/Ollama.app" ]; then
                sudo rm -rf -- "/Applications/Ollama.app"
                [ -L "/usr/local/bin/ollama" ] && sudo rm -f -- "/usr/local/bin/ollama"
            else
                echo "⚠️  Ollama's install method is not recognized; the stopped runtime was not removed." >&2
                echo "   The shared model cache remains untouched." >&2
                return 1
            fi
            ;;
        Linux)
            if command -v systemctl >/dev/null 2>&1 &&
               systemctl list-unit-files 2>/dev/null | grep -q '^ollama\.service'; then
                sudo systemctl disable ollama >/dev/null 2>&1 || true
                [ -f "/etc/systemd/system/ollama.service" ] &&
                    sudo rm -f -- "/etc/systemd/system/ollama.service"
                sudo systemctl daemon-reload
            fi

            ollama_bin="${OLLAMA_TEARDOWN_BIN:-$(command -v ollama 2>/dev/null || true)}"
            case "$ollama_bin" in
                /usr/local/bin/ollama)
                    ollama_lib="/usr/local/lib/ollama"
                    sudo rm -f -- "$ollama_bin"
                    [ -d "$ollama_lib" ] && sudo rm -rf -- "$ollama_lib"
                    ;;
                /usr/bin/ollama)
                    ollama_lib="/usr/lib/ollama"
                    sudo rm -f -- "$ollama_bin"
                    [ -d "$ollama_lib" ] && sudo rm -rf -- "$ollama_lib"
                    ;;
                /bin/ollama)
                    ollama_lib="/lib/ollama"
                    sudo rm -f -- "$ollama_bin"
                    [ -d "$ollama_lib" ] && sudo rm -rf -- "$ollama_lib"
                    ;;
                "")
                    ;;
                *)
                    echo "❌ Refusing to remove unrecognized Ollama binary: $ollama_bin" >&2
                    echo "   Stop succeeded and shared models are untouched, but runtime teardown is incomplete." >&2
                    return 1
                    ;;
            esac
            ;;
    esac
    hash -r
    echo "✅ Ollama runtime removed; shared downloaded models were preserved."
}

echo "🦙 Setting up the shared native Ollama service..."

case "$POLICY" in
    STOP)
        _stop_ollama
        exit 0
        ;;
    TEARDOWN)
        _teardown_ollama
        exit $?
        ;;
    CLEAN)
        echo "🧹 Reinstalling Ollama while preserving the shared model cache..."
        _teardown_ollama || exit 1
        ;;
    FAST) ;;
    *)
        echo "❌ Unsupported Ollama lifecycle policy: $POLICY" >&2
        exit 1
        ;;
esac

if ! command -v "$OLLAMA_CMD" >/dev/null 2>&1; then
    echo "Ollama is not installed on this host."
    if [ "$POLICY" = "CLEAN" ]; then
        _install_ollama || exit 1
    else
        read -rp "Install it now using the official platform method? [y/N]: " answer
        if [[ "$answer" =~ ^[Yy] ]]; then
            _install_ollama || exit 1
        else
            echo "ℹ️  Installation skipped."
            exit 0
        fi
    fi
fi

if _healthy; then
    echo "✅ Ollama is already responsive at $OLLAMA_HOST"
    _report_bind_address
else
    echo "🔄 Starting Ollama..."
    _start_ollama || exit 1
    attempt=0
    while [ "$attempt" -lt 15 ]; do
        _healthy && break
        sleep 1
        attempt=$((attempt + 1))
    done
    if _healthy; then
        echo "✅ Ollama is responsive at $OLLAMA_HOST"
        _report_bind_address
    else
        echo "❌ Ollama did not become responsive at $OLLAMA_HOST." >&2
        echo "   Check the service, then use the Check / Restart Ollama action." >&2
        exit 1
    fi
fi

bash "$REPO_DIR/lib/run-info.sh" "$SCRIPT_DIR" list
