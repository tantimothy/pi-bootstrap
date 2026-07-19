#!/usr/bin/env bash
# Interactive wizard that creates and deploys a second (or third, ...)
# independent Claude CLI instance — everything README's "Running Multiple
# Instances" describes doing by hand: copy this folder, give the copy a
# distinct CONTAINER_NAME/SSH_PORT/CLAUDE_WORKSPACE_PATH, register it in
# config/environments.yaml, deploy it, and install its own desktop entries.
#
# Invoked from the "New Claude CLI Instance..." desktop entry (any
# instance's own copy — each instance can spawn a sibling, since ${ENV_DIR}
# in desktop-entries.yaml always resolves to whichever instance launched
# it), or run directly: ./environments/claude-cli/new-instance.sh
set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$ENV_DIR/../.." && pwd)"
ENVIRONMENTS_DIR="$REPO_DIR/environments"

source "$REPO_DIR/lib/locale-lib.sh" || true
source "$REPO_DIR/lib/deploy-lib.sh"

echo "🧬 New Claude CLI Instance"
echo "=========================="
echo "Creates a second, fully independent Claude CLI container — its own SSH"
echo "port, login state, SSH host key, and workspace — alongside $(basename "$ENV_DIR")."
echo "Ctrl+C at any prompt cancels with nothing created."
echo ""

# 1. Instance name — becomes the environments/claude-cli-<name> folder AND
# (unless overridden in the .env this writes below) CONTAINER_NAME.
while true; do
    read -rp "Instance name (e.g. 'work' -> creates claude-cli-work/): " SUFFIX
    SUFFIX="$(printf '%s' "$SUFFIX" | tr -cd 'a-zA-Z0-9_-')"
    if [ -z "$SUFFIX" ]; then
        echo "  Enter at least one letter or number."
        continue
    fi
    NEW_NAME="claude-cli-${SUFFIX}"
    NEW_DIR="$ENVIRONMENTS_DIR/$NEW_NAME"
    if [ -e "$NEW_DIR" ]; then
        echo "  ❌ $NEW_NAME already exists — pick a different name."
        continue
    fi
    break
done

# 2. SSH port — suggest the lowest one not already claimed by an existing
# claude-cli* instance's own .env (still just a suggestion: two instances
# only ever actually collide if you deploy both with the same value, same
# as picking any other port by hand).
_suggest_port() {
    local port=2222 used
    used=$(grep -h "^SSH_PORT=" "$ENVIRONMENTS_DIR"/claude-cli*/.env 2>/dev/null \
        | sed -e "s/^SSH_PORT=//" -e "s/[\"']//g" || true)
    while printf '%s\n' "$used" | grep -qx "$port"; do
        port=$((port + 1))
    done
    printf '%s' "$port"
}
DEFAULT_PORT="$(_suggest_port)"
read -rp "SSH port [$DEFAULT_PORT]: " SSH_PORT
SSH_PORT="${SSH_PORT:-$DEFAULT_PORT}"

# 3. Workspace path — the repo/directory this instance's `claude` operates
# on. Same leading-~ expansion deploy.sh's own .env form applies.
DEFAULT_WORKSPACE="$HOME/${NEW_NAME}-workspace"
read -rp "Workspace path to bind-mount [$DEFAULT_WORKSPACE]: " CLAUDE_WORKSPACE_PATH
CLAUDE_WORKSPACE_PATH="${CLAUDE_WORKSPACE_PATH:-$DEFAULT_WORKSPACE}"
case "$CLAUDE_WORKSPACE_PATH" in
    "~") CLAUDE_WORKSPACE_PATH="$HOME" ;;
    "~/"*) CLAUDE_WORKSPACE_PATH="$HOME/${CLAUDE_WORKSPACE_PATH#\~/}" ;;
esac
mkdir -p "$CLAUDE_WORKSPACE_PATH"

echo ""
echo "About to create $NEW_NAME:"
echo "  SSH_PORT=$SSH_PORT"
echo "  CLAUDE_WORKSPACE_PATH=$CLAUDE_WORKSPACE_PATH"
read -rp "Proceed? [Y/n] " CONFIRM
case "$CONFIRM" in
    [nN]*) echo "Cancelled — nothing created."; exit 0 ;;
esac

# 4. Copy this instance's own folder as the template, then strip anything
# generated/local that a fresh instance shouldn't inherit (see
# .gitignore's own comments for why each of these is never tracked).
cp -a "$ENV_DIR" "$NEW_DIR"
rm -rf "$NEW_DIR/logs" "$NEW_DIR/post-deploy-info.html" \
       "$NEW_DIR/.deployed" "$NEW_DIR/.container-config-hash"
rm -f "$NEW_DIR/.env"

# 5. Write the new instance's own .env — same single-quoted KEY='value'
# format deploy.sh's own bulk form compiler writes, so a later "configure
# this environment" pass through deploy.sh reads these back correctly as
# its form defaults. SSH_AUTHORIZED_KEYS_PATH/PUID/PGID/GIT_USER_*/GH_TOKEN
# are carried over from THIS instance's own .env when it has one, so
# shared identity/key settings don't need re-entering per instance.
_carried() {
    local key="$1" default="$2"
    [ -f "$ENV_DIR/.env" ] && grep -q "^${key}=" "$ENV_DIR/.env" \
        && grep "^${key}=" "$ENV_DIR/.env" | cut -d'=' -f2- | sed -e "s/^'//" -e "s/'\$//" \
        || printf '%s' "$default"
}
{
    printf "CONTAINER_NAME='%s'\n" "$NEW_NAME"
    printf "SSH_PORT='%s'\n" "$SSH_PORT"
    printf "CLAUDE_WORKSPACE_PATH='%s'\n" "$CLAUDE_WORKSPACE_PATH"
    printf "SSH_AUTHORIZED_KEYS_PATH='%s'\n" "$(_carried SSH_AUTHORIZED_KEYS_PATH "$HOME/.ssh/authorized_keys")"
    printf "PUID='%s'\n" "$(_carried PUID "$(id -u)")"
    printf "PGID='%s'\n" "$(_carried PGID "$(id -g)")"
    for key in GIT_USER_NAME GIT_USER_EMAIL GH_TOKEN; do
        val="$(_carried "$key" "")"
        [ -n "$val" ] && printf "%s='%s'\n" "$key" "$val"
    done
} > "$NEW_DIR/.env"
echo "✅ Wrote $NEW_DIR/.env"

# 6. Register it in config/environments.yaml's "ai" category, right after
# claude-cli, so it's grouped in deploy.sh's menu like every other AI
# Assistant instead of falling to the unlisted-folder alphabetical
# fallback (see README's "Running Multiple Instances").
CONFIG_YAML="$REPO_DIR/config/environments.yaml"
if ! grep -qxF "      - $NEW_NAME" "$CONFIG_YAML"; then
    sed -i.bak "/^      - claude-cli\$/a\\
      - $NEW_NAME" "$CONFIG_YAML"
    rm -f "$CONFIG_YAML.bak"
    echo "✅ Registered $NEW_NAME in config/environments.yaml"
fi

# 7. Deploy it — same DOCKER_CMD escalation deploy.sh itself does.
echo ""
echo "🚀 Deploying $NEW_NAME (first build can take a minute)..."
DOCKER_CMD="docker"
if ! docker ps &>/dev/null; then
    echo "🔒 Raw docker commands denied. Escalating to 'sudo docker' wrapper..."
    DOCKER_CMD="sudo docker"
fi
if deploy_environment "$NEW_DIR" "FAST" "$DOCKER_CMD"; then
    echo "✅ $NEW_NAME is up."
else
    echo "❌ Deploy failed — see the log above, or under $NEW_DIR/logs/."
    read -rp "Press Enter to close..." _
    exit 1
fi

# 8. Install its own desktop entries so its submenu/shortcuts show up
# immediately, without waiting for a full ./install-desktop-entries.sh
# rerun across every environment.
if [[ "$(uname)" != "Darwin" ]]; then
    bash "$REPO_DIR/lib/run-install-desktop.sh" "$NEW_DIR"
fi

echo ""
echo "🎉 $NEW_NAME is ready:"
echo "   ssh -p $SSH_PORT claude@localhost"
echo "   Folder: $NEW_DIR"
read -rp "Press Enter to close..." _
