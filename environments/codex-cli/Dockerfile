# Standalone Codex CLI container with its own SSH server and a persistent
# tmux session. The user's repository is bind-mounted at runtime.
FROM debian:bookworm-slim

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

RUN useradd --uid 1000 --create-home --shell /bin/bash codex \
    && mkdir -p /run/sshd /opt/codex \
    && chown codex:codex /opt/codex

# OpenAI's supported standalone installer avoids requiring Node/npm in the
# runtime image and selects the correct binary for amd64 or arm64.
#
# The installer normally stores release packages under $CODEX_HOME. Keep the
# installed program in /opt/codex, outside the persistent runtime-state mount,
# so a CLEAN image rebuild really picks up the newly built CLI version instead
# of an older package preserved in the named volume. Runtime CODEX_HOME is
# switched back to ~/.codex immediately afterwards.
USER codex
ENV CODEX_HOME="/opt/codex"
RUN curl -fsSL https://chatgpt.com/codex/install.sh | sh
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
