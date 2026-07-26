# Builds and serves https://github.com/mihaip/infinite-mac (the code behind
# infinitemac.org) — a browser-based multi-emulator platform for classic
# Mac OS. The actual emulators run as WebAssembly *in the browser*; this
# image only builds the static site (Vite) and serves it, so it's pure
# Node.js/Python tooling — no architecture-specific concerns like the
# Emscripten toolchain upstream's own Dockerfile deals with (that one is
# only needed to rebuild the emulator cores from source, which this image
# never does — the compiled WASM is already committed upstream).
FROM node:22-bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git ca-certificates curl python3 build-essential zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# uv (https://astral.sh/uv) runs the Python-side data-import scripts
# (import-disks/import-cd-roms/import-library). Installed the same way
# upstream's own scripts/build-tools.sh does, so that script's own
# `command -v uv` check finds it and skips its interactive install prompt
# (which would otherwise hang a non-interactive `docker build`).
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

WORKDIR /app

ARG INFINITE_MAC_REPO=https://github.com/mihaip/infinite-mac.git
ARG INFINITE_MAC_REF=main
# Bumping this (via --build-arg CACHEBUST=$(date +%s)) busts the cache from
# here down without redoing the apt/uv installs above — see the "Update to
# latest infinite-mac" custom action in info.yaml, which is exactly this: a
# much faster way to pick up upstream changes than CLEAN's --no-cache
# rebuild-everything.
ARG CACHEBUST=1
RUN git clone --recurse-submodules --depth 1 --branch "${INFINITE_MAC_REF}" "${INFINITE_MAC_REPO}" .

RUN npm install
# xcodebuild-dependent step (building lsar/unar from XADMaster) is skipped
# automatically on Linux — build-tools.sh only warns and moves on, per
# upstream's own script.
RUN npm run build-tools

# "minimal"/"placeholder" builds System 1 through 7.5.5 plus an empty
# CD-ROM/downloads library entirely from files already committed upstream
# (Images/) — no ROM-hosting/licensing questions, no Macintosh Garden data
# dump required, no network fetch beyond what git clone already did. See
# this environment's README for how to go further with the full library.
RUN npm run import-disks minimal
RUN npm run import-cd-roms placeholder
RUN npm run import-library placeholder

RUN npm run build

# `vite preview` needs the full toolchain (node_modules), not just the
# static build/ output, so there's nothing smaller to copy into a second
# stage — this serves directly out of the build image.
EXPOSE 4127
CMD ["npm", "run", "preview"]
