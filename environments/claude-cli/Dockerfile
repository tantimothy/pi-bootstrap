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

# GitHub CLI — official apt repo method (cli.github.com/packages), so
# `apt install gh` resolves the right binary for whatever architecture
# this image is built for (amd64/arm64) without hand-picking a release
# asset. Used for the GH_TOKEN-based non-interactive path (gh auth
# setup-git, gh pr create, ...) — see README's "Connecting to a GitHub
# Repo". Plain SSH-agent-forwarded git doesn't need this at all.
RUN mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages/stable/apt stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
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
#
# AllowAgentForwarding is pinned explicitly to Debian's own default (yes)
# rather than left commented-out — that's what makes `ssh -A` (see README's
# "Connecting to a GitHub Repo") work at all, and pinning it means a future
# Debian base-image default change can't silently disable it.
RUN sed -i \
        -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' \
        -e 's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
        -e 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' \
        -e 's/^#\?AllowAgentForwarding.*/AllowAgentForwarding yes/' \
        /etc/ssh/sshd_config

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
