#!/usr/bin/env bash
# NanoClaw desktop entry:
#   NanoClaw AI — launches the environment in a terminal emulator

set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="${APPS_DIR:-${HOME}/.local/share/applications}"

ENTRIES=(pi-bootstrap-nanoclaw)

if [ "${1:-}" = "--uninstall" ]; then
    for e in "${ENTRIES[@]}"; do rm -f "$APPS_DIR/${e}.desktop"; done
    exit 0
fi

mkdir -p "$APPS_DIR"

cat > "$APPS_DIR/pi-bootstrap-nanoclaw.desktop" << EOF
[Desktop Entry]
Name=NanoClaw AI
Comment=Local AI tools — Ollama model inference, Whisper speech-to-text, Claude
Exec=bash -c "cd '$ENV_DIR' && REBUILD_POLICY=FAST ./run.sh"
Icon=utilities-terminal
Type=Application
Categories=Science;
Terminal=true
EOF
echo "  ✓  NanoClaw AI"
