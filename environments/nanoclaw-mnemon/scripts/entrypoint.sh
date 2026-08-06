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

# Written fresh on every container start (regenerated, not just created
# once) so it's always accurate even if CONTAINER_NAME/NANOCLAW_INSTALL_PATH
# change across a redeploy. Claude Code auto-reads CLAUDE.md from a
# session's own launch directory — "Open a Claude Session" (info.yaml's
# custom_actions) lands in /root specifically (see that action's own
# comment for why: conversation continuity is scoped to the exact launch
# directory, and /root is where the real, already-in-use admin history
# lives) — so this gives a BRAND NEW admin session basic self-awareness
# immediately, independent of whether it has any prior conversation
# history to draw on. Without this, a fresh session (no history — e.g.
# right after a CLEAN, or the first time this admin session is ever used)
# has no way to know it's running inside this container at all, and will
# say so plainly if asked. Conversation history itself is NOT recreated by
# this file — /root/.claude lives only on the container's own ephemeral
# writable layer (no dedicated named volume), so it doesn't survive CLEAN,
# TEARDOWN+redeploy, or "Choose Claude Model"'s own stop+rm+relaunch. This
# file gives a brand-new session basic self-awareness regardless.
cat > /root/CLAUDE.md <<CLAUDEMD
# Context for the admin \`claude\` session inside this container

You are running inside the **${CONTAINER_NAME:-nanoclaw-mnemon}** orchestrator
container — the \`nanoclaw-mnemon\` environment from the \`pi-bootstrap\` repo
(https://github.com/tantimothy/pi-bootstrap). This container runs
[NanoClaw](https://github.com/nanocoai/nanoclaw) itself (its Telegram/
Discord/etc. channel bot orchestrator, spawning per-conversation-group
agent sandbox containers via the host's Docker socket) with
[mnemon](https://github.com/mnemon-dev/mnemon) patched into those agent
sandboxes for persistent, cross-session graph memory.

- NanoClaw's own source/install path: \`${NANOCLAW_INSTALL_PATH}\` (this
  container's env var \`NANOCLAW_INSTALL_PATH\`) — \`groups/\` holds
  per-conversation-group data, \`data/\` holds sessions/message DB/task
  scheduler state, \`container/\` is the per-group agent sandbox's own
  Dockerfile/entrypoint (where the mnemon patch lands).
- This \`claude\` session itself (the one reading this file) is a separate,
  independent conversation from NanoClaw's own chat-platform one — you are
  not NanoClaw, you're an admin/maintenance session running alongside it in
  the same container, for things like adding channels (\`/add-telegram\`
  etc.), inspecting logs, or debugging.
- \`docker logs -f ${CONTAINER_NAME:-nanoclaw-mnemon}\` (from the HOST, not
  from inside here) shows NanoClaw's own live application log.
- \`${NANOCLAW_INSTALL_PATH}/.pi-bootstrap-patches.md\` — regenerated every
  deploy, lists every host-side patch pi-bootstrap applies on top of
  NanoClaw's own upstream source (mnemon, media/whisper tools, the Ollama
  MCP tool) and each one's current PASSED/SKIPPED/FAILED status. Since
  pi-bootstrap tracks NanoClaw's \`main\` branch rather than a pinned
  commit, an upstream change can occasionally break one of these patches —
  check this file first if a feature it describes seems to be missing or
  broken. If you diagnose or fix something, record it in the sibling
  \`${NANOCLAW_INSTALL_PATH}/.pi-bootstrap-patch-fixes.md\` (never
  overwritten by a deploy) so a human can use it to update pi-bootstrap's
  own patch scripts later.
CLAUDEMD

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

    # Crash-recovery watchdog. Real incident that motivated this: on a
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
    # NanoClaw's own service sat dead inside it — Telegram, and everything
    # else, unreachable — for 3 days until someone noticed and ran
    # start-nanoclaw.sh by hand.
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
    echo "   docker exec -it ${CONTAINER_NAME:-nanoclaw-mnemon} bash -lc 'cd \$NANOCLAW_INSTALL_PATH && bash nanoclaw.sh'"
    # Nothing to watch yet — just keep the container (PID 1) alive and
    # `docker logs -f` working until a manual setup run creates dist/.
    exec tail -F logs/nanoclaw.log
fi
