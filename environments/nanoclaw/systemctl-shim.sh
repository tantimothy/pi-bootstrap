#!/usr/bin/env bash
# Minimal `systemctl` shim for this container — there's no real systemd
# here (PID 1 is entrypoint.sh, not systemd; hasSystemd() in NanoClaw's
# own setup/platform.ts always returns false), and no `systemctl` binary
# was ever installed either.
#
# NanoClaw's own setup scripts don't know that. Every channel skill's own
# "Restart" step (/add-telegram, /add-discord, /add-whatsapp, etc. — channels
# aren't shipped as standalone setup/add-*.sh scripts anymore, see this
# environment's README's "Adding Channels" section) calls
# `bash setup/lib/restart.sh`, which unconditionally shells out to
# `systemctl --user restart <unit>` on Linux to make the live service pick up
# newly-installed adapter code/tokens, with the failure swallowed by a bare
# `|| true` — verified directly against nanoclaw's source. Without a
# `systemctl` at all, that call was always a silent no-op: the running
# service never actually restarted, so a freshly-installed channel's code
# never loaded, and anything depending on it (e.g. Telegram's own
# pairing-code handshake) hangs forever waiting for a service that's still
# running the pre-install build.
#
# Rather than patch every one of those upstream scripts individually
# (fragile — breaks again on the next nanoclaw update, and misses
# whatever channel gets added next), redirect the two calls that
# actually matter to the exact same start-nanoclaw.sh wrapper run.sh
# already uses for the identical gap in the initial service-start step.
# Everything else best-effort no-ops, matching what a real systemctl
# talking to a nonexistent systemd would already do from these callers'
# point of view (all of them treat failure as non-fatal).
set -u

INSTALL_PATH="${NANOCLAW_INSTALL_PATH:-}"

case "$*" in
    *restart*)
        [ -n "$INSTALL_PATH" ] && [ -f "$INSTALL_PATH/start-nanoclaw.sh" ] || exit 1
        exec bash "$INSTALL_PATH/start-nanoclaw.sh"
        ;;
    *is-active*)
        [ -n "$INSTALL_PATH" ] || exit 3
        pid_file="$INSTALL_PATH/nanoclaw.pid"
        [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null || exit 3
        echo "active"
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
