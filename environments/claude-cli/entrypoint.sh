#!/bin/bash
# Runs as root (the container's own PID 1) so it can fix ownership before
# handing off to sshd — everything a logged-in user actually touches
# (workspace, ~/.claude, the SSH session itself) runs as the unprivileged
# "claude" user.
set -euo pipefail

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

# Re-number the "claude" user/group to match the host UID/GID that owns the
# bind-mounted workspace (set PUID/PGID in .env to your own `id -u`/`id -g`
# if they're not the common default 1000/1000) — otherwise files the host
# already owns show up unwritable (or owned by the wrong name entirely)
# once you're inside an SSH session as "claude".
CURRENT_UID="$(id -u claude)"
CURRENT_GID="$(id -g claude)"
if [ "$PUID" != "$CURRENT_UID" ]; then
    usermod -u "$PUID" claude
fi
if [ "$PGID" != "$CURRENT_GID" ]; then
    groupmod -g "$PGID" claude
fi
chown -R claude:claude /home/claude

# Host keys persist in a named volume (see docker-compose.yml) so the
# container's SSH fingerprint stays stable across recreation — ssh-keygen -A
# only generates keys that don't already exist there, so this is safe to
# run on every start.
ssh-keygen -A

# The host's authorized_keys file is bind-mounted read-only at a path
# outside ~/.ssh (see docker-compose.yml) rather than directly onto
# ~/.ssh/authorized_keys itself, since sshd's StrictModes checks ownership
# and permissions on that exact file/dir — a raw bind mount would keep the
# host's own ownership/mode, which won't generally satisfy that check
# inside the container. Copying the content into a container-owned file
# with the right mode sidesteps it.
mkdir -p /home/claude/.ssh
if [ -f /run/host-authorized_keys ]; then
    cp /run/host-authorized_keys /home/claude/.ssh/authorized_keys
else
    echo "⚠️  No authorized_keys file found at the mounted SSH_AUTHORIZED_KEYS_PATH — no key will be able to log in until one exists there." >&2
    : > /home/claude/.ssh/authorized_keys
fi
chown -R claude:claude /home/claude/.ssh
chmod 700 /home/claude/.ssh
chmod 600 /home/claude/.ssh/authorized_keys

mkdir -p /home/claude/workspace
chown claude:claude /home/claude/workspace

# Optional git identity — otherwise commits inside the container fail with
# no user.name/user.email configured. See README's "Connecting to a GitHub
# Repo".
if [ -n "${GIT_USER_NAME:-}" ]; then
    runuser -u claude -- git config --global user.name "$GIT_USER_NAME"
fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then
    runuser -u claude -- git config --global user.email "$GIT_USER_EMAIL"
fi

# Optional GH_TOKEN — written to /etc/environment (not a file under
# ~/.ssh or ~/.claude) so PAM hands it to every future SSH login shell
# automatically; both the `gh` CLI and its git credential helper read
# GH_TOKEN straight from the environment, so no token file ever touches
# disk under the claude user's own home. `gh auth setup-git` wires git's
# own credential.helper to call `gh auth git-credential`, so plain
# `git push`/`git clone` over HTTPS pick this up too, not just `gh` itself.
if [ -n "${GH_TOKEN:-}" ]; then
    sed -i '/^GH_TOKEN=/d' /etc/environment
    echo "GH_TOKEN=${GH_TOKEN}" >> /etc/environment
    runuser -u claude -- env GH_TOKEN="$GH_TOKEN" gh auth setup-git
fi

exec /usr/sbin/sshd -D -e
