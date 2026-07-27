#!/usr/bin/env bash
# Picks which model `aider` launches with, writing AIDER_MODEL to this
# environment's own .env and restarting the container (FAST — no rebuild
# needed, same as claude-cli's own choose-model.sh).
#
# Unlike claude-cli, Aider isn't Claude-only — the whole point of pairing
# it with a gateway is provider flexibility (see README's "Choosing a
# Provider"), so the quick picks below cover direct-Anthropic Claude
# models only; anything else (a gateway-routed alias, DeepSeek, a local
# Ollama model) goes through the "Custom" option instead.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$ENV_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "❌ No .env in $ENV_DIR — deploy this environment at least once first." >&2
    exit 1
fi

MODELS=(claude-sonnet-5 claude-opus-5 claude-haiku-4-5-20251001 claude-fable-5)

echo "Which model should \`aider\` launch with?"
echo "  (Quick picks below are direct-Anthropic Claude models — requires ANTHROPIC_API_KEY in .env."
echo "   Routing through llm-gateways/OPENAI_API_BASE instead? Use Custom — see README's 'Choosing a Provider'.)"
for i in "${!MODELS[@]}"; do
    echo "  $((i + 1))) ${MODELS[$i]}"
done
CUSTOM_NUM=$((${#MODELS[@]} + 1))
CLEAR_NUM=$((${#MODELS[@]} + 2))
echo "  ${CUSTOM_NUM}) Custom (type a model name — any Aider/litellm-recognized string)"
echo "  ${CLEAR_NUM}) Clear override (let Aider pick its own default)"
read -rp "Number: " CHOICE

if ! [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
    echo "❌ Not a valid choice: $CHOICE" >&2
    exit 1
elif [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "${#MODELS[@]}" ]; then
    NEW_MODEL="${MODELS[$((CHOICE - 1))]}"
elif [ "$CHOICE" -eq "$CUSTOM_NUM" ]; then
    read -rp "Model name: " NEW_MODEL
    if [ -z "$NEW_MODEL" ]; then
        echo "❌ Empty model name." >&2
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
sed -i.bak '/^AIDER_MODEL=/d; /^#AIDER_MODEL=/d' "$ENV_FILE"
rm -f "$ENV_FILE.bak"
if [ -n "$NEW_MODEL" ]; then
    echo "AIDER_MODEL=$NEW_MODEL" >> "$ENV_FILE"
    echo "✅ AIDER_MODEL set to: $NEW_MODEL"
else
    echo "✅ AIDER_MODEL cleared — Aider will pick its own default."
fi

CONTAINER_NAME=$(grep -E '^CONTAINER_NAME=' "$ENV_FILE" | tail -1 | cut -d= -f2-)
CONTAINER_NAME="${CONTAINER_NAME:-aider}"

echo ""
echo "🔁 Restarting $CONTAINER_NAME so it picks up the new environment..."
(cd "$ENV_DIR" && docker compose up -d)

echo ""
echo "✅ Done. The restart ended any live tmux session — SSH back in"
echo "   (ssh -p \${SSH_PORT:-2223} aider@<host>) and it starts a fresh"
echo "   \`aider\` session against the new model."
