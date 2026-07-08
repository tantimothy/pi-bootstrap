#!/usr/bin/env bash
# NanoClaw desktop entries:
#   NanoClaw AI   — launches the environment in a terminal emulator
#   NanoClaw Info — opens the generated post-deploy-info.html

set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="${APPS_DIR:-${HOME}/.local/share/applications}"
REPO_DIR="${REPO_DIR:-$(cd "$ENV_DIR/../.." && pwd)}"
source "$REPO_DIR/lib/desktop-lib.sh"

MENU_ID="nanoclaw"
CATEGORY="X-PiBootstrap-${MENU_ID};"

ENTRIES=(pi-bootstrap-nanoclaw pi-bootstrap-nanoclaw-info)

if [ "${1:-}" = "--uninstall" ]; then
    for e in "${ENTRIES[@]}"; do rm -f "$APPS_DIR/${e}.desktop"; remove_desktop_icon "$e"; done
    remove_submenu "$MENU_ID"
    exit 0
fi

mkdir -p "$APPS_DIR"

# Only install entries if the nanoclaw service has been registered.
# If it hasn't (or was unregistered since), clean up any stale entries too.
if ! systemctl list-unit-files "nanoclaw.service" --no-legend 2>/dev/null | grep -q "nanoclaw"; then
    for e in "${ENTRIES[@]}"; do rm -f "$APPS_DIR/${e}.desktop"; remove_desktop_icon "$e"; done
    remove_submenu "$MENU_ID"
    echo "  ⚠  nanoclaw: service 'nanoclaw.service' not found — skipping (deploy the environment first)"
    exit 0
fi
echo "  nanoclaw: deployed ✓"
register_submenu "$MENU_ID" "NanoClaw" "utilities-terminal"

cat > "$APPS_DIR/pi-bootstrap-nanoclaw.desktop" << EOF
[Desktop Entry]
Name=NanoClaw AI
Comment=Local AI tools — Ollama model inference, Whisper speech-to-text, Claude
Exec=bash -c "cd '$ENV_DIR' && REBUILD_POLICY=FAST ./run.sh"
Icon=utilities-terminal
Type=Application
Categories=${CATEGORY}
Terminal=true
EOF
install_desktop_icon "pi-bootstrap-nanoclaw"
echo "  ✓  NanoClaw AI"

# Ensure post-deploy-info.html exists even if INFO has never been opened
# from the menu yet (this is a cheap, idempotent safety net).
bash "$ENV_DIR/info.sh" list >/dev/null 2>&1 || true
install_info_icon "pi-bootstrap-nanoclaw-info" "NanoClaw Info" "$ENV_DIR/post-deploy-info.html" "$CATEGORY"
echo "  ✓  Info page (NanoClaw)"
