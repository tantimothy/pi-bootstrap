#!/usr/bin/env bash
# Backs "Open a Claude Session (most recent agent container)" — info.yaml's
# custom_actions.
#
# Unlike the other two session actions, this does NOT attach to the
# orchestrator. It attaches to one of the per-conversation-group AGENT
# sandbox containers NanoClaw spawns — a different container, a different
# image, and the place where the things people actually debug live:
# whisper-cli, yt-dlp, mnemon's own data, the Ollama MCP tool, and the
# baked ENVs that decide whether any of them work.
#
# That distinction is the reason this exists. Every "is it broken?" question
# in this environment's history has eventually come down to checking inside a
# live agent container, and doing that by hand means finding the container
# name, remembering the mount-scope caveat, and typing a long `docker exec`.
#
# Runs on the HOST (not inside the orchestrator), because picking the target
# container needs the host's Docker socket and `docker ps` output.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
[ -f "$ENV_DIR/.env" ] && { set -a; source "$ENV_DIR/.env"; set +a; }

DOCKER="${DOCKER_CMD:-docker}"
INSTALL_PATH="${NANOCLAW_INSTALL_PATH:-$HOME/nanoclaw-mnemon}"

# Same two-identifier match and same bind-mount scoping as run.sh's own
# sweep_agent_container_ids(): match on the container NAME as well as the
# image (a per-agent image tag can stop resolving, at which point
# `docker ps --format '{{.Image}}'` degrades to a bare sha256), then keep
# only containers whose mounts trace back to THIS install — so a second
# NanoClaw on the same host is never picked by mistake.
#
# Sorted newest-first by creation, and only RUNNING containers: an exited
# agent container is not something you can open a session in.
_candidates() {
    local line id name created mounts
    while IFS='|' read -r id name created; do
        [ -z "$id" ] && continue
        mounts=$($DOCKER inspect "$id" --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' 2>/dev/null)
        if echo "$mounts" | grep -qF "$INSTALL_PATH"; then
            printf '%s|%s|%s\n' "$id" "$name" "$created"
        fi
    done < <($DOCKER ps --format '{{.ID}}|{{.Names}}|{{.CreatedAt}}' 2>/dev/null \
        | awk -F'|' '$2 ~ /^nanoclaw-v2-/ || $0 ~ /nanoclaw-agent-v2-/ {print}')
}

mapfile_free_candidates=$(_candidates)

if [ -z "$mapfile_free_candidates" ]; then
    echo "ℹ️  No running agent container for this install right now." >&2
    echo "" >&2
    echo "   That is usually NORMAL, not a fault: NanoClaw spawns an agent container" >&2
    echo "   when a message arrives for a group and reaps it when idle. Send a message" >&2
    echo "   on a paired channel and try again." >&2
    echo "" >&2
    echo "   It is only a problem if a channel is unresponsive AND the orchestrator log" >&2
    echo "   shows 'Spawning container' repeating every 60s — that means the group's" >&2
    echo "   image is missing and every spawn is failing silently. Check with:" >&2
    echo "     docker logs ${CONTAINER_NAME:-nanoclaw-mnemon} 2>&1 | tail -40" >&2
    exit 1
fi

# Newest by creation time. `docker ps` already lists newest-first, so the
# first surviving candidate is the most recent one.
TARGET_ID="$(printf '%s\n' "$mapfile_free_candidates" | head -1 | cut -d'|' -f1)"
TARGET_NAME="$(printf '%s\n' "$mapfile_free_candidates" | head -1 | cut -d'|' -f2)"
TARGET_CREATED="$(printf '%s\n' "$mapfile_free_candidates" | head -1 | cut -d'|' -f3)"
TARGET_IMAGE="$($DOCKER inspect "$TARGET_ID" --format '{{.Config.Image}}' 2>/dev/null)"

echo "🤖 Opening a session in agent container:"
echo "     name:    $TARGET_NAME"
echo "     image:   ${TARGET_IMAGE:-<unresolvable>}"
echo "     started: $TARGET_CREATED"

# .Config.Image is the reference recorded at creation, which survives the tag
# being collected — unlike `docker ps`'s resolved-at-query-time column. Worth
# printing because "which image is this agent actually running" is the first
# question in almost every investigation here, and a group with custom packages
# runs a DERIVED image rather than the base.
case "$TARGET_IMAGE" in
    *:latest) ;;
    *) echo "     note:    this is a per-group DERIVED image, not the :latest base." ;;
esac
echo ""

# Agent containers are not the orchestrator: no guarantee tmux exists, and no
# guarantee the `claude` CLI does either (they run the Agent SDK via bun, which
# is not the same thing). Probe rather than assume, and say plainly what you
# are getting — a bare shell in the right container is still far more useful
# than a failed command.
if $DOCKER exec "$TARGET_ID" sh -c 'command -v claude' >/dev/null 2>&1; then
    if $DOCKER exec "$TARGET_ID" sh -c 'command -v tmux' >/dev/null 2>&1; then
        MODEL_ARGS=""
        [ -n "${CLAUDE_MODEL:-}" ] && MODEL_ARGS="--model $CLAUDE_MODEL"
        exec $DOCKER exec -it "$TARGET_ID" sh -c \
            "cd /workspace/agent 2>/dev/null || cd /workspace/group 2>/dev/null || cd /; \
             tmux has-session -t claude-agent 2>/dev/null \
               && tmux new-session -t claude-agent -s 'client_\$\$' \; set-option destroy-unattached on \
               || tmux new-session -s claude-agent sh -c 'claude --continue ${MODEL_ARGS} || claude ${MODEL_ARGS}'"
    fi
    echo "ℹ️  No tmux in this image — launching claude directly (not detachable)."
    exec $DOCKER exec -it "$TARGET_ID" sh -c \
        "cd /workspace/agent 2>/dev/null || cd /workspace/group 2>/dev/null || cd /; claude"
fi

echo "ℹ️  No 'claude' CLI in this agent image — opening a shell instead." >&2
echo "   Agent containers run NanoClaw's Agent SDK via bun, which does not imply the" >&2
echo "   claude CLI is installed. A shell is still what you want for checking" >&2
echo "   whisper-cli, mnemon, yt-dlp, or the baked environment:" >&2
echo "     ldd \$(command -v whisper-cli)        # static build?" >&2
echo "     mnemon embed --status                # insight counts are only real HERE" >&2
echo "     env | grep -i -E 'proxy|ollama|mnemon'" >&2
echo "" >&2
exec $DOCKER exec -it "$TARGET_ID" sh -c \
    "cd /workspace/agent 2>/dev/null || cd /workspace/group 2>/dev/null || cd /; exec bash 2>/dev/null || exec sh"
