#!/usr/bin/env bash
set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$ENV_DIR/../.." && pwd)"
ENVIRONMENTS_DIR="$REPO_DIR/environments"
source "$REPO_DIR/lib/locale-lib.sh" || true
source "$REPO_DIR/lib/deploy-lib.sh"

echo "🧬 New Codex CLI Instance"
echo "Creates an independent container, SSH port, Codex home, and workspace."

while true; do
    read -rp "Instance name (e.g. 'work' -> codex-cli-work): " SUFFIX
    SUFFIX="$(printf '%s' "$SUFFIX" | tr -cd 'a-zA-Z0-9_-')"
    [ -n "$SUFFIX" ] || { echo "Enter at least one letter or number."; continue; }
    NEW_NAME="codex-cli-${SUFFIX}"
    NEW_DIR="$ENVIRONMENTS_DIR/$NEW_NAME"
    [ ! -e "$NEW_DIR" ] || { echo "$NEW_NAME already exists."; continue; }
    break
done

_suggest_port() {
    local port=2223 used
    used=$(grep -h "^SSH_PORT=" "$ENVIRONMENTS_DIR"/codex-cli*/.env 2>/dev/null \
        | sed -e "s/^SSH_PORT=//" -e "s/[\"']//g" || true)
    while printf '%s\n' "$used" | grep -qx "$port"; do port=$((port + 1)); done
    printf '%s' "$port"
}
DEFAULT_PORT="$(_suggest_port)"
read -rp "SSH port [$DEFAULT_PORT]: " SSH_PORT
SSH_PORT="${SSH_PORT:-$DEFAULT_PORT}"

DEFAULT_WORKSPACE="$HOME/${NEW_NAME}-workspace"
read -rp "Workspace path [$DEFAULT_WORKSPACE]: " CODEX_WORKSPACE_PATH
CODEX_WORKSPACE_PATH="${CODEX_WORKSPACE_PATH:-$DEFAULT_WORKSPACE}"
case "$CODEX_WORKSPACE_PATH" in
    "~") CODEX_WORKSPACE_PATH="$HOME" ;;
    "~/"*) CODEX_WORKSPACE_PATH="$HOME/${CODEX_WORKSPACE_PATH#\~/}" ;;
esac

echo "Will create $NEW_NAME on port $SSH_PORT using $CODEX_WORKSPACE_PATH"
read -rp "Proceed? [Y/n] " CONFIRM
case "$CONFIRM" in [nN]*) echo "Cancelled."; exit 0 ;; esac

mkdir -p "$CODEX_WORKSPACE_PATH"
cp -a "$ENV_DIR" "$NEW_DIR"
rm -rf "$NEW_DIR/logs" "$NEW_DIR/post-deploy-info.html" \
       "$NEW_DIR/.deployed" "$NEW_DIR/.container-config-hash"
rm -f "$NEW_DIR/.env"

_carried() {
    local key="$1" default="$2"
    [ -f "$ENV_DIR/.env" ] && grep -q "^${key}=" "$ENV_DIR/.env" \
        && grep "^${key}=" "$ENV_DIR/.env" | tail -1 | cut -d= -f2- | sed -e "s/^'//" -e "s/'\$//" \
        || printf '%s' "$default"
}
{
    printf "CONTAINER_NAME=%s\n" "$NEW_NAME"
    printf "SSH_PORT='%s'\n" "$SSH_PORT"
    printf "CODEX_WORKSPACE_PATH='%s'\n" "$CODEX_WORKSPACE_PATH"
    printf "SSH_AUTHORIZED_KEYS_PATH='%s'\n" "$(_carried SSH_AUTHORIZED_KEYS_PATH "$HOME/.ssh/authorized_keys")"
    printf "PUID='%s'\n" "$(_carried PUID "$(id -u)")"
    printf "PGID='%s'\n" "$(_carried PGID "$(id -g)")"
    for key in GIT_USER_NAME GIT_USER_EMAIL GH_TOKEN OPENAI_API_KEY CODEX_ACCESS_TOKEN; do
        val="$(_carried "$key" "")"
        [ -n "$val" ] && printf "%s='%s'\n" "$key" "$val"
    done
} > "$NEW_DIR/.env"

CONFIG_YAML="$REPO_DIR/config/environments.yaml"
if ! grep -qxF "      - $NEW_NAME" "$CONFIG_YAML"; then
    sed -i.bak "/^      - codex-cli\$/a\\
      - $NEW_NAME" "$CONFIG_YAML"
    rm -f "$CONFIG_YAML.bak"
fi

DOCKER_CMD="docker"
docker ps &>/dev/null || DOCKER_CMD="sudo docker"
deploy_environment "$NEW_DIR" "FAST" "$DOCKER_CMD"
if [[ "$(uname)" != "Darwin" ]]; then
    bash "$REPO_DIR/lib/run-install-desktop.sh" "$NEW_DIR"
fi
echo "🎉 Ready: ssh -p $SSH_PORT codex@localhost"
