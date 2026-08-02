# Extend OpenClaw's official multi-architecture gateway image rather than
# copying its rapidly evolving source build into pi-bootstrap. CLEAN pulls the
# current official image, then rebuilds this thin tooling layer.
FROM ghcr.io/openclaw/openclaw:latest

USER root

# tmux backs persistent admin sessions for both CLIs. The remaining tools are
# useful to the CLIs and to OpenClaw skills operating in the shared workspace.
RUN apt-get update && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        git \
        jq \
        less \
        procps \
        tmux \
    && rm -rf /var/lib/apt/lists/*

# Keep both image-owned CLI programs outside the persistent runtime home. The
# whole /home/node tree is a named volume at runtime so post-setup user files,
# caches, plugins, and tools survive CLEAN; installing either CLI there would
# let the preserved old binary shadow a newly rebuilt one indefinitely.
RUN mkdir -p /opt/claude /opt/codex /opt/codex-home \
    && chown -R node:node /opt/claude /opt/codex /opt/codex-home \
    && printf '%s\n' '{}' > /opt/claude/.claude.json \
    && chown node:node /opt/claude/.claude.json

USER node

# These are the same official installers used by the standalone claude-cli and
# codex-cli environments in this repository. Both select the correct binary
# for the image architecture. Give each installer an image-owned HOME so its
# executable and release payload stay outside /home/node.
ENV HOME="/opt/claude"
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV HOME="/opt/codex-home"
ENV CODEX_HOME="/opt/codex"
RUN curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh

USER root

# Login shells may replace PATH through /etc/profile. Stable links in
# /usr/local/bin keep both commands available to OpenClaw and docker exec.
RUN cp -P /opt/claude/.local/bin/claude /usr/local/bin/claude \
    && cp -P /opt/codex-home/.local/bin/codex /usr/local/bin/codex

COPY scripts/cli-tmux.sh /usr/local/bin/openclaw-cli-tmux
RUN chmod +x /usr/local/bin/openclaw-cli-tmux

ENV HOME="/home/node"
ENV CODEX_HOME="/home/node/.codex"

# Match the official OpenClaw runtime's non-root security posture.
USER node
