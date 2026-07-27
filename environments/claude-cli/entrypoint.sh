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

# ~/.claude.json holds Claude Code's MCP server registrations, onboarding
# state, and trusted-project list — bind-mounted directly at this exact
# path from a real host file (see docker-compose.yml and pre-deploy.sh)
# rather than symlinked into the claude_cli_home volume like an earlier
# version of this file did. That symlink looked like it should work but
# didn't survive real use: Claude Code writes this file via an atomic
# temp-file-then-rename, and POSIX rename() onto a path that's currently
# a symlink replaces the symlink itself instead of following it through
# to its target — so the very first `claude mcp add` silently broke the
# symlink and started writing to this container's own ephemeral layer
# again, invisibly, with no further entrypoint.sh run happening to notice
# and re-fix it before the next rebuild threw that whole layer away.
# Confirmed directly: a real deploy lost its MCP registration on a
# routine CLEAN rebuild. A real mount point doesn't have this failure
# mode — rename() onto it lands on the mounted storage regardless of how
# the file underneath gets written. (An intermediate version used a named
# Docker volume instead of a bind mount here — that hit a separate,
# Docker-implementation-specific bug; see docs/lessons-learned/
# claude-cli.md.)
mkdir -p /home/claude/.claude

# One-time migration for anyone upgrading from that old symlinked setup:
# the claude_cli_home volume (unaffected by this fix) may still hold real
# data at the old symlink's target path from before the rename() bug ever
# bit — if so, and the bind-mounted ~/.claude.json is still empty (this
# container has never written under the new scheme yet), carry it over
# once rather than silently starting fresh.
if [ -s /home/claude/.claude/.claude.json ] && [ ! -s /home/claude/.claude.json ]; then
    cp /home/claude/.claude/.claude.json /home/claude/.claude.json
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

# Optional ANTHROPIC_BASE_URL/ANTHROPIC_AUTH_TOKEN — redirects `claude` at
# a self-hosted gateway instead of api.anthropic.com (see
# scripts/point-to-gateway.sh and the README's "Pointing Claude CLI at a
# Gateway"). Written to /etc/environment the same way GH_TOKEN is above,
# so every future login shell sees it. Unlike GH_TOKEN, always stripped
# first regardless of whether either is currently set — scripts/
# revert-to-claude.sh's whole job is clearing these back out, and without
# an unconditional strip a prior gateway's values would survive here even
# after .env no longer sets them.
sed -i '/^ANTHROPIC_BASE_URL=/d; /^ANTHROPIC_AUTH_TOKEN=/d' /etc/environment
if [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
    echo "ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}" >> /etc/environment
fi
if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
    echo "ANTHROPIC_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN}" >> /etc/environment
fi

# Optional CLAUDE_MODEL — which model bashrc-tmux-attach.sh passes as
# `claude --model` when it creates the base tmux session (see that
# file's own comment for why only that one moment matters). Written to
# /etc/environment the same way ANTHROPIC_BASE_URL is above — a plain
# docker-compose `environment:` var doesn't reach a NEW SSH login
# session's own shell on its own, only PID 1's; /etc/environment is what
# PAM actually applies to every login. Always stripped first, same
# reasoning as ANTHROPIC_BASE_URL: clearing CLAUDE_MODEL in .env should
# actually clear it here too, not leave a stale value behind.
sed -i '/^CLAUDE_MODEL=/d' /etc/environment
if [ -n "${CLAUDE_MODEL:-}" ]; then
    echo "CLAUDE_MODEL=${CLAUDE_MODEL}" >> /etc/environment
fi

exec /usr/sbin/sshd -D -e
