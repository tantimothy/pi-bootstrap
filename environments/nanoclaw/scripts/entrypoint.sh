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
mkdir -p logs
touch logs/nanoclaw.log

if [ -f "dist/index.js" ]; then
    if [ ! -f nanoclaw.pid ] || ! kill -0 "$(cat nanoclaw.pid)" 2>/dev/null; then
        echo "🔄 Relaunching NanoClaw's background process..."
        nohup node dist/index.js >> logs/nanoclaw.log 2>> logs/nanoclaw.error.log &
        echo $! > nanoclaw.pid
    fi

    # Makes `docker logs -f nanoclaw` show NanoClaw's actual application
    # log — the nohup'd process above writes to a file, not to this
    # script's own stdout. Backgrounded (not exec'd) because the watchdog
    # loop below needs to be this container's real PID 1.
    tail -F logs/nanoclaw.log &

    # Crash-recovery watchdog. Real incident that motivated this (in the
    # sibling nanoclaw-mnemon environment, same entrypoint shape): on a
    # host reboot, NanoClaw's own ensureContainerRuntimeRunning()
    # (container-runtime.ts) hit Docker's sibling daemon before it had
    # finished starting, got ETIMEDOUT on its one-shot readiness check
    # (no retry/backoff there — worth fixing upstream too, but this loop
    # makes it a non-issue regardless), and exited FATAL. The relaunch
    # check above only runs once, at container start, before this loop —
    # it caught nothing here because the process it launched was still
    # alive at that exact moment; the crash happened seconds later, after
    # this script had already moved on. With no supervisor watching
    # afterward, the container itself stayed running (this script's PID 1
    # never exited, so Docker's --restart policy never triggered) while
    # NanoClaw's own service sat dead inside it, unreachable, until
    # someone noticed and ran start-nanoclaw.sh by hand.
    #
    # Polls every 10s — cheap, and there's no reason to relaunch faster
    # than a human would notice an outage anyway. `wait "$pid"` reaps the
    # just-exited process before relaunching (it's a genuine child of
    # this script via the `&` above, so this is a real, immediate reap —
    # not a blocking wait on a live process) — without it, a persistent
    # crash loop would accumulate zombies under this script's PID 1 until
    # the container itself was recreated.
    while true; do
        sleep 10
        pid="$(cat nanoclaw.pid 2>/dev/null)"
        if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null
            echo "🔄 [$(date '+%Y-%m-%d %H:%M:%S')] NanoClaw's background process isn't running — relaunching..." >> logs/nanoclaw.log
            nohup node dist/index.js >> logs/nanoclaw.log 2>> logs/nanoclaw.error.log &
            echo $! > nanoclaw.pid
        fi
    done
else
    echo "⏳ NanoClaw isn't installed yet in this container."
    echo "   run.sh hands off to the interactive setup wizard automatically"
    echo "   on first deploy — if you're seeing this some other way, run:"
    echo "   docker exec -it ${CONTAINER_NAME:-nanoclaw} bash -lc 'cd \$NANOCLAW_INSTALL_PATH && bash nanoclaw.sh'"
    # Nothing to watch yet — just keep the container (PID 1) alive and
    # `docker logs -f` working until a manual setup run creates dist/.
    exec tail -F logs/nanoclaw.log
fi
