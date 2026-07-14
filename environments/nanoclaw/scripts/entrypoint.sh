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

# NanoClaw's own OneCLI (its agent-key vault) can't auto-detect a bind
# address from inside this container: it's a Docker-outside-of-Docker
# sibling container — only eth0/lo exist in its own network namespace, no
# docker0 bridge is visible here even though one exists on the host/VM
# side — and OneCLI's own auto-detection assumes a "bare-metal Linux with
# a visible docker0" topology it can inspect directly. That's inherent to
# this deployment shape, not something any one host's Docker setup can
# fix. Precompute it once here, from this container's own default route
# (whatever bridge network gateway it actually landed on), and drop it
# into a profile.d snippet so it's already set by the time nanoclaw.sh's
# own `docker exec -it ... bash -lc` login shell runs it (see run.sh) —
# without this, every fresh deploy hits the same manual dead end.
if [ -z "${ONECLI_BIND_HOST:-}" ]; then
    detected_gw="$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')"
    if [ -n "$detected_gw" ]; then
        echo "export ONECLI_BIND_HOST='${detected_gw}'" > /etc/profile.d/onecli-bind-host.sh
    fi
fi

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
    echo "   docker exec -it ${CONTAINER_NAME:-nanoclaw} bash -lc 'cd \$NANOCLAW_INSTALL_PATH && bash nanoclaw.sh'"
fi

# Keeps this container's PID 1 (and therefore the container itself) alive,
# and doubles as making `docker logs -f nanoclaw` show NanoClaw's actual
# application log — the nohup'd process above writes to a file, not to
# this script's own stdout, so without this `docker logs` would show
# nothing.
mkdir -p logs
touch logs/nanoclaw.log
exec tail -F logs/nanoclaw.log
