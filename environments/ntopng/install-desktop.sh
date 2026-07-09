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
MENU_NAME="ntopng"
MENU_ICON="network-wired"
DEPLOYED_CHECK_KIND="container"
DEPLOYED_CHECK_VALUE="ntopng"

NTOPNG_PORT=$(env_val "NTOPNG_PORT" "3002")

ENTRY_IDS=(pi-bootstrap-ntopng)
ENTRY_NAMES=("ntopng (Deep Traffic Analysis)")
ENTRY_COMMENTS=("Per-flow traffic analysis, DPI, and historical trends — default login admin/admin")
ENTRY_ICONS=(network-wired)
ENTRY_KINDS=(link)
ENTRY_TARGETS=("http://localhost:$NTOPNG_PORT")

INFO_ID="pi-bootstrap-ntopng-info"
INFO_NAME="ntopng Info"

run_desktop_install "$@"
