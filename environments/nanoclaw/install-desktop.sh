#!/usr/bin/env bash
# NanoClaw desktop entries — data lives in desktop-entries.yaml, deploy-mode
# branching lives here (the one piece that isn't static data):
#   NanoClaw AI   — launches the environment in a terminal emulator
#   NanoClaw Info — opens the generated post-deploy-info.html

set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="${APPS_DIR:-${HOME}/.local/share/applications}"
REPO_DIR="${REPO_DIR:-$(cd "$ENV_DIR/../.." && pwd)}"
source "$REPO_DIR/lib/desktop-lib.sh"

_load_desktop_entries_yaml "$ENV_DIR"

# Deployed-check depends on which deploy mode is actually configured —
# mirrors run.sh's own OS-based default + .env override, since there's no
# systemd unit at all in container mode (and no "nanoclaw" container in
# host mode either). .env was already sourced by _load_desktop_entries_yaml
# above, so NANOCLAW_DEPLOY_MODE/CONTAINER_NAME are real variables here if set.
if [ -z "${NANOCLAW_DEPLOY_MODE:-}" ]; then
    if [[ "$(uname)" == "Darwin" ]]; then NANOCLAW_DEPLOY_MODE="container"; else NANOCLAW_DEPLOY_MODE="host"; fi
fi

if [ "$NANOCLAW_DEPLOY_MODE" = "container" ]; then
    DEPLOYED_CHECK_KIND="container"
    # Mirrors run.sh's own CONTAINER_NAME override (defaults to "nanoclaw"
    # if unset in .env) — hardcoding this independently would silently
    # break the deployed-check for anyone who's actually customized it.
    DEPLOYED_CHECK_VALUE="${CONTAINER_NAME:-nanoclaw}"
else
    DEPLOYED_CHECK_KIND="systemd"
    DEPLOYED_CHECK_VALUE="nanoclaw.service"
fi

run_desktop_install "$@"
