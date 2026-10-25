FROM debian:bookworm-slim

# A full (headed) Chromium on a virtual display, so a human can log in over
# VNC and an agent can then drive the very same browser over CDP. Debian's own
# chromium package is multi-arch (amd64 + arm64), which covers both the
# Raspberry Pi and an Apple-Silicon Mac running Docker.
RUN apt-get update && apt-get install -y --no-install-recommends \
        chromium xvfb x11vnc fluxbox socat curl ca-certificates \
        fonts-liberation fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS --max-time 4 http://127.0.0.1:9223/json/version >/dev/null || exit 1

ENTRYPOINT ["/entrypoint.sh"]
