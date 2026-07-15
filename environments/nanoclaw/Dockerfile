# NanoClaw orchestrator runtime — Node.js + pnpm + the Docker CLI, so the
# containerized host process can shell out to the HOST's Docker daemon
# (via the bind-mounted socket run.sh passes in) to spawn per-conversation-
# group agent containers as siblings of this one, not nested inside it
# (Docker-outside-of-Docker, not Docker-in-Docker).
#
# NanoClaw's own source is deliberately NOT baked into this image — it's
# git-cloned into a bind-mounted volume at container start (see run.sh),
# exactly like the host-native deployment already does. That keeps
# `git pull` picking up upstream updates without rebuilding this image,
# and keeps this Dockerfile a stable "runtime" layer independent of
# NanoClaw's own release cadence.

# Borrow just the `docker` CLI binary (plus its bundled buildx/compose
# plugins) from the official image rather than adding Docker's apt repo —
# smaller image, no apt-key/repo setup. The bare binary alone isn't enough:
# NanoClaw's own agent-sandbox build uses BuildKit `--mount=type=cache`,
# and this same CLI is what nested `docker build`/`docker compose` calls
# use (see run.sh's -e DOCKER_BUILDKIT=1) — without the plugins directory,
# both fail outright ("buildx component is missing", "Docker Compose is
# not available") since there's no cli-plugins dir at all to find them in.
# /usr/local/libexec/docker/cli-plugins is one of the Docker CLI's built-in
# plugin search paths, so copying straight to the same path here is enough
# for it to be found with no extra config — verified against the upstream
# docker-library/docker Dockerfile for this exact tag, which installs
# docker-buildx and docker-compose to precisely that path.
FROM docker:27-cli AS docker-cli

FROM node:20-slim

COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker-cli /usr/local/libexec/docker/cli-plugins/ /usr/local/libexec/docker/cli-plugins/

# jq: NanoClaw's own channel skills (/add-telegram, /add-discord, etc.) pipe
# curl'd API responses through it directly (e.g. add-telegram's own
# `curl ... | jq -er '.result.username'` credential-validation step) —
# without it that step fails with a plain exit 127, which silently cascades
# into every later step of the skill (restart, pairing) getting skipped too,
# since they depend on it completing. Confirmed directly against a live
# /add-telegram run (against the nanoclaw-mnemon environment's identical
# base image — this one shares the same gap).
RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        procps \
        curl \
        ca-certificates \
        iproute2 \
        jq \
    && rm -rf /var/lib/apt/lists/* \
    && corepack enable \
    && corepack prepare pnpm@latest --activate

# NanoClaw's own setup wizard installs the Claude CLI reactively, on demand,
# via this exact same installer (setup/install-claude.sh) — but only when a
# failure-recovery flow ("Claude CLI is needed to diagnose this") needs it,
# and that script already skips the install cleanly if `claude` is already
# on PATH. Pre-installing it here means it's simply already there whenever
# that flow (or anything else in the container) needs it, rather than a
# slow first-time curl install triggered mid-failure.
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/root/.local/bin:${PATH}"

COPY scripts/entrypoint.sh /usr/local/bin/nanoclaw-entrypoint.sh
RUN chmod +x /usr/local/bin/nanoclaw-entrypoint.sh

# See systemctl-shim.sh for why: NanoClaw's own channel installers (Telegram,
# Discord, Slack, etc.) restart the live service via `systemctl --user
# restart` on Linux with no nohup-aware fallback, and there's no real
# systemd/systemctl in this container at all — that restart has always
# silently no-op'd here.
COPY scripts/systemctl-shim.sh /usr/local/bin/systemctl
RUN chmod +x /usr/local/bin/systemctl

ENTRYPOINT ["/usr/local/bin/nanoclaw-entrypoint.sh"]
