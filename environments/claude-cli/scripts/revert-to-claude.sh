#!/usr/bin/env bash
# Reverts point-to-gateway.sh: removes ANTHROPIC_BASE_URL/ANTHROPIC_AUTH_TOKEN
# from this environment's own .env and restarts the container (`docker
# compose up -d`, the same command deploy.sh's FAST policy already runs)
# so `claude` falls back to api.anthropic.com — using the OAuth session
# already stored under ~/.claude (the persistent claude_cli_home volume)
# from your original /login. That session and the env-var override are
# separate auth paths (see entrypoint.sh's own comment), so removing the
# override doesn't sign you out.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$ENV_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "❌ No .env in $ENV_DIR — nothing to revert." >&2
    exit 1
fi

if ! grep -qE '^ANTHROPIC_BASE_URL=.' "$ENV_FILE" 2>/dev/null; then
    echo "ℹ️  ANTHROPIC_BASE_URL isn't set in .env — Claude CLI is already pointed at api.anthropic.com. Nothing to do."
    exit 0
fi

sed -i '/^ANTHROPIC_BASE_URL=/d; /^ANTHROPIC_AUTH_TOKEN=/d' "$ENV_FILE"

CONTAINER_NAME=$(grep -E '^CONTAINER_NAME=' "$ENV_FILE" | tail -1 | cut -d= -f2-)
CONTAINER_NAME="${CONTAINER_NAME:-claude-cli}"

echo "↩️  Reverting Claude CLI to api.anthropic.com"
echo ""
echo "🔁 Restarting $CONTAINER_NAME so it drops the gateway override..."
(cd "$ENV_DIR" && docker compose up -d)

echo ""
echo "✅ Done. The restart ended any live tmux session — SSH back in"
echo "   (ssh -p \${SSH_PORT:-2222} claude@<host>) and it reattaches"
echo "   automatically, resuming your conversation (--continue) against"
echo "   api.anthropic.com again. Verify inside that session:"
echo "   echo \$ANTHROPIC_BASE_URL   # should print nothing"
