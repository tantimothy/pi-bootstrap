#!/usr/bin/env bash
# Opens an interactive `claude` session against this NanoClaw install —
# directly on the host in `host` deploy mode (a native process, no
# container involved at all), or via `docker exec -it` into the
# orchestrator container in `container` mode. Mirrors run.sh's own
# deploy-mode auto-detection exactly (NANOCLAW_DEPLOY_MODE if set in
# .env, else macOS -> container, Linux -> host) rather than guessing
# independently — this needs to agree with whichever mode this install
# was actually deployed in, not just the host's own OS.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$SCRIPT_DIR/.env" ] && { set -a; source "$SCRIPT_DIR/.env"; set +a; }

DEPLOY_MODE="${NANOCLAW_DEPLOY_MODE:-}"
if [ -z "$DEPLOY_MODE" ]; then
    if [[ "$(uname)" == "Darwin" ]]; then DEPLOY_MODE="container"; else DEPLOY_MODE="host"; fi
fi

if [ "$DEPLOY_MODE" = "container" ]; then
    # \$NANOCLAW_INSTALL_PATH is deliberately escaped so it's evaluated by
    # the CONTAINER's own shell once docker exec actually attaches —
    # run.sh passes it in via `-e NANOCLAW_INSTALL_PATH=...`, matching the
    # same "evaluated by the container's own shell" reasoning this
    # environment's own useful_commands already documents.
    exec docker exec -it "${CONTAINER_NAME:-nanoclaw}" bash -lc "cd \$NANOCLAW_INSTALL_PATH && claude"
else
    INSTALL_PATH="${NANOCLAW_INSTALL_PATH:-$HOME/nanoclaw}"
    cd "$INSTALL_PATH"
    exec claude
fi
