# Standalone Pi coding-agent container with its own SSH server and a
# persistent tmux session. The user's repository is bind-mounted at runtime.
# The official Node image supports both amd64 and arm64 and supplies node,
# npm, and npx.
#
# Node 24 is not incidental. Pi has NO native MCP — by design, because an MCP
# tool schema costs 7-14k tokens of context and Pi's whole pitch is a ~200
# token system prompt. mcporter (installed below) puts MCP back within reach
# as a COMMAND rather than an always-loaded tool schema, so it costs nothing
# until the agent invokes it. See
# docs/future-enhancements/agent-control-environments.md.
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
        ripgrep \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI, installed from its official architecture-aware apt repository.
RUN mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Official Node images reserve uid/gid 1000 for their "node" user. Remove it
# before creating the runtime account so PUID/PGID defaults and remapping keep
# the same behavior as the other CLI environments.
RUN userdel -r node \
    && (groupdel node || true) \
    && useradd --uid 1000 --create-home --shell /bin/bash pi \
    && mkdir -p /run/sshd

# ─────────────────────────────────────────────────────────────────────────
# PIN THE SCOPE AND THE VERSION. BOTH.
#
# Four scopes publish a package called "pi-coding-agent" and all four install
# without error:
#
#   @earendil-works/pi-coding-agent   <- current canonical Pi (this one)
#   @mariozechner/pi-coding-agent     <- pre-acquisition Pi, STILL PUBLISHED
#   @oh-my-pi/pi-coding-agent         <- omp, a different product entirely
#   @badlogic/pi
#
# The dangerous one is not omp: its version scheme (18.x) is so different
# that a pinned version is unambiguous. It is @mariozechner, which older
# guides still name, which installs cleanly, and which silently gives you a
# Pi twelve minor versions stale with nothing to catch it.
#
# --ignore-scripts is upstream's own documented install line: Pi needs no
# dependency lifecycle scripts for a normal npm install.
# ─────────────────────────────────────────────────────────────────────────
ARG PI_PACKAGE_VERSION=0.85.1
RUN npm install -g --ignore-scripts "@earendil-works/pi-coding-agent@${PI_PACKAGE_VERSION}"

# mcporter — an MCP *client* runtime, not a server. `mcporter list` / `call`
# make MCP servers reachable from Pi's bash tool without paying for a tool
# schema in every prompt. Installed here rather than given an environments/
# folder of its own, the same treatment gh gets.
ARG MCPORTER_VERSION=latest
RUN npm install -g "mcporter@${MCPORTER_VERSION}"

COPY .tmux.conf /home/pi/.tmux.conf
RUN chown pi:pi /home/pi/.tmux.conf
COPY bashrc-tmux-attach.sh /etc/profile.d/pi-tmux-attach.sh
RUN chmod +x /etc/profile.d/pi-tmux-attach.sh

RUN sed -i \
        -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' \
        -e 's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
        -e 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' \
        -e 's/^#\?AllowAgentForwarding.*/AllowAgentForwarding yes/' \
        /etc/ssh/sshd_config

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
