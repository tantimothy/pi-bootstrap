#!/bin/bash
# Runs as root (the container's own PID 1) so it can fix ownership before
# handing off to sshd — everything a logged-in user actually touches (the
# workspace, the SSH session itself) runs as the unprivileged "aider" user.
# Mirrors claude-cli's own entrypoint.sh structure closely; see that file's
# comments for the fuller reasoning behind each step, not repeated here.
set -euo pipefail

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

CURRENT_UID="$(id -u aider)"
CURRENT_GID="$(id -g aider)"
if [ "$PUID" != "$CURRENT_UID" ]; then
    usermod -u "$PUID" aider
fi
if [ "$PGID" != "$CURRENT_GID" ]; then
    groupmod -g "$PGID" aider
fi
chown -R aider:aider /home/aider

# Host keys persist in a named volume (see docker-compose.yml) so the
# container's SSH fingerprint stays stable across recreation.
ssh-keygen -A

mkdir -p /home/aider/.ssh
if [ -f /run/host-authorized_keys ]; then
    cp /run/host-authorized_keys /home/aider/.ssh/authorized_keys
else
    echo "⚠️  No authorized_keys file found at the mounted SSH_AUTHORIZED_KEYS_PATH — no key will be able to log in until one exists there." >&2
    : > /home/aider/.ssh/authorized_keys
fi
chown -R aider:aider /home/aider/.ssh
chmod 700 /home/aider/.ssh
chmod 600 /home/aider/.ssh/authorized_keys

mkdir -p /home/aider/workspace
chown aider:aider /home/aider/workspace

# Optional git identity — otherwise commits Aider makes inside the
# container fail with no user.name/user.email configured. Aider commits
# automatically after each change by default (--auto-commits, aider's own
# default), so this matters more here than it does for claude-cli, where
# committing is something you ask for explicitly.
if [ -n "${GIT_USER_NAME:-}" ]; then
    runuser -u aider -- git config --global user.name "$GIT_USER_NAME"
fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then
    runuser -u aider -- git config --global user.email "$GIT_USER_EMAIL"
fi

# Optional GH_TOKEN — same /etc/environment mechanism as claude-cli's own
# entrypoint.sh (see that file's comment for why): PAM applies
# /etc/environment to every future SSH login shell, unlike docker-compose's
# `environment:` block, which only ever reaches PID 1's own process.
if [ -n "${GH_TOKEN:-}" ]; then
    sed -i '/^GH_TOKEN=/d' /etc/environment
    echo "GH_TOKEN=${GH_TOKEN}" >> /etc/environment
fi

# Provider credentials/endpoint — see README's "Choosing a Provider" for
# what each combination does. All optional and independent of each other;
# aider (via its own litellm backend) reads these as plain environment
# variables with no extra flags needed. Always stripped first so clearing
# one in .env actually clears it here too, not just failing to add it.
for VAR in ANTHROPIC_API_KEY OPENAI_API_KEY OPENAI_API_BASE AIDER_MODEL; do
    sed -i "/^${VAR}=/d" /etc/environment
    VALUE="${!VAR:-}"
    if [ -n "$VALUE" ]; then
        echo "${VAR}=${VALUE}" >> /etc/environment
    fi
done

exec /usr/sbin/sshd -D -e
