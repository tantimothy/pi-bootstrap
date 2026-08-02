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

# Keep the image-owned Codex program outside its persistent runtime CODEX_HOME,
# so a CLEAN rebuild upgrades the binary without an older package in the state
# volume shadowing it. Claude's installer expects ~/.claude.json, when present,
# to contain valid JSON.
RUN mkdir -p /opt/codex /home/node/.local/bin \
    && chown -R node:node /opt/codex /home/node/.local \
    && printf '%s\n' '{}' > /home/node/.claude.json \
    && chown node:node /home/node/.claude.json

USER node

# These are the same official installers used by the standalone claude-cli and
# codex-cli environments in this repository. Both select the correct binary
# for the image architecture.
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV CODEX_HOME="/opt/codex"
RUN curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh

USER root

# Login shells may replace PATH through /etc/profile. Stable links in
# /usr/local/bin keep both commands available to OpenClaw and docker exec.
RUN ln -sf /home/node/.local/bin/claude /usr/local/bin/claude \
    && cp -P /home/node/.local/bin/codex /usr/local/bin/codex

COPY scripts/cli-tmux.sh /usr/local/bin/openclaw-cli-tmux
RUN chmod +x /usr/local/bin/openclaw-cli-tmux

ENV CODEX_HOME="/home/node/.codex"

# Match the official OpenClaw runtime's non-root security posture.
USER node
