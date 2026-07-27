#!/usr/bin/env bash
# Interactive picker for CLAUDE_MODEL (see .env.example) — writes the
# choice to this environment's own .env and restarts the container (FAST)
# so entrypoint.sh re-exports it. Takes effect the next time a base tmux
# session is created (a fresh deploy, or after the restart this script
# itself triggers) — see bashrc-tmux-attach.sh's own comment for why an
# already-running session isn't affected until then.
#
# The model list below — verified against Claude Code's own model
# configuration docs (https://code.claude.com/docs/en/model-config), not
# guessed — mixes the current Anthropic-API lineup (options 1-4) with real,
# still-current pinned versions other providers' `sonnet`/`opus` aliases
# resolve to instead (options 5-7: Claude Platform on AWS resolves `sonnet`
# to 4.6; Microsoft Foundry resolves `opus`/`sonnet` to 4.6/4.5) — not
# fetched live from anywhere, since there's no "list models" endpoint this
# script could query without an API key already configured. Run `claude
# --help` inside the container (or Anthropic's own docs) for the
# authoritative, current list if this looks stale — model names change
# over time, and this file isn't kept in sync with them automatically.
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
    echo "  1) claude-sonnet-5              (balanced, current Anthropic-API default)"
    echo "  2) claude-opus-5                (most capable)"
    echo "  3) claude-haiku-4-5-20251001    (fastest/cheapest)"
    echo "  4) claude-fable-5"
    echo "  5) claude-sonnet-4-6            (what 'sonnet' resolves to on Claude Platform on AWS)"
    echo "  6) claude-opus-4-6              (what 'opus' resolves to on Microsoft Foundry)"
    echo "  7) claude-sonnet-4-5            (what 'sonnet' resolves to on Bedrock/Foundry)"
    echo "  8) Custom — type a model ID"
    echo "  9) Clear override — let Claude Code pick its own default"
    read -rp "Number: " NUM
    case "$NUM" in
        1) CHOICE="claude-sonnet-5" ;;
        2) CHOICE="claude-opus-5" ;;
        3) CHOICE="claude-haiku-4-5-20251001" ;;
        4) CHOICE="claude-fable-5" ;;
        5) CHOICE="claude-sonnet-4-6" ;;
        6) CHOICE="claude-opus-4-6" ;;
        7) CHOICE="claude-sonnet-4-5" ;;
        8) read -rp "Model ID: " CHOICE ;;
        9) CHOICE="--clear" ;;
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
