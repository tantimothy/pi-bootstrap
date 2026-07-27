#!/usr/bin/env bash
# Opens an interactive `claude` session against this NanoClaw install —
# directly on the host in `host` deploy mode (a native process, no
# container involved at all), or via `docker exec -it` into the
# orchestrator container in `container` mode. Mirrors run.sh's own
# deploy-mode auto-detection exactly (NANOCLAW_DEPLOY_MODE if set in
# .env, else macOS -> container, Linux -> host) rather than guessing
# independently — this needs to agree with whichever mode this install
# was actually deployed in, not just the host's own OS.
#
# Both branches land you in a persistent, detachable tmux "claude" session
# where possible — same grouped-session pattern as the standalone
# claude-cli environment's own bashrc-tmux-attach.sh (see that file's own
# comment for the full explanation of why grouped, not `-A` attach-or-
# create): the first connection ever (or the first since the session's
# host process/container last restarted) creates the base "claude" session
# running `claude --continue`; every connection after that groups a new,
# independent window onto it instead of forcing every simultaneous
# connection to watch the same window.
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
    #
    # nanoclaw-claude-tmux.sh (baked into the image — see this
    # environment's own scripts/claude-tmux.sh, identical to
    # nanoclaw-mnemon's copy) does the actual grouped-session tmux
    # attach/create; CLAUDE_MODEL, if set in .env, is already in the
    # container's own environment (set via `docker run -e` in run.sh) so
    # `docker exec` inherits it with no extra passthrough needed here.
    exec docker exec -it "${CONTAINER_NAME:-nanoclaw}" bash -lc "cd /root && nanoclaw-claude-tmux.sh"
else
    INSTALL_PATH="${NANOCLAW_INSTALL_PATH:-$HOME/nanoclaw}"
    cd "$INSTALL_PATH"
    # host mode runs directly on the host OS, which may or may not have
    # tmux installed (unlike container mode's own Dockerfile, which always
    # installs it) — macOS in particular doesn't ship tmux by default.
    # Fall back to a plain, non-tmux `claude` launch if it's missing rather
    # than failing outright; the grouped-session/multi-window behavior
    # just isn't available without it.
    if command -v tmux >/dev/null 2>&1; then
        MODEL_ARGS=""
        [ -n "${CLAUDE_MODEL:-}" ] && MODEL_ARGS="--model $CLAUDE_MODEL"
        # Gated on an explicit `has-session` check, not on whether the
        # group-join attempt itself fails — see nanoclaw-mnemon's
        # scripts/claude-tmux.sh for why: `-t claude` silently creates the
        # group if it's missing rather than erroring, so relying on that
        # command's own exit status never actually detected "first time
        # ever" and left a plain shell (no `claude`) as the base session.
        if tmux has-session -t claude 2>/dev/null; then
            exec tmux new-session -t claude -s "client_$$" \; set-option destroy-unattached on
        else
            # `claude --continue` exits outright ("No conversation found to
            # continue") rather than falling back to a fresh conversation
            # itself, when there's genuinely nothing to resume yet (e.g.
            # the very first time this admin session is ever opened) —
            # confirmed directly against the container-mode equivalent (see
            # nanoclaw-mnemon's scripts/claude-tmux.sh): the whole tmux
            # window/session closed the instant that happened. `--continue`
            # is still tried first, since host mode's `~/.claude` is a
            # plain, persistent host directory — most launches after the
            # first genuinely do have a conversation to resume.
            exec tmux new-session -s claude -c "$INSTALL_PATH" sh -c "claude --continue $MODEL_ARGS || claude $MODEL_ARGS"
        fi
    elif [ -n "${CLAUDE_MODEL:-}" ]; then
        exec claude --model "$CLAUDE_MODEL"
    else
        exec claude
    fi
fi
