#!/usr/bin/env bash
# Interactive operator menu for the manual half of NanoClaw's Codex-provider
# lifecycle. CLEAN can install the runtime headlessly; this script handles
# OAuth and explicit provider activation later.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
[ -f "$ENV_DIR/.env" ] && { set -a; source "$ENV_DIR/.env"; set +a; }

INSTALL_PATH="${NANOCLAW_INSTALL_PATH:-$HOME/nanoclaw-mnemon}"
CONTAINER_NAME="${CONTAINER_NAME:-nanoclaw-mnemon}"
DOCKER="${DOCKER_CMD:-docker}"

require_container() {
    if ! "$DOCKER" ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
        echo "❌ $CONTAINER_NAME is not running. Deploy the environment first." >&2
        exit 1
    fi
}

inside() {
    "$DOCKER" exec -it "$CONTAINER_NAME" bash -lc "cd '$INSTALL_PATH' && $1"
}

list_groups() {
    echo ""
    inside "pnpm ncl groups list"
    echo ""
}

read_group_id() {
    list_groups
    read -rp "Group ID: " GROUP_ID
    if ! [[ "$GROUP_ID" =~ ^[A-Za-z0-9._:-]+$ ]]; then
        echo "❌ Group ID must contain only letters, numbers, dot, underscore, colon, or hyphen." >&2
        return 1
    fi
}

codex_installed() {
    [ -f "$INSTALL_PATH/src/providers/codex.ts" ] &&
        grep -Fq "import './codex.js';" "$INSTALL_PATH/src/providers/index.ts" 2>/dev/null &&
        grep -Fq '"@openai/codex"' "$INSTALL_PATH/container/cli-tools.json" 2>/dev/null
}

show_status() {
    echo "Codex provider status"
    echo "====================="
    if codex_installed; then
        echo "Provider source: installed"
    else
        echo "Provider source: not installed"
    fi

    if grep -Fq '"@openai/codex"' "$INSTALL_PATH/container/cli-tools.json" 2>/dev/null; then
        echo "CLI manifest:    installed"
    else
        echo "CLI manifest:    not installed"
    fi

    IMAGE_TAG=$("$DOCKER" images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -m1 '^nanoclaw-agent-v2-' || true)
    if [ -n "$IMAGE_TAG" ]; then
        echo "Agent image:     $IMAGE_TAG"
        if "$DOCKER" run --rm --entrypoint codex "$IMAGE_TAG" --version 2>/dev/null; then
            :
        else
            echo "Codex executable: missing from agent image (run CLEAN or Refresh)"
        fi
    else
        echo "Agent image:     not built"
    fi

    echo ""
    echo "Group assignments:"
    inside "pnpm ncl groups list"
    echo ""
    echo "OAuth credentials are intentionally vault-only and are not printed here."
    echo "Use “Authenticate / Refresh OAuth” to create or repair them."
}

refresh_provider() {
    echo "🔄 Refreshing the Codex provider without entering OAuth..."
    "$DOCKER" exec -i "$CONTAINER_NAME" bash -s -- "$INSTALL_PATH" < "$SCRIPT_DIR/install-codex-provider.sh"
    inside "pnpm run build"
    "$DOCKER" exec -it -e DOCKER_BUILDKIT=1 "$CONTAINER_NAME" \
        bash -lc "bash '$INSTALL_PATH/container/build.sh'"
    inside "bash start-nanoclaw.sh"
    echo "✅ Codex provider refreshed. Authentication was not changed."
}

authenticate() {
    echo "🔐 Starting NanoClaw's vault-backed Codex authentication walkthrough..."
    echo "   Choose ChatGPT subscription and complete browser/device pairing when prompted."
    inside "pnpm exec tsx setup/index.ts --step provider-auth codex"
}

choose_group_provider() {
    read_group_id
    echo "Provider for $GROUP_ID:"
    echo "  1) codex"
    echo "  2) claude"
    read -rp "Number: " PROVIDER_CHOICE
    case "$PROVIDER_CHOICE" in
        1) PROVIDER=codex ;;
        2) PROVIDER=claude ;;
        *) echo "❌ Not a valid choice: $PROVIDER_CHOICE" >&2; return 1 ;;
    esac
    if [ "$PROVIDER" = "codex" ] && ! codex_installed; then
        echo "❌ Codex is not installed. Run CLEAN with NANOCLAW_INSTALL_CODEX=true or choose Refresh first." >&2
        return 1
    fi
    inside "pnpm ncl groups config update --id '$GROUP_ID' --provider '$PROVIDER'"
    inside "pnpm ncl groups restart --id '$GROUP_ID'"
    echo "✅ $GROUP_ID now uses $PROVIDER."
}

set_default_provider() {
    echo "Default provider for groups created later:"
    echo "  1) codex"
    echo "  2) claude"
    read -rp "Number: " PROVIDER_CHOICE
    case "$PROVIDER_CHOICE" in
        1) PROVIDER=codex ;;
        2) PROVIDER=claude ;;
        *) echo "❌ Not a valid choice: $PROVIDER_CHOICE" >&2; return 1 ;;
    esac
    if [ "$PROVIDER" = "codex" ] && ! codex_installed; then
        echo "❌ Codex is not installed. Run CLEAN with NANOCLAW_INSTALL_CODEX=true or choose Refresh first." >&2
        return 1
    fi
    inside "pnpm exec tsx setup/index.ts --step set-env -- --key DEFAULT_AGENT_PROVIDER --value '$PROVIDER'"
    inside "bash start-nanoclaw.sh"
    echo "✅ New groups will default to $PROVIDER; existing groups were not changed."
}

restart_group() {
    read_group_id
    inside "pnpm ncl groups restart --id '$GROUP_ID'"
    echo "✅ Restarted $GROUP_ID."
}

show_diagnostics() {
    echo "Recent Codex/provider-related errors:"
    echo "====================================="
    "$DOCKER" exec "$CONTAINER_NAME" bash -lc \
        "grep -Ei 'codex|provider|spawn .*ENOENT|container exited non-zero|auth' '$INSTALL_PATH/logs/nanoclaw.error.log' 2>/dev/null | tail -n 100" \
        || true
}

require_container

echo "Manage NanoClaw Codex Provider"
echo "=============================="
echo "  1) Show status"
echo "  2) Install / refresh provider (headless)"
echo "  3) Authenticate / refresh OAuth"
echo "  4) Choose provider for a group"
echo "  5) Set default provider for new groups"
echo "  6) Restart a group"
echo "  7) Show recent diagnostics"
read -rp "Number: " ACTION

case "$ACTION" in
    1) show_status ;;
    2) refresh_provider ;;
    3) authenticate ;;
    4) choose_group_provider ;;
    5) set_default_provider ;;
    6) restart_group ;;
    7) show_diagnostics ;;
    *) echo "❌ Not a valid choice: $ACTION" >&2; exit 1 ;;
esac
