#!/usr/bin/env bash
# Redirects this claude-cli container's own `claude` process at a
# self-hosted gateway (this repo's own llm-gateways environment, or any
# other Anthropic-Messages-API-compatible endpoint) instead of
# api.anthropic.com — by writing ANTHROPIC_BASE_URL/ANTHROPIC_AUTH_TOKEN
# into this environment's own .env and restarting the container (`docker
# compose up -d`, the same command deploy.sh's FAST policy already runs)
# so entrypoint.sh re-exports them into every future login shell (see
# that file's own comment for exactly where they land: /etc/environment,
# the same mechanism GH_TOKEN already uses).
#
# Parameters come from .env.gateway.<name>, NOT this environment's main
# .env — see .env.gateway.litellm / .env.gateway.portkey for what each
# one expects filled in, and the README's "Pointing Claude CLI at a
# Gateway" section for the full picture, including what
# ANTHROPIC_BASE_URL actually needs to point at and why this hasn't been
# independently verified against a live gateway from inside this repo.
#
# Usage:
#   ./point-to-gateway.sh              # prompts with a picker over
#                                       # whichever .env.gateway.* files
#                                       # actually exist in this directory
#   ./point-to-gateway.sh litellm      # skip the picker, target one
#   ./point-to-gateway.sh portkey      # directly (matches the .env.gateway.<name> suffix)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$ENV_DIR/.env"

GATEWAY="${1:-}"
if [ -z "$GATEWAY" ]; then
    NAMES=()
    while IFS= read -r f; do
        NAMES+=("$(basename "$f" | sed 's/^\.env\.gateway\.//')")
    # .env.gateway.example is the generic, secrets-free template for
    # adding a new gateway (see that file's own comment) — never a real,
    # selectable target itself, so it's excluded here the same way
    # .env.example is never treated as a real .env anywhere in this repo.
    done < <(ls "$ENV_DIR"/.env.gateway.* 2>/dev/null | grep -v '/\.env\.gateway\.example$' | sort)

    if [ "${#NAMES[@]}" -eq 0 ]; then
        echo "❌ No .env.gateway.* files found in $ENV_DIR" >&2
        exit 1
    elif [ "${#NAMES[@]}" -eq 1 ]; then
        GATEWAY="${NAMES[0]}"
        echo "Only one gateway configured — using it: $GATEWAY"
    else
        echo "Which gateway?"
        for i in "${!NAMES[@]}"; do
            echo "  $((i + 1))) ${NAMES[$i]}"
        done
        read -rp "Number: " CHOICE
        if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "${#NAMES[@]}" ]; then
            echo "❌ Not a valid choice: $CHOICE" >&2
            exit 1
        fi
        GATEWAY="${NAMES[$((CHOICE - 1))]}"
    fi
fi

GATEWAY_FILE="$ENV_DIR/.env.gateway.$GATEWAY"
if [ ! -f "$GATEWAY_FILE" ]; then
    echo "❌ No such gateway file: $GATEWAY_FILE" >&2
    echo "   Available:" >&2
    ls "$ENV_DIR"/.env.gateway.* 2>/dev/null | sed 's/^/    /' >&2
    exit 1
fi

# Pulling exactly these two keys out of the gateway file rather than
# sourcing it outright — a gateway file is meant to hold only these two,
# but there's no reason to eval arbitrary shell out of it either.
NEW_BASE_URL=$(grep -E '^ANTHROPIC_BASE_URL=' "$GATEWAY_FILE" | tail -1 | cut -d= -f2-)
NEW_AUTH_TOKEN=$(grep -E '^ANTHROPIC_AUTH_TOKEN=' "$GATEWAY_FILE" | tail -1 | cut -d= -f2-)

if [ -z "$NEW_BASE_URL" ]; then
    echo "❌ ANTHROPIC_BASE_URL is empty in $GATEWAY_FILE — fill it in first." >&2
    exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
    echo "❌ No .env in $ENV_DIR — deploy claude-cli at least once first (cp .env.example .env)." >&2
    exit 1
fi

# Strip any prior ANTHROPIC_BASE_URL/ANTHROPIC_AUTH_TOKEN lines (from an
# earlier point-to-gateway.sh run against a different gateway, or a stray
# manual edit) before appending the new ones — same idempotent
# strip-then-append pattern used elsewhere in this repo (e.g.
# nanoclaw-mnemon's apply_mnemon_patch) rather than leaving duplicate
# lines for docker compose to pick an unpredictable one of.
sed -i '/^ANTHROPIC_BASE_URL=/d; /^ANTHROPIC_AUTH_TOKEN=/d' "$ENV_FILE"
{
    echo "ANTHROPIC_BASE_URL=$NEW_BASE_URL"
    echo "ANTHROPIC_AUTH_TOKEN=$NEW_AUTH_TOKEN"
} >> "$ENV_FILE"

echo "🔀 Pointing Claude CLI at: $GATEWAY"
echo "   ANTHROPIC_BASE_URL=$NEW_BASE_URL"
echo ""

CONTAINER_NAME=$(grep -E '^CONTAINER_NAME=' "$ENV_FILE" | tail -1 | cut -d= -f2-)
CONTAINER_NAME="${CONTAINER_NAME:-claude-cli}"

echo "🔁 Restarting $CONTAINER_NAME so it picks up the new environment..."
(cd "$ENV_DIR" && docker compose up -d)

echo ""
echo "✅ Done. The restart ended any live tmux session — SSH back in"
echo "   (ssh -p \${SSH_PORT:-2222} claude@<host>) and it reattaches"
echo "   automatically, resuming your conversation (--continue) against"
echo "   the new endpoint. Verify inside that session: echo \$ANTHROPIC_BASE_URL"
