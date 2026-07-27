#!/usr/bin/env bash
# Picks which Claude model this environment's own admin `claude` session
# ("Open a Claude Session" in the deploy.sh menu — see claude-tmux.sh)
# launches with, writing CLAUDE_MODEL to this environment's own .env and
# recreating the orchestrator container so it picks it up.
#
# Does NOT affect per-conversation-group agent containers — those are
# NanoClaw's own separate concern (see the README's "Can NanoClaw Itself
# Talk to Ollama?" section for how a group's own model gets set via its
# `.claude-shared/settings.json`).
#
# Recreates rather than restarts: a `docker run -e` value only takes effect
# at container creation, not a plain `docker restart` — see run.sh's own
# `docker run` call for where CLAUDE_MODEL is passed in.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$ENV_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "❌ No .env in $ENV_DIR — deploy this environment at least once first." >&2
    exit 1
fi

# Current lineup on the Anthropic API, plus real, still-current pinned
# versions other providers' `sonnet`/`opus` aliases resolve to instead
# (Claude Platform on AWS: Sonnet 4.6; Microsoft Foundry: Opus 4.6/Sonnet
# 4.5) — verified against Claude Code's own model configuration docs
# (https://code.claude.com/docs/en/model-config), not guessed either way.
MODELS=(claude-sonnet-5 claude-opus-5 claude-haiku-4-5-20251001 claude-fable-5 claude-sonnet-4-6 claude-opus-4-6 claude-sonnet-4-5)

echo "Which Claude model should \`claude\` launch with in this container's admin session?"
for i in "${!MODELS[@]}"; do
    echo "  $((i + 1))) ${MODELS[$i]}"
done
CUSTOM_NUM=$((${#MODELS[@]} + 1))
CLEAR_NUM=$((${#MODELS[@]} + 2))
echo "  ${CUSTOM_NUM}) Custom (type a model ID)"
echo "  ${CLEAR_NUM}) Clear override (let Claude Code pick its own default)"
read -rp "Number: " CHOICE

if ! [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
    echo "❌ Not a valid choice: $CHOICE" >&2
    exit 1
elif [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "${#MODELS[@]}" ]; then
    NEW_MODEL="${MODELS[$((CHOICE - 1))]}"
elif [ "$CHOICE" -eq "$CUSTOM_NUM" ]; then
    read -rp "Model ID: " NEW_MODEL
    if [ -z "$NEW_MODEL" ]; then
        echo "❌ Empty model ID." >&2
        exit 1
    fi
elif [ "$CHOICE" -eq "$CLEAR_NUM" ]; then
    NEW_MODEL=""
else
    echo "❌ Not a valid choice: $CHOICE" >&2
    exit 1
fi

# -i.bak, not bare -i: works identically on GNU sed (Linux) and BSD sed
# (macOS) — see claude-cli's point-to-gateway.sh for the fuller writeup.
sed -i.bak '/^CLAUDE_MODEL=/d; /^#CLAUDE_MODEL=/d' "$ENV_FILE"
rm -f "$ENV_FILE.bak"
if [ -n "$NEW_MODEL" ]; then
    echo "CLAUDE_MODEL=$NEW_MODEL" >> "$ENV_FILE"
    echo "✅ CLAUDE_MODEL set to: $NEW_MODEL"
else
    echo "✅ CLAUDE_MODEL cleared — Claude Code will pick its own default."
fi

CONTAINER_NAME=$(grep -E '^CONTAINER_NAME=' "$ENV_FILE" | tail -1 | cut -d= -f2-)
CONTAINER_NAME="${CONTAINER_NAME:-nanoclaw-mnemon}"

echo ""
echo "🔁 Recreating $CONTAINER_NAME so it picks up the new environment..."
echo "   (docker run -e only takes effect at container creation — a plain restart isn't enough)"
DOCKER="${DOCKER_CMD:-docker}"
"$DOCKER" stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
"$DOCKER" rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
bash "$ENV_DIR/run.sh"

echo ""
echo "✅ Done. Any live tmux \"claude\" session inside the old container is gone —"
echo "   use \"Open a Claude Session\" again and it starts fresh with --continue"
echo "   against the new model."
