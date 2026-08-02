#!/usr/bin/env bash
# Prepare the single-file Claude settings bind mount and generate the gateway
# token before Compose touches either. Docker otherwise creates a missing bind
# source as a directory, while Claude requires ~/.claude.json to be valid JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

mkdir -p "$SCRIPT_DIR/data/claude-json"
[ -f "$SCRIPT_DIR/data/claude-json/claude.json" ] || printf '%s\n' '{}' > "$SCRIPT_DIR/data/claude-json/claude.json"

if [ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]; then
    OPENCLAW_GATEWAY_TOKEN="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
    export OPENCLAW_GATEWAY_TOKEN

    # BSD and GNU sed both accept -i.bak. Preserve any other values written by
    # deploy.sh's environment form and replace only this one key.
    if [ -f "$ENV_FILE" ]; then
        sed -i.bak '/^OPENCLAW_GATEWAY_TOKEN=/d' "$ENV_FILE"
        rm -f "$ENV_FILE.bak"
    fi
    printf "OPENCLAW_GATEWAY_TOKEN='%s'\n" "$OPENCLAW_GATEWAY_TOKEN" >> "$ENV_FILE"
    echo "🔐 Generated and saved a new OpenClaw gateway token."
fi
