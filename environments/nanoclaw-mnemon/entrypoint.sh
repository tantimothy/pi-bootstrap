#!/usr/bin/env bash
# Container entrypoint (PID 1). Baked into the image (see Dockerfile) since
# it must exist before NanoClaw's own source is ever cloned into the
# bind-mounted install path.
#
# NANOCLAW_INSTALL_PATH is passed in by run.sh as an env var and MUST be
# the exact same absolute path on the host and inside this container (see
# the README's "Deployment Modes" section for why) — this script never
# hardcodes a path of its own.
set -uo pipefail

INSTALL_DIR="${NANOCLAW_INSTALL_PATH:?NANOCLAW_INSTALL_PATH must be set}"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# NanoClaw's own setup wizard (run interactively via `docker exec`, not
# here — see run.sh) installs into this same directory and, on Linux
# without systemd (this container's baseline reality — see the README),
# falls into its own setupNohupFallback(): `nohup node dist/index.js
# >> logs/nanoclaw.log 2>> logs/nanoclaw.error.log &`, then returns. That
# background process is a live descendant of this container's own init,
# independent of whatever spawned it (the wizard's `docker exec` session,
# or this script on a restart) — it keeps running as long as THIS
# container does, regardless of which process originally launched it.
#
# On every container start (including the very first, before install),
# check whether that background process is already alive; if the
# container was just recreated and it isn't, relaunch it directly rather
# than re-running the whole interactive wizard.
if [ -f "dist/index.js" ]; then
    if [ ! -f nanoclaw.pid ] || ! kill -0 "$(cat nanoclaw.pid)" 2>/dev/null; then
        echo "🔄 Relaunching NanoClaw's background process..."
        mkdir -p logs
        nohup node dist/index.js >> logs/nanoclaw.log 2>> logs/nanoclaw.error.log &
        echo $! > nanoclaw.pid
    fi
else
    echo "⏳ NanoClaw isn't installed yet in this container."
    echo "   run.sh hands off to the interactive setup wizard automatically"
    echo "   on first deploy — if you're seeing this some other way, run:"
    echo "   docker exec -it ${CONTAINER_NAME:-nanoclaw-mnemon} bash -lc 'cd \$NANOCLAW_INSTALL_PATH && bash nanoclaw.sh'"
fi

# Keeps this container's PID 1 (and therefore the container itself) alive,
# and doubles as making `docker logs -f nanoclaw` show NanoClaw's actual
# application log — the nohup'd process above writes to a file, not to
# this script's own stdout, so without this `docker logs` would show
# nothing.
mkdir -p logs
touch logs/nanoclaw.log
exec tail -F logs/nanoclaw.log
