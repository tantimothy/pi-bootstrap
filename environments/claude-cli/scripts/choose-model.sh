#!/usr/bin/env bash
# Interactive picker for CLAUDE_MODEL (see .env.example) — writes the
# choice to this environment's own .env and restarts the container (FAST)
# so entrypoint.sh re-exports it. Takes effect the next time a base tmux
# session is created (a fresh deploy, or after the restart this script
# itself triggers) — see bashrc-tmux-attach.sh's own comment for why an
# already-running session isn't affected until then.
#
# The model list below is this repo's own understanding of Anthropic's
# current lineup as of this writing — not fetched live from anywhere,
# since there's no "list models" endpoint this script could query without
# an API key already configured. Run `claude --help` inside the container
# (or Anthropic's own docs) for the authoritative, current list if this
# looks stale — model names change over time, and this file isn't kept
# in sync with them automatically.
#
# Usage:
#   ./choose-model.sh              # interactive picker
#   ./choose-model.sh <model-id>   # skip the picker, set directly
#   ./choose-model.sh --clear      # unset CLAUDE_MODEL (Claude Code's own default)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$ENV_DIR/.env"

CHOICE="${1:-}"

if [ -z "$CHOICE" ]; then
    echo "Which model should claude launch with?"
    echo "  1) claude-sonnet-5              (balanced)"
    echo "  2) claude-opus-5                (most capable)"
    echo "  3) claude-haiku-4-5-20251001    (fastest/cheapest)"
    echo "  4) claude-fable-5"
    echo "  5) Custom — type a model ID"
    echo "  6) Clear override — let Claude Code pick its own default"
    read -rp "Number: " NUM
    case "$NUM" in
        1) CHOICE="claude-sonnet-5" ;;
        2) CHOICE="claude-opus-5" ;;
        3) CHOICE="claude-haiku-4-5-20251001" ;;
        4) CHOICE="claude-fable-5" ;;
        5) read -rp "Model ID: " CHOICE ;;
        6) CHOICE="--clear" ;;
        *) echo "❌ Not a valid choice: $NUM" >&2; exit 1 ;;
    esac
fi

touch "$ENV_FILE"
# -i.bak, not bare -i: works identically on GNU sed (Linux) and BSD sed
# (macOS) — see point-to-gateway.sh's own comment for why bare -i doesn't.
sed -i.bak '/^CLAUDE_MODEL=/d' "$ENV_FILE"
rm -f "$ENV_FILE.bak"

if [ "$CHOICE" = "--clear" ]; then
    echo "✅ Cleared — claude will use its own default model."
else
    echo "CLAUDE_MODEL=${CHOICE}" >> "$ENV_FILE"
    echo "✅ Set CLAUDE_MODEL=${CHOICE}"
fi

CONTAINER_NAME=$(grep -E '^CONTAINER_NAME=' "$ENV_FILE" | tail -1 | cut -d= -f2-)
CONTAINER_NAME="${CONTAINER_NAME:-claude-cli}"

echo "🔄 Restarting $CONTAINER_NAME to apply..."
(cd "$ENV_DIR" && docker compose up -d)
echo "✅ Done — reconnect (or open a new SSH session) to launch with the new model."
