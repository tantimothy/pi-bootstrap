# Standalone Claude CLI container reachable directly over SSH — no NanoClaw,
# no channel bots, no orchestrator spawning sibling containers. Just the
# `claude` CLI, a bind-mounted git repo, and an sshd of its own so this
# container is reachable from any machine that has your SSH key, without
# needing shell access on the host at all (unlike nanoclaw-mnemon's own
# "SSH to the host, then docker exec" pattern — see that environment's
# README's "SSH'ing in from Another macOS Machine" section for the
# alternative this container avoids requiring).
FROM node:20-slim

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

# Non-root login user. Claude CLI and its own OAuth/session state live
# entirely under this user's home, matching how it's run everywhere else in
# this repo (never as root).
RUN useradd --create-home --shell /bin/bash claude

# sshd proper (not just the client) needs its own runtime dir and host keys.
RUN mkdir -p /run/sshd

# Same installer nanoclaw-mnemon's own Dockerfile pre-installs Claude CLI
# with — see that Dockerfile's comment for why this is done at build time
# rather than left to a first-run prompt.
USER claude
RUN curl -fsSL https://claude.ai/install.sh | bash
USER root
ENV PATH="/home/claude/.local/bin:${PATH}"

# Auto-attach (or create) a detachable tmux session running `claude` on
# every interactive SSH login — see README's "How Login Works" for why:
# this is what makes the session survive a dropped connection and lets
# multiple devices reconnect to the exact same live conversation.
COPY bashrc-tmux-attach.sh /etc/profile.d/claude-tmux-attach.sh
RUN chmod +x /etc/profile.d/claude-tmux-attach.sh

# sshd config: key-based auth only. No password login, no root login — the
# authorized_keys file is bind-mounted read-only from the host at runtime
# (see docker-compose.yml), so access is controlled entirely by whoever's
# public key is in that file, not by anything baked into this image.
RUN sed -i \
        -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' \
        -e 's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
        -e 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' \
        /etc/ssh/sshd_config

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
