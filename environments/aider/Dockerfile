# Standalone Aider container reachable directly over SSH — same shape as
# this repo's own claude-cli environment (own sshd, persistent tmux
# session, bind-mounted workspace) but running Aider (https://aider.chat)
# instead of Claude Code, so it can target any provider its own litellm
# backend supports: Anthropic directly, this repo's own llm-gateways
# LiteLLM proxy (Claude, DeepSeek, local Ollama models — see that
# environment), or any other OpenAI-compatible endpoint. See README's
# "Choosing a Provider" for the two ways to point it somewhere.
FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server \
        tmux \
        git \
        curl \
        ca-certificates \
        procps \
        less \
        vim \
    && rm -rf /var/lib/apt/lists/*

# pip install, not the aider-install curl script — this repo's other
# CLI-tool environments (claude-cli, nanoclaw's Claude CLI) already
# establish curl|bash as the pattern for tools that ship one; aider's own
# docs list plain `pip install aider-chat` as the primary supported method
# instead (its "aider-install" wrapper is just a pipx-based convenience for
# host installs, not meaningfully different from this inside a container
# already dedicated to running it).
RUN pip install --no-cache-dir aider-chat

# Non-root login user, matching claude-cli's own reasoning exactly: Aider's
# own state (this repo mounts it below) and the SSH session both run as
# this unprivileged user, never as root.
#
# python:3.12-slim doesn't ship a stray "node"-style UID 1000 user the way
# node:20-slim does, so no pre-emptive userdel is needed here before
# useradd — confirmed directly against this base image's own /etc/passwd.
RUN useradd --uid 1000 --create-home --shell /bin/bash aider

# sshd proper (not just the client) needs its own runtime dir and host keys.
RUN mkdir -p /run/sshd

# Auto-attach (or create) a detachable tmux session running `aider` on
# every interactive SSH login — identical grouped-session mechanism to
# claude-cli's own bashrc-tmux-attach.sh (see that file's comment, and this
# environment's own copy, for the full explanation).
COPY .tmux.conf /home/aider/.tmux.conf
RUN chown aider:aider /home/aider/.tmux.conf
COPY bashrc-tmux-attach.sh /etc/profile.d/aider-tmux-attach.sh
RUN chmod +x /etc/profile.d/aider-tmux-attach.sh

# sshd config: key-based auth only. No password login, no root login — the
# authorized_keys file is bind-mounted read-only from the host at runtime
# (see docker-compose.yml), so access is controlled entirely by whoever's
# public key is in that file, not by anything baked into this image.
RUN sed -i \
        -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' \
        -e 's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
        -e 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' \
        -e 's/^#\?AllowAgentForwarding.*/AllowAgentForwarding yes/' \
        /etc/ssh/sshd_config

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
