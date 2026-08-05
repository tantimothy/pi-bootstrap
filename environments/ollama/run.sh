#!/usr/bin/env bash
#
# Installs and starts one native Ollama daemon shared by every AI environment
# in this repository. Idempotent and safe to re-run.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
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

_start_ollama() {
    case "$(uname -s)" in
        Darwin)
            if command -v brew >/dev/null 2>&1 && brew list ollama >/dev/null 2>&1; then
                brew services start ollama
            elif [ -d "/Applications/Ollama.app" ]; then
                open -a Ollama
            else
                nohup "$OLLAMA_CMD" serve >> "$HOME/.ollama-server.log" 2>&1 &
            fi
            ;;
        Linux)
            if command -v systemctl >/dev/null 2>&1 &&
               systemctl list-unit-files 2>/dev/null | grep -q '^ollama\.service'; then
                sudo systemctl enable --now ollama
            else
                nohup "$OLLAMA_CMD" serve >> "$HOME/.ollama-server.log" 2>&1 &
            fi
            ;;
    esac
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
    else
        echo "❌ Ollama did not become responsive at $OLLAMA_HOST." >&2
        echo "   Check the service, then use the Check / Restart Ollama action." >&2
        exit 1
    fi
fi

bash "$REPO_DIR/lib/run-info.sh" "$SCRIPT_DIR" list
