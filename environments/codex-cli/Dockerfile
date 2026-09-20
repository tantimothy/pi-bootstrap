# Standalone Codex CLI container with its own SSH server, Node.js for MCP
# servers, and a persistent tmux session. The user's repository is
# bind-mounted at runtime. The official Node image supports both amd64 and
# arm64 and supplies node, npm, and npx.
FROM node:24-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server \
        tmux \
        git \
        curl \
        ca-certificates \
        procps \
        util-linux \
        less \
        vim \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI, installed from its official architecture-aware apt repository.
RUN mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# ─────────────────────────────────────────────────────────────────────────
# herdr — so this container can be added as a Herdr MACHINE.
#
# `herdr machine add ssh://<user>@host:PORT` runs a herdr server IN HERE,
# which is the only way the blocked/working/idle sidebar can see this
# agent: herdr identifies an agent from the LOCAL foreground process name,
# so detection has to happen inside the container.
#
# HERDR_INSTALL_DIR=/usr/local/bin IS THE ENTIRE POINT. Left to itself,
# `machine add` installs to $HOME/.local/bin and then fails with:
#
#   herdr: installed remote binary to ~/.local/bin/herdr, but the remote
#   shell does not resolve `herdr` to that path
#
# — observed on a real deploy. Two reasons it cannot work there: SSH runs
# non-interactive commands under a shell that does not read the login
# profile, so ~/.local/bin is not on PATH; and $HOME here is a PERSISTENT
# VOLUME, so a binary installed into it survives CLEAN and goes stale —
# the same trap codex-cli's own /opt dance exists to avoid.
#
# NO VERSION PIN IS POSSIBLE. The installer reads only HERDR_INSTALL_DIR
# and MANIFEST_URL; the version comes from https://herdr.dev/latest.json.
# So this tracks latest at BUILD time, as herdr-client does at deploy
# time. `machine add` requires a compatible client/server pair and offers
# to replace a mismatched remote server, so if that prompt appears, CLEAN
# this environment to rebuild against the same manifest the client used.
RUN curl -fsSL https://herdr.dev/install.sh -o /tmp/herdr-install.sh \
    && HERDR_INSTALL_DIR=/usr/local/bin sh /tmp/herdr-install.sh \
    && rm -f /tmp/herdr-install.sh \
    && /usr/local/bin/herdr --version

# Official Node images reserve uid/gid 1000 for their "node" user. Remove it
# before creating the runtime account so PUID/PGID defaults and remapping keep
# the same behavior as the other CLI environment.
RUN userdel -r node \
    && (groupdel node || true) \
    && useradd --uid 1000 --create-home --shell /bin/bash codex \
    && mkdir -p /run/sshd /opt/codex \
    && chown codex:codex /opt/codex

# OpenAI's supported standalone installer selects the correct Codex binary for
# amd64 or arm64. Node/npm above are included for MCP servers, not for Codex's
# own installation.
#
# The installer normally stores release packages under $CODEX_HOME. Keep the
# image's installed program in /opt/codex, outside the persistent runtime-state
# mount, so a CLEAN image rebuild really picks up the newly built CLI version
# instead of an older package preserved in the named volume. At startup the
# entrypoint exposes this managed standalone tree at the fixed path beneath the
# runtime CODEX_HOME that `codex remote-control` requires. Runtime CODEX_HOME is
# switched back to ~/.codex immediately afterwards.
USER codex
ENV CODEX_HOME="/opt/codex"
RUN curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh
USER root
ENV CODEX_HOME="/home/codex/.codex"

# Login shells reset PATH via /etc/profile, so copy the installer's symlink
# itself (-P) into /usr/local/bin. Its target is the stable
# /opt/codex/.../current path. Do not create a second link through
# /home/codex/.local/bin: that home is a persistent runtime volume and a
# user edit there must not pin or break the image-owned CLI after rebuild.
RUN cp -P /home/codex/.local/bin/codex /usr/local/bin/codex

COPY .tmux.conf /home/codex/.tmux.conf
RUN chown codex:codex /home/codex/.tmux.conf
COPY bashrc-tmux-attach.sh /etc/profile.d/codex-tmux-attach.sh
RUN chmod +x /etc/profile.d/codex-tmux-attach.sh

RUN sed -i \
        -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' \
        -e 's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
        -e 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' \
        -e 's/^#\?AllowAgentForwarding.*/AllowAgentForwarding yes/' \
        /etc/ssh/sshd_config

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
