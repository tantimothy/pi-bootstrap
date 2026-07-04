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

# Only install entries if the nanoclaw service has been registered.
# If it hasn't (or was unregistered since), clean up any stale entries too.
if ! systemctl list-unit-files "nanoclaw.service" --no-legend 2>/dev/null | grep -q "nanoclaw"; then
    for e in "${ENTRIES[@]}"; do rm -f "$APPS_DIR/${e}.desktop"; done
    echo "  ⚠  nanoclaw: service 'nanoclaw.service' not found — skipping (deploy the environment first)"
    exit 0
fi
echo "  nanoclaw: deployed ✓"

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
