#!/usr/bin/env bash
#
# Installs and starts one native Ollama daemon shared by every AI environment
# in this repository. Idempotent and safe to re-run.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"

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
                nohup ollama serve >> "$HOME/.ollama-server.log" 2>&1 &
            fi
            ;;
        Linux)
            if command -v systemctl >/dev/null 2>&1 &&
               systemctl list-unit-files 2>/dev/null | grep -q '^ollama\.service'; then
                sudo systemctl enable --now ollama
            else
                nohup ollama serve >> "$HOME/.ollama-server.log" 2>&1 &
            fi
            ;;
    esac
}

echo "🦙 Setting up the shared native Ollama service..."

if ! command -v ollama >/dev/null 2>&1; then
    echo "Ollama is not installed on this host."
    read -rp "Install it now using the official platform method? [y/N]: " answer
    if [[ "$answer" =~ ^[Yy] ]]; then
        _install_ollama || exit 1
    else
        echo "ℹ️  Installation skipped."
        exit 0
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
