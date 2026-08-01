#!/bin/bash
set -euo pipefail

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

CURRENT_UID="$(id -u codex)"
CURRENT_GID="$(id -g codex)"
[ "$PUID" = "$CURRENT_UID" ] || usermod -u "$PUID" codex

# macOS commonly uses GID 20 ("staff"). Debian already has a different group
# at that numeric GID, so `groupmod -g 20 codex` would fail with "GID already
# exists". Reuse an existing numeric group when present; otherwise renumber
# the private codex group as usual. This keeps the same image usable with
# Linux's common 1000:1000 and macOS's common 501:20 ownership.
if [ "$PGID" != "$CURRENT_GID" ]; then
    EXISTING_GROUP="$(getent group "$PGID" | cut -d: -f1 || true)"
    if [ -n "$EXISTING_GROUP" ]; then
        usermod -g "$EXISTING_GROUP" codex
    else
        groupmod -g "$PGID" codex
    fi
fi

mkdir -p /home/codex/.codex/packages /home/codex/workspace /home/codex/.ssh

# `codex remote-control` deliberately launches app-server from the standalone
# installer's fixed path under $CODEX_HOME. The image keeps that installer-
# managed tree under /opt so CLEAN rebuilds update the CLI without replacing
# persistent auth and settings. Expose the image-owned tree at the required
# runtime path. The target remains writable by the remapped codex user because
# remote control may update its managed app-server files there.
MANAGED_STANDALONE_DIR="/opt/codex/packages/standalone"
RUNTIME_STANDALONE_DIR="/home/codex/.codex/packages/standalone"
chown -R "$PUID:$PGID" /opt/codex
if [ ! -e "$RUNTIME_STANDALONE_DIR" ] && [ ! -L "$RUNTIME_STANDALONE_DIR" ]; then
    ln -s "$MANAGED_STANDALONE_DIR" "$RUNTIME_STANDALONE_DIR"
fi
if [ ! -x "$RUNTIME_STANDALONE_DIR/current/codex" ]; then
    echo "ERROR: managed standalone Codex install is unavailable at $RUNTIME_STANDALONE_DIR/current/codex" >&2
    exit 1
fi

# The whole user home is persistent, so fix ownership for settings created
# under the image's original 1000:1000 identity. Explicitly prune the nested
# bind-mounted workspace: recursively changing a possibly large host repo is
# unnecessary on Linux and crosses the VM/host boundary on macOS.
find /home/codex -path /home/codex/workspace -prune \
    -o -exec chown "$PUID:$PGID" {} +
chown "$PUID:$PGID" /home/codex/workspace

ssh-keygen -A
if [ -f /run/host-authorized_keys ]; then
    cp /run/host-authorized_keys /home/codex/.ssh/authorized_keys
else
    echo "⚠️  No authorized_keys file found; SSH login is unavailable until the configured host file exists." >&2
    : > /home/codex/.ssh/authorized_keys
fi
chown -R "$PUID:$PGID" /home/codex/.ssh
chmod 700 /home/codex/.ssh
chmod 600 /home/codex/.ssh/authorized_keys

if [ -n "${GIT_USER_NAME:-}" ]; then
    runuser -u codex -- git config --global user.name "$GIT_USER_NAME"
fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then
    runuser -u codex -- git config --global user.email "$GIT_USER_EMAIL"
fi

if [ -n "${GH_TOKEN:-}" ]; then
    sed -i '/^GH_TOKEN=/d' /etc/environment
    printf 'GH_TOKEN=%s\n' "$GH_TOKEN" >> /etc/environment
    runuser -u codex -- env GH_TOKEN="$GH_TOKEN" gh auth setup-git
else
    sed -i '/^GH_TOKEN=/d' /etc/environment
fi

# Import an explicitly configured non-interactive credential only when the
# persistent Codex home does not already contain a valid login.
if ! runuser -u codex -- codex login status >/dev/null 2>&1; then
    if [ -n "${CODEX_ACCESS_TOKEN:-}" ]; then
        printf '%s' "$CODEX_ACCESS_TOKEN" \
            | runuser -u codex -- codex login --with-access-token
    elif [ -n "${OPENAI_API_KEY:-}" ]; then
        printf '%s' "$OPENAI_API_KEY" \
            | runuser -u codex -- codex login --with-api-key
    fi
fi

# PAM reads model selection into each new SSH login. Always remove an old
# value first so clearing CODEX_MODEL in .env really clears the override.
sed -i '/^CODEX_MODEL=/d' /etc/environment
if [ -n "${CODEX_MODEL:-}" ]; then
    printf 'CODEX_MODEL=%s\n' "$CODEX_MODEL" >> /etc/environment
fi

exec /usr/sbin/sshd -D -e
