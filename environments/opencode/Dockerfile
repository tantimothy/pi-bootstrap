# Standalone OpenCode container with its own SSH server and a persistent
# tmux session. The user's repository is bind-mounted at runtime.
#
# Node is here for MCP servers and LSP servers, NOT for OpenCode itself —
# OpenCode ships as a self-contained binary. Unlike `pi`, this image gets
# NO mcporter: OpenCode has native MCP, so an MCP client runtime would be
# redundant. See docs/future-enhancements/agent-control-environments.md.
FROM node:24-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server \
        tmux \
        git \
        curl \
        unzip \
        ca-certificates \
        procps \
        util-linux \
        less \
        vim \
        ripgrep \
        fzf \
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
# the same behavior as the other CLI environments.
RUN userdel -r node \
    && (groupdel node || true) \
    && useradd --uid 1000 --create-home --shell /bin/bash opencode \
    && mkdir -p /run/sshd /opt/opencode \
    && chown opencode:opencode /opt/opencode

# ─────────────────────────────────────────────────────────────────────────
# Install to /opt, not to the runtime home — and force it with HOME.
#
# The installer HARDCODES `INSTALL_DIR=$HOME/.opencode/bin` on line 68. Its
# README documents an OPENCODE_INSTALL_DIR override, but the script does not
# read that variable at all — checked against the source, not assumed. So
# HOME is the only lever, and setting it for this one RUN is what keeps the
# binary out of /home/opencode.
#
# That matters for exactly the reason codex-cli's Dockerfile gives for its
# own /opt dance: /home/opencode is a PERSISTENT VOLUME. A binary installed
# there would survive a CLEAN image rebuild and keep running the old version
# while every check reported the new one — the silently-stale-copy failure
# recorded in docs/lessons-learned/nanoclaw-mnemon.md.
#
# --no-modify-path stops the installer editing .bashrc/.zshrc, which it does
# by default and which would be a persistent-volume edit for the same reason.
#
# Also worth knowing, and the reason this pins a version by default: the
# OpenCode installer does NO CHECKSUM VERIFICATION. herdr's and collie's
# installers both verify a sha256 sidecar and refuse to install without one;
# this one downloads and unpacks. A pinned version at least makes what you
# get reproducible.
#
# Release artifacts come from github.com/anomalyco/opencode — that IS the
# official home (the project's own README badges, brew tap and download
# links all point there; sst/opencode redirects to it). The thing to avoid is
# a third-party Docker image, not that org.
# ─────────────────────────────────────────────────────────────────────────
ARG OPENCODE_VERSION=""
USER opencode
# Downloaded to a file and then run, rather than piped: `HOME=x curl | bash`
# sets HOME for curl, not for the shell that actually installs.
RUN curl -fsSL https://opencode.ai/install -o /tmp/install-opencode.sh \
    && if [ -n "$OPENCODE_VERSION" ]; then \
           HOME=/opt/opencode bash /tmp/install-opencode.sh --no-modify-path --version "$OPENCODE_VERSION"; \
       else \
           HOME=/opt/opencode bash /tmp/install-opencode.sh --no-modify-path; \
       fi \
    && rm -f /tmp/install-opencode.sh
USER root

# Login shells reset PATH via /etc/profile, so put the image-owned binary
# somewhere /etc/profile's PATH already covers. A copy, not a symlink into a
# home directory: nothing in /home may pin or break the image-owned CLI.
RUN cp /opt/opencode/.opencode/bin/opencode /usr/local/bin/opencode \
    && chmod 755 /usr/local/bin/opencode \
    && /usr/local/bin/opencode --version

COPY .tmux.conf /home/opencode/.tmux.conf
RUN chown opencode:opencode /home/opencode/.tmux.conf
COPY bashrc-tmux-attach.sh /etc/profile.d/opencode-tmux-attach.sh
RUN chmod +x /etc/profile.d/opencode-tmux-attach.sh

RUN sed -i \
        -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' \
        -e 's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
        -e 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' \
        -e 's/^#\?AllowAgentForwarding.*/AllowAgentForwarding yes/' \
        /etc/ssh/sshd_config

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
