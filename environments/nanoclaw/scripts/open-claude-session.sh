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
    # /root, not $NANOCLAW_INSTALL_PATH — same reasoning confirmed directly
    # against nanoclaw-mnemon's own container (see that environment's
    # lessons-learned entry): this image runs as root with no explicit
    # WORKDIR, so a plain, unwrapped `docker exec -it nanoclaw bash` lands
    # at /root by default, and Claude Code's own conversation continuity
    # is scoped to the exact launch directory, not the container as a
    # whole. If an admin claude session here was ever started that way
    # before this menu action existed, its real history lives at /root —
    # landing anywhere else would start a second, parallel conversation
    # instead of resuming it.
    exec docker exec -it "${CONTAINER_NAME:-nanoclaw}" bash -lc "cd /root && claude"
else
    INSTALL_PATH="${NANOCLAW_INSTALL_PATH:-$HOME/nanoclaw}"
    cd "$INSTALL_PATH"
    exec claude
fi
