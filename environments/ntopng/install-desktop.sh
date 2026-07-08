#!/usr/bin/env bash
# ntopng desktop entries:
#   ntopng      — opens browser to the deep traffic analysis UI
#   ntopng Info — opens the generated post-deploy-info.html

set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="${APPS_DIR:-${HOME}/.local/share/applications}"
REPO_DIR="${REPO_DIR:-$(cd "$ENV_DIR/../.." && pwd)}"
source "$REPO_DIR/lib/desktop-lib.sh"

MENU_ID="ntopng"
CATEGORY="X-PiBootstrap-${MENU_ID};"

ENTRIES=(
    pi-bootstrap-ntopng
    pi-bootstrap-ntopng-info
)

if [ "${1:-}" = "--uninstall" ]; then
    for e in "${ENTRIES[@]}"; do rm -f "$APPS_DIR/${e}.desktop"; remove_desktop_icon "$e"; done
    remove_submenu "$MENU_ID"
    exit 0
fi

mkdir -p "$APPS_DIR"

# Only install entries if the environment has been deployed.
# If it isn't (or was deployed before and has since been torn down), remove
# any stale entries so the menu doesn't accumulate broken shortcuts.
if ! docker ps -a --filter "name=^/ntopng$" -q 2>/dev/null | grep -q .; then
    for e in "${ENTRIES[@]}"; do rm -f "$APPS_DIR/${e}.desktop"; remove_desktop_icon "$e"; done
    remove_submenu "$MENU_ID"
    echo "  ⚠  ntopng: container 'ntopng' not found — skipping (deploy the environment first)"
    exit 0
fi
echo "  ntopng: deployed ✓"

register_submenu "$MENU_ID" "ntopng" "network-wired"

# Read a value from .env with a fallback default
env_val() {
    local key="$1" default="$2"
    local val
    val=$(grep "^${key}=" "$ENV_DIR/.env" 2>/dev/null | cut -d= -f2 | tr -d "\"'" | head -1)
    echo "${val:-$default}"
}

NTOPNG_PORT=$(env_val "NTOPNG_PORT" "3002")

install_link_icon "pi-bootstrap-ntopng" "ntopng (Deep Traffic Analysis)" \
    "Per-flow traffic analysis, DPI, and historical trends — default login admin/admin" \
    "http://localhost:$NTOPNG_PORT" "network-wired" "$CATEGORY"
echo "  ✓  ntopng          (http://localhost:$NTOPNG_PORT)"

# Ensure post-deploy-info.html exists even if INFO has never been opened
# from the menu yet (run.sh already generates it right after deploy, but
# this is a cheap, idempotent safety net either way).
bash "$ENV_DIR/info.sh" list >/dev/null 2>&1 || true
install_info_icon "pi-bootstrap-ntopng-info" "ntopng Info" "$ENV_DIR/post-deploy-info.html" "$CATEGORY"
echo "  ✓  Info page       (post-deploy-info.html)"
