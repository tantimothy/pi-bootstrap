FROM debian:bookworm-slim

# ntopng isn't packaged in Debian's own repos — it has to come from ntop's
# own apt repository. This closely mirrors ntop's own official ARM64 build
# recipe (Dockerfile.ntopng_arm64.dev in https://github.com/ntop/docker-ntop),
# which confirms the apt-ntop.deb repo-detection installer works correctly
# inside a plain debian:bookworm-slim container — not real Raspberry Pi OS.
# Building this locally (docker compose build always runs natively, no
# cross-compilation) targets the Pi's real architecture (arm64/armhf)
# automatically, avoiding the "exec format error" crash loop the official
# ntop/ntopng:latest image hits on ARM — that image only ever publishes
# linux/amd64.
#
# Deliberately not using ntop's own entrypoint pattern (which bundles a
# local redis-server inside the same container) since this environment
# already runs ntopng-redis as its own service.
RUN apt-get update \
    && apt-get -y -q install --no-install-recommends \
        software-properties-common \
        wget \
        whiptail \
        lsb-release \
        gnupg \
        libelf1 \
    && wget -q http://packages.ntop.org/RaspberryPI/apt-ntop.deb \
    && apt-get -y -q install ./apt-ntop.deb \
    && rm ./apt-ntop.deb \
    && apt-get update \
    && apt-get -y -q install --no-install-recommends \
        ntopng \
        libcap2 \
        libzstd1 \
    && apt-get clean all \
    && rm -rf /var/lib/apt/lists/*

# docker-compose.yml's `command:` for this service is flags only (-i/-w/-r),
# not the binary name — it relies on an entrypoint to prepend `ntopng`, the
# same way the official ntop/ntopng image's own /run.sh entrypoint does
# (visible in its "exec /run.sh: exec format error" crash on ARM).
RUN echo '#!/bin/bash\nexec ntopng "$@"' > /run.sh && chmod +x /run.sh
ENTRYPOINT ["/run.sh"]
