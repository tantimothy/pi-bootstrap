#!/bin/sh
# browser-lock — cooperative mutex for the ONE shared browser (the sibling
# `browser` environment, reached over CDP by every agent container).
# Installed into the agent image as /usr/local/bin/browser-lock by
# pi-bootstrap's browser-lock patch. ADVISORY: nothing stops a session that
# skips it. Docs: templates/patch-details/browser.md.
#
#   browser-lock acquire   block until the lock is ours (or give up)
#   browser-lock release   free it (only if we still hold it)
#   browser-lock status    print holder/age, or "free"
#
# Env: BROWSER_LOCK_TTL_SECS  (default 600) a lock older than this is reclaimed
#      BROWSER_LOCK_WAIT_SECS (default 120) how long `acquire` polls
#      BROWSER_LOCK_DIR       (default /workspace/agent/.browser-lock.d)
# Lock = a directory (mkdir is atomic). It must live on a mount every
# concurrent session of the group shares; /workspace/agent is that mount.

LOCK_DIR="${BROWSER_LOCK_DIR:-/workspace/agent/.browser-lock.d}"
TTL="${BROWSER_LOCK_TTL_SECS:-600}"
WAIT="${BROWSER_LOCK_WAIT_SECS:-120}"
TOKEN_FILE="${BROWSER_LOCK_TOKEN_FILE:-/tmp/.browser-lock-token}"
HOLDER="$LOCK_DIR/holder.json"

case "$TTL$WAIT" in *[!0-9]*|'') echo "browser-lock: TTL/WAIT must be whole seconds" >&2; exit 2;; esac

now() { date +%s; }
new_token() { echo "$$-$(now)-$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' ')"; }
# Holder file is one line: token=<t> pid=<p> since=<epoch>
field() { sed -n "s/.*$1=\([^ ]*\).*/\1/p" "$HOLDER" 2>/dev/null | head -1; }

lock_age() {
    since=$(field since)
    [ -n "$since" ] || { echo 999999999; return; }
    echo $(( $(now) - since ))
}

try_acquire() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        t=$(new_token)
        echo "token=$t pid=$$ since=$(now)" > "$HOLDER"
        echo "$t" > "$TOKEN_FILE"
        return 0
    fi
    # Held. Reclaim if past TTL, or if the holder file never got written
    # (holder died between mkdir and write) and the dir itself is old.
    age=$(lock_age)
    if [ -f "$HOLDER" ]; then
        [ "$age" -ge "$TTL" ] || return 1
    else
        mt=$(stat -c %Y "$LOCK_DIR" 2>/dev/null || stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0)
        [ $(( $(now) - mt )) -ge 10 ] || return 1
    fi
    # Atomic takeover: whoever renames the stale dir away wins; losers retry mkdir.
    stale="$LOCK_DIR.stale.$$"
    if mv "$LOCK_DIR" "$stale" 2>/dev/null; then
        rm -rf "$stale"
        echo "browser-lock: reclaimed a stale lock (age ${age}s >= TTL ${TTL}s)" >&2
    fi
    return 1
}

cmd="${1:-status}"
case "$cmd" in
    acquire)
        start=$(now)
        while :; do
            if try_acquire; then echo "browser-lock: acquired"; exit 0; fi
            if [ $(( $(now) - start )) -ge "$WAIT" ]; then
                echo "browser-lock: gave up after ${WAIT}s — the shared browser is in use ($(field since | sed 's/^/held since epoch /'))." >&2
                echo "  Do NOT touch the shared browser. Retry later, or use the private 'agent-browser open'." >&2
                exit 1
            fi
            sleep 2
        done
        ;;
    release)
        [ -d "$LOCK_DIR" ] || { echo "browser-lock: already free"; exit 0; }
        mine=$(cat "$TOKEN_FILE" 2>/dev/null)
        if [ -n "$mine" ] && [ "$mine" = "$(field token)" ]; then
            rm -rf "$LOCK_DIR"; rm -f "$TOKEN_FILE"
            echo "browser-lock: released"
        else
            echo "browser-lock: not released — the lock is not ours (reclaimed as stale, or never acquired here)." >&2
            exit 1
        fi
        ;;
    status)
        if [ -d "$LOCK_DIR" ]; then
            echo "browser-lock: held (age $(lock_age)s, ttl ${TTL}s)"
        else
            echo "browser-lock: free"
        fi
        ;;
    *) echo "usage: browser-lock acquire|release|status" >&2; exit 2 ;;
esac
