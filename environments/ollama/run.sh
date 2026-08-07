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
source "$REPO_DIR/lib/ollama-lib.sh"

_healthy() { ollama_healthy "$OLLAMA_HOST"; }

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

# Install/start/stop/probe all live in lib/ollama-lib.sh so this environment,
# nanoclaw-mnemon's ensure_ollama_ready(), and ollama-watchdog.sh cannot start
# the one native daemon differently — or twice. ollama_start() is a no-op when
# Ollama already answers, which is the guard against a second process.
_start_ollama() { ollama_start "$OLLAMA_HOST"; }

_report_bind_address() { ollama_report_binding; }

_stop_ollama() { ollama_stop; }

_teardown_ollama() {
    local ollama_bin=""
    local ollama_lib=""

    _stop_ollama
    case "$(uname -s)" in
        Darwin)
            # Four recognized macOS install methods, not two. The original pair
            # (brew formula, /Applications/Ollama.app) missed both a Homebrew
            # *cask* install and a plain binary dropped on PATH — and a real
            # host running the latter had its CLEAN abort outright, since the
            # unrecognized branch returned 1 straight into `|| exit 1`.
            if command -v brew >/dev/null 2>&1 && brew list --formula ollama >/dev/null 2>&1; then
                brew uninstall --formula ollama
            elif command -v brew >/dev/null 2>&1 && brew list --cask ollama >/dev/null 2>&1; then
                brew uninstall --cask ollama
            elif [ -d "/Applications/Ollama.app" ]; then
                sudo rm -rf -- "/Applications/Ollama.app"
                [ -L "/usr/local/bin/ollama" ] && sudo rm -f -- "/usr/local/bin/ollama"
            else
                # A bare binary, wherever it landed. Same allow-list approach as
                # the Linux branch below — remove only paths we recognize, never
                # whatever `command -v` happens to resolve to.
                ollama_bin="${OLLAMA_TEARDOWN_BIN:-$(command -v ollama 2>/dev/null || true)}"
                case "$ollama_bin" in
                    /usr/local/bin/ollama|/opt/homebrew/bin/ollama)
                        sudo rm -f -- "$ollama_bin"
                        ;;
                    *)
                        # Stopped, but not removed. Deliberately NOT a hard
                        # failure: CLEAN can still reinstall over the top and
                        # start the daemon correctly, which is what the operator
                        # actually wants, and refusing to continue leaves them
                        # with no path forward at all. TEARDOWN does treat this
                        # as a failure — see the policy dispatch below — because
                        # there "remove it" was the entire request.
                        echo "⚠️  Ollama's install method is not recognized, so the runtime was stopped but not removed." >&2
                        if [ -n "$ollama_bin" ]; then
                            echo "   Found the binary at: $ollama_bin" >&2
                            echo "   Recognized locations are /usr/local/bin/ollama and /opt/homebrew/bin/ollama," >&2
                            echo "   a Homebrew formula or cask, or /Applications/Ollama.app." >&2
                        else
                            echo "   No 'ollama' binary is on PATH at all." >&2
                        fi
                        echo "   The shared model cache is untouched either way." >&2
                        return 2
                        ;;
                esac
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

# Hold the maintenance lock for the whole deploy: STOP/TEARDOWN/CLEAN all stop
# the daemon deliberately, and a scheduled watchdog tick would otherwise see an
# unhealthy Ollama and restart it mid-teardown. Released on every exit path,
# including failure — a lock left behind would mute the watchdog, and the trap
# is what stops the abandoned-lock timeout from ever being load-bearing.
ollama_begin_maintenance "deploy:${POLICY}"
trap ollama_end_maintenance EXIT INT TERM

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
        # Exit 2 means "stopped, but the runtime could not be removed because
        # the install method isn't recognized". That is not a reason to abort a
        # CLEAN: the reinstall and the start below still run, and the operator
        # ends up with a correctly-bound daemon, which is the point. Only a
        # genuine teardown error (1) stops the deploy.
        _teardown_ollama
        _teardown_rc=$?
        if [ "$_teardown_rc" -eq 1 ]; then
            exit 1
        elif [ "$_teardown_rc" -eq 2 ]; then
            echo "   Continuing anyway — CLEAN will reinstall over the existing runtime and restart it." >&2
        fi
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
