#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$ENV_DIR/.env"
CHOICE="${1:-}"

if [ -z "$CHOICE" ]; then
    echo "Enter a Codex model ID, or leave blank to clear the override."
    echo "Use /model inside Codex to see models currently available to your account."
    read -rp "Model ID: " CHOICE
fi

touch "$ENV_FILE"
sed -i.bak '/^CODEX_MODEL=/d' "$ENV_FILE"
rm -f "$ENV_FILE.bak"

if [ -n "$CHOICE" ] && [ "$CHOICE" != "--clear" ]; then
    printf 'CODEX_MODEL=%s\n' "$CHOICE" >> "$ENV_FILE"
    echo "✅ Set CODEX_MODEL=$CHOICE"
else
    echo "✅ Cleared CODEX_MODEL; Codex will use its default."
fi

echo "🔄 Restarting the container to apply the next base-session launch..."
(cd "$ENV_DIR" && docker compose up -d)
