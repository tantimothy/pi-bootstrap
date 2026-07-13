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

# Borrow just the `docker` CLI binary from the official image rather than
# adding Docker's apt repo — smaller image, no apt-key/repo setup for a
# single binary.
FROM docker:27-cli AS docker-cli

FROM node:20-slim

COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker

RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        procps \
        curl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && corepack enable \
    && corepack prepare pnpm@latest --activate

COPY entrypoint.sh /usr/local/bin/nanoclaw-entrypoint.sh
RUN chmod +x /usr/local/bin/nanoclaw-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/nanoclaw-entrypoint.sh"]
