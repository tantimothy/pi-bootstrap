#!/usr/bin/env bash
# ---------------------------------------------------------------------------------------
# Shared lifecycle for the ONE native Ollama daemon this repo manages.
#
# Ollama is not containerized here — it's a single native process on the host,
# on port 11434, shared by every AI environment in this repo (nanoclaw-mnemon's
# mnemon embeddings and Ollama MCP tool, chat-frontends, llm-gateways). But
# three separate things could start it, each with their own copy of the logic:
#
#     environments/ollama/run.sh              the environment that owns it
#     environments/nanoclaw-mnemon/run.sh     ensure_ollama_ready(), if it finds
#                                             nothing answering
#     ollama-watchdog.sh                      restart-on-unhealthy
#
# Three implementations of "start Ollama" meant three chances to start it
# differently, and that is not theoretical: a real host ended up running TWO
# ollama processes at once — one bound to *:11434 over IPv6 and one to
# 127.0.0.1:11434 over IPv4 — with containers still refused, because they
# connect over IPv4 and the only IPv4 listener was the loopback one. This file
# exists so there is exactly one implementation for all three to call.
#
# Two rules it enforces that each caller previously got wrong:
#
#   1. **Starting is idempotent.** ollama_start() returns immediately if the
#      daemon already answers. That is what prevents a second process, which is
#      how the duplicate above happened.
#   2. **OLLAMA_HOST never leaks into `ollama serve`.** The name means two
#      different things: to a client it is the URL to talk to, to the server it
#      is the address to BIND. Callers source .env with `set -a`, so a probe URL
#      of http://localhost:11434 would otherwise become the bind address — which
#      is exactly how ollama-watchdog.sh silently forced loopback on every
#      restart. The bind address comes only from OLLAMA_SERVE_HOST; otherwise
#      OLLAMA_HOST is stripped so Ollama uses its own default.
# ---------------------------------------------------------------------------------------

OLLAMA_PORT="${OLLAMA_PORT:-11434}"

# Derived from this file's own location rather than trusting a caller to have
# set REPO_DIR — this is sourced by scripts at the repo root and by environment
# run.sh files two levels down.
_OLLAMA_LIB_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------------------------------
# PATH repair — because the most important caller of this file does not run
# from a login shell.
#
# ollama-watchdog.sh's whole reason to exist is the scheduled run, and on macOS
# that run is a launchd LaunchAgent. launchd does NOT source a shell profile and
# does not consult /etc/paths: a job with no explicit PATH gets exactly
# /usr/bin:/bin:/usr/sbin:/sbin. Homebrew installs `ollama` and `brew` to
# /opt/homebrew/bin (Apple Silicon) or /usr/local/bin (Intel), and NEITHER is on
# that list.
#
# The consequence was invisible for as long as Ollama stayed up, because a
# healthy check returns before any of this is reached. It only bites at the one
# moment the watchdog is supposed to earn its keep — a reboot, where the daemon
# really is down. There, under launchd:
#   `command -v brew`   fails  -> _ollama_brew_service() says "not a brew service"
#   `command -v ollama` fails  -> the bare `ollama serve` fallback below is
#                                 "command not found", logged to a file nobody
#                                 reads, and Ollama simply never comes back.
# Run the exact same script from Terminal and it works perfectly, which is what
# makes this so easy to miss.
#
# Appended, never prepended: an operator who deliberately put a different
# `ollama` earlier on PATH keeps it, and OLLAMA_CMD still overrides everything.
# ---------------------------------------------------------------------------------------
ollama_ensure_path() {
    local d
    for d in /opt/homebrew/bin /opt/homebrew/sbin /usr/local/bin /usr/local/sbin; do
        [ -d "$d" ] || continue
        case ":${PATH}:" in
            *":${d}:"*) ;;
            *) PATH="${PATH}:${d}" ;;
        esac
    done
    export PATH
}
# Done at source time rather than left to each caller: every function below that
# shells out to `brew`, `ollama` or `pkill` depends on it, and a caller that
# forgets gets the silent launchd failure above rather than an error.
ollama_ensure_path

# ONE source of truth for the bind address: environments/ollama/.env.
#
# That environment owns the daemon's lifecycle, so its .env owns the daemon's
# configuration. The alternative — each caller keeping its own copy — is how
# configuration drifts apart, and drift between things managing one daemon is
# the entire reason this library exists. A nanoclaw-mnemon deploy that starts
# Ollama must not bind it differently from the way the ollama environment
# would, and neither must the watchdog's scheduled restart.
#
# Read with grep rather than `source`: callers include a root-level script, and
# executing another environment's .env to pull one value is a much larger
# action than reading one. Anything already set wins, so an explicit
# OLLAMA_SERVE_HOST on the command line still overrides the file.
ollama_resolve_serve_host() {
    local f="${_OLLAMA_LIB_REPO_DIR}/environments/ollama/.env"
    [ -n "${OLLAMA_SERVE_HOST:-}" ] && return 0
    OLLAMA_SERVE_HOST=""
    [ -f "$f" ] || return 0
    OLLAMA_SERVE_HOST="$(grep -E '^[[:space:]]*OLLAMA_SERVE_HOST=' "$f" 2>/dev/null \
        | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
    OLLAMA_SERVE_HOST="${OLLAMA_SERVE_HOST:-}"
}

# ---------------------------------------------------------------------------------------
# Maintenance lock — keeps the scheduled watchdog out of a deploy's way.
#
# The `ollama` environment's STOP/TEARDOWN/CLEAN policies all stop the daemon
# on purpose, and a CLEAN then uninstalls and reinstalls it. The watchdog runs
# on its own schedule (every 5 minutes by default) and exists precisely to
# restart a daemon that is not answering — so a tick landing inside that window
# sees exactly what it is built to fix and "fixes" it: restarting Ollama in the
# middle of its own teardown, potentially while the binary is being removed,
# and firing a spurious "Ollama is back up" notification.
#
# Nothing coordinated the two. This is the same three-managers-of-one-daemon
# problem this library exists for, except across time rather than across code.
#
# The lock goes stale on its own: a deploy that crashes without cleaning up
# must not disable the watchdog forever, which would be a far worse failure
# than the race it prevents. `find -mmin` is used for the age check because it
# behaves the same on BSD/macOS and GNU, unlike `stat`.
# ---------------------------------------------------------------------------------------
OLLAMA_MAINTENANCE_LOCK="${OLLAMA_MAINTENANCE_LOCK:-$HOME/.pi-bootstrap-ollama-maintenance.lock}"
OLLAMA_MAINTENANCE_MAX_AGE_MIN="${OLLAMA_MAINTENANCE_MAX_AGE_MIN:-30}"

ollama_begin_maintenance() {
    printf '%s pid=%s\n' "${1:-maintenance}" "$$" > "$OLLAMA_MAINTENANCE_LOCK" 2>/dev/null || true
}

ollama_end_maintenance() {
    rm -f "$OLLAMA_MAINTENANCE_LOCK" 2>/dev/null || true
}

ollama_maintenance_active() {
    [ -f "$OLLAMA_MAINTENANCE_LOCK" ] || return 1
    # Present but older than the cutoff: treat as abandoned and clear it, so a
    # crashed deploy self-heals rather than silently muting the watchdog.
    if [ -z "$(find "$OLLAMA_MAINTENANCE_LOCK" -mmin "-${OLLAMA_MAINTENANCE_MAX_AGE_MIN}" 2>/dev/null)" ]; then
        ollama_end_maintenance
        return 1
    fi
    return 0
}

# Address of every listener on Ollama's port, one per line, empty if none.
# lsof on macOS, ss on modern Linux, netstat as a last resort — if none of the
# three exists we return nothing rather than guessing, since a false claim here
# would send someone chasing a problem that isn't there.
ollama_listeners() {
    if command -v lsof >/dev/null 2>&1; then
        # Pick the field holding the address, NOT $NF: lsof's NAME column is
        # "TCP 127.0.0.1:11434 (LISTEN)" — three whitespace-separated fields —
        # so $NF is "(LISTEN)" and every address test downstream silently
        # passes. That exact bug shipped once and was caught only by running it
        # against real lsof output.
        lsof -nP -iTCP:"$OLLAMA_PORT" -sTCP:LISTEN 2>/dev/null \
            | awk -v p="[.:]${OLLAMA_PORT}$" 'NR>1 { for (i = 1; i <= NF; i++) if ($i ~ p) print $i }'
    elif command -v ss >/dev/null 2>&1; then
        ss -ltnH 2>/dev/null | awk '{print $4}' | grep ":${OLLAMA_PORT}$" || true
    elif command -v netstat >/dev/null 2>&1; then
        netstat -an 2>/dev/null | awk '/LISTEN/ {print $4}' | grep "[.:]${OLLAMA_PORT}$" || true
    fi
}

# Called once per listener address, from inside loops in both callers below.
# A `case` rather than the `printf | grep -q` this replaces: same four
# prefixes, but as a builtin it costs no subshell and no process per address.
_ollama_is_loopback() {
    case "$1" in
        127.0.0.1*|'[::1]'*|::1*|localhost*) return 0 ;;
    esac
    return 1
}

# Prints what Ollama is actually listening on, and warns about the two states
# that break containerized consumers while every host-side check still passes.
ollama_report_binding() {
    local listeners loopback=0 wide=0 addr
    listeners="$(ollama_listeners)"
    [ -z "$listeners" ] && return 0

    while IFS= read -r addr; do
        [ -z "$addr" ] && continue
        if _ollama_is_loopback "$addr"; then loopback=$((loopback + 1)); else wide=$((wide + 1)); fi
    done <<OLLAMA_LISTENERS
$listeners
OLLAMA_LISTENERS

    echo "🔌 Ollama is listening on:"
    printf '%s\n' "$listeners" | sed 's/^/     /'

    if [ "$loopback" -gt 0 ] && [ "$wide" -gt 0 ]; then
        echo "" >&2
        echo "⚠️  Both a loopback and a non-loopback listener are present — more than one" >&2
        echo "   Ollama process is running. Containers may still be refused: a wide IPv6" >&2
        echo "   listener does not help one dialling IPv4." >&2
        echo "   Fix: pkill -x ollama, then redeploy the 'ollama' environment." >&2
        echo "" >&2
        return 0
    fi
    [ "$wide" -gt 0 ] && return 0

    echo "" >&2
    echo "⚠️  Loopback only — this host reaches Ollama, containers cannot." >&2
    echo "   Traffic arriving via host.docker.internal:${OLLAMA_PORT} is external as far as a" >&2
    echo "   loopback listener is concerned, and is refused. Symptoms: mnemon reporting" >&2
    echo "   'ollama_available: false', agent-side Ollama tools failing — with nothing" >&2
    echo "   failing on this side to point at the cause." >&2
    echo "   Fix: set OLLAMA_SERVE_HOST=0.0.0.0:${OLLAMA_PORT} in the 'ollama' environment's" >&2
    echo "   .env and redeploy it. Note that also exposes Ollama to your local network." >&2
    echo "" >&2
}

# True when the current listeners actually satisfy OLLAMA_SERVE_HOST: at least
# one non-loopback listener and no loopback one. A loopback listener alongside a
# wide one means two daemons, which does not count as satisfied — containers can
# still be refused depending on address family.
ollama_binding_satisfies_serve_host() {
    local listeners addr loopback=0 wide=0
    listeners="$(ollama_listeners)"
    [ -z "$listeners" ] && return 1
    while IFS= read -r addr; do
        [ -z "$addr" ] && continue
        if _ollama_is_loopback "$addr"; then loopback=$((loopback + 1)); else wide=$((wide + 1)); fi
    done <<OLLAMA_SATISFY
$listeners
OLLAMA_SATISFY
    [ "$wide" -gt 0 ] && [ "$loopback" -eq 0 ]
}

# The host's real LAN address. Needed because `host.docker.internal` is not
# dependably a working route to the host: on one real OrbStack install it
# resolved to an address that REFUSED connections, while the Mac itself sat on
# a different address on that bridge and the LAN address worked fine from
# inside containers. lib/info-lib.sh's own HOST_IP logic is Linux-only
# (`ip route`, `hostname -I`), so macOS gets its own path here.
ollama_host_lan_ip() {
    local ip="" iface=""
    if [[ "$(uname)" == "Darwin" ]]; then
        iface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')
        [ -n "$iface" ] && ip=$(ipconfig getifaddr "$iface" 2>/dev/null || true)
    else
        ip=$( { ip route get 1.1.1.1 2>/dev/null || true; } \
            | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i+1); exit}}')
        [ -z "$ip" ] && ip=$( { hostname -I 2>/dev/null || true; } | awk '{print $1}')
    fi
    printf '%s' "$ip"
}

# Can a CONTAINER reach this endpoint directly? This is the question every
# host-side check structurally cannot answer, and not asking it is what let a
# real install spend days on `ollama_available: false`: the daemon was running,
# the host could reach it, every probe passed — and no container could reach it
# at all, because `host.docker.internal` pointed somewhere that refused.
#
# --noproxy '*' is essential. A host-side HTTP proxy can reach the daemon over
# loopback and will happily return 200 for a container that has no direct route
# whatsoever, which is exactly the false success that made this take so long.
#
# Returns: 0 reachable, 1 not reachable, 2 could not test (no usable image).
ollama_reachable_from_container() {
    local endpoint="$1" image="$2"
    [ -z "$endpoint" ] && return 2
    [ -z "$image" ] && return 2
    [ -z "$($DOCKER images -q "$image" 2>/dev/null)" ] && return 2
    if $DOCKER run --rm --entrypoint sh "$image" -c \
        "curl -fsS --max-time 5 --noproxy '*' '${endpoint}/api/tags' >/dev/null 2>&1" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

ollama_healthy() {
    curl -fsS --max-time "${OLLAMA_PROBE_TIMEOUT:-5}" "${1}/api/tags" >/dev/null 2>&1
}

ollama_installed() {
    command -v "${OLLAMA_CMD:-ollama}" >/dev/null 2>&1
}

# Starts the daemon, or does nothing if it already answers.
#
# $1 = probe URL (e.g. http://localhost:11434) so the idempotency check can
#      confirm "already running" before starting anything.
#
# The no-op-when-healthy check is the whole anti-duplicate guard: every caller
# used to decide independently whether to start, and two of them deciding yes
# at once is how a host ends up with two daemons fighting over one port.
ollama_start() {
    local probe_url="${1:-http://localhost:${OLLAMA_PORT}}"
    local cmd="${OLLAMA_CMD:-ollama}"

    # Every caller gets the same bind address without having to know where it
    # lives, and without keeping its own copy of it.
    ollama_resolve_serve_host

    if ollama_healthy "$probe_url"; then
        # Already running — but "running" is not the same as "running the way
        # this host is configured to run it". The no-op-when-healthy guard
        # above exists to stop a second daemon appearing, and on its own it
        # also meant an already-running daemon could never be REBOUND: a deploy
        # with OLLAMA_SERVE_HOST=0.0.0.0:11434 would find loopback-bound Ollama
        # answering, return immediately, and report the loopback warning
        # forever without ever fixing it. Confirmed on a live host, where the
        # setting was correct and every redeploy still left it on 127.0.0.1.
        #
        # So: if a bind address is configured and the current listeners do not
        # satisfy it, restart into the right one. With no OLLAMA_SERVE_HOST set
        # there is nothing to compare against and a running daemon is left
        # strictly alone.
        if [ -z "${OLLAMA_SERVE_HOST:-}" ] || ollama_binding_satisfies_serve_host; then
            return 0
        fi
        echo "♻️  Ollama is running, but not bound as configured (OLLAMA_SERVE_HOST=${OLLAMA_SERVE_HOST})."
        ollama_listeners | sed 's/^/     currently: /'
        echo "   Restarting it so the configured bind address takes effect..."
        ollama_stop
        sleep 2
    fi

    if [ -n "${OLLAMA_SERVE_HOST:-}" ]; then
        # brew services and Ollama.app both launch via launchd, which does not
        # inherit this shell's environment — launchctl's session environment is
        # the only supported way to reach them. This is Ollama's own documented
        # macOS procedure. It is session-wide, hence announced rather than silent.
        if [[ "$(uname)" == "Darwin" ]]; then
            echo "🔧 Setting OLLAMA_HOST=${OLLAMA_SERVE_HOST} in the launchd session so Ollama binds there."
            launchctl setenv OLLAMA_HOST "$OLLAMA_SERVE_HOST" 2>/dev/null || true
        fi
    fi

    case "$(uname -s)" in
        Darwin)
            # Same correction as ollama_stop: ask whether a brew SERVICE
            # exists, not whether `brew list` recognizes the name. Starting a
            # bare `ollama serve` beside a launchd-managed one is how a host
            # ends up with two daemons — the supervised one on loopback, ours
            # bound wide, and containers still refused because they dial the
            # loopback one.
            if _ollama_brew_service; then
                brew services start ollama >/dev/null 2>&1
                ollama_wait_healthy "$probe_url" 10 >/dev/null 2>&1 || true

                # Supervised start is preferred — launchd restarts the daemon if
                # it dies, and nothing here does. But Homebrew's service
                # definition carries its own EnvironmentVariables, which beat
                # `launchctl setenv`, so on some formula versions the bind
                # address is simply not ours to set: confirmed on a real host
                # where `launchctl setenv OLLAMA_HOST 0.0.0.0:11434` followed by
                # `brew services start ollama` still came up on 127.0.0.1.
                #
                # Editing the generated plist is not a fix either — `brew
                # services start` regenerates it from the formula every time, so
                # the edit would be silently reverted on the next start. Exactly
                # the stale-patch failure mode this repo keeps running into.
                #
                # So verify rather than assume, and only take the daemon out of
                # supervision if supervision actually cannot honor the
                # configuration. A host whose formula doesn't pin OLLAMA_HOST
                # keeps launchd's restart-on-crash for free.
                if [ -z "${OLLAMA_SERVE_HOST:-}" ] || ollama_binding_satisfies_serve_host; then
                    return 0
                fi

                echo "⚠️  Homebrew's service definition overrides the bind address — it started Ollama on:" >&2
                ollama_listeners | sed 's/^/       /' >&2
                echo "   OLLAMA_SERVE_HOST=${OLLAMA_SERVE_HOST} cannot be applied through 'brew services'," >&2
                echo "   and hand-editing the generated plist is undone the next time brew regenerates it." >&2
                echo "   Taking Ollama out of brew's supervision and running it directly instead." >&2
                echo "   Restart-on-crash is then covered by ollama-watchdog.sh — schedule it via the" >&2
                echo "   'Watchdog: Schedule Automatic Checks' action if you have not already." >&2
                echo "   To hand it back to Homebrew later: unset OLLAMA_SERVE_HOST, then 'brew services start ollama'." >&2
                brew services stop ollama >/dev/null 2>&1 || true
                pkill -x ollama 2>/dev/null || true
                sleep 2
                # falls through to the bare `ollama serve` below, which does
                # control its own environment
            elif [ -d "/Applications/Ollama.app" ]; then
                open -a Ollama && return 0
            fi
            ;;
        Linux)
            if command -v systemctl >/dev/null 2>&1 &&
               systemctl list-unit-files 2>/dev/null | grep -q '^ollama\.service'; then
                # Unlike Homebrew, systemd HAS a supported override that
                # survives package upgrades: a drop-in. So on a Pi the bind
                # address is applied properly rather than falling back to an
                # unsupervised daemon — the unit keeps restart-on-crash, and
                # this file is rewritten from the current value on every deploy,
                # so it cannot go stale the way a hand-edit would.
                if [ -n "${OLLAMA_SERVE_HOST:-}" ]; then
                    if sudo mkdir -p /etc/systemd/system/ollama.service.d 2>/dev/null &&
                       printf '# Managed by pi-bootstrap — rewritten on every deploy.\n[Service]\nEnvironment="OLLAMA_HOST=%s"\n' \
                            "$OLLAMA_SERVE_HOST" \
                            | sudo tee /etc/systemd/system/ollama.service.d/pi-bootstrap-bind.conf >/dev/null 2>&1; then
                        sudo systemctl daemon-reload 2>/dev/null || true
                        echo "🔧 Applied OLLAMA_HOST=${OLLAMA_SERVE_HOST} via a systemd drop-in (ollama.service.d/pi-bootstrap-bind.conf)."
                    else
                        echo "⚠️  Couldn't write the systemd drop-in for OLLAMA_HOST — is sudo available?" >&2
                        echo "   Apply it by hand:  sudo systemctl edit ollama" >&2
                        echo "   adding:            Environment=\"OLLAMA_HOST=${OLLAMA_SERVE_HOST}\"" >&2
                    fi
                fi
                sudo systemctl enable --now ollama >/dev/null 2>&1 || true
                ollama_wait_healthy "$probe_url" 10 >/dev/null 2>&1 || true

                # Same verify-then-fall-back shape as the macOS branch above:
                # supervision is preferred, but only if it can actually honor
                # the configured binding.
                if [ -z "${OLLAMA_SERVE_HOST:-}" ] || ollama_binding_satisfies_serve_host; then
                    return 0
                fi
                echo "⚠️  ollama.service started, but not on the configured bind address:" >&2
                ollama_listeners | sed 's/^/       /' >&2
                echo "   Running Ollama directly instead; ollama-watchdog.sh covers restarts." >&2
                sudo systemctl stop ollama 2>/dev/null || true
                pkill -x ollama 2>/dev/null || true
                sleep 2
                # falls through to the bare `ollama serve` below
            fi
            ;;
    esac

    # Bare `ollama serve` — the one path where this shell's environment is
    # inherited directly, so it is the one that must be scrubbed. See this
    # file's header for why leaking OLLAMA_HOST here is a real bug and not a
    # theoretical one.
    #
    # `set -m` is load-bearing, not tidiness. When this runs from the watchdog's
    # LaunchAgent, launchd kills every surviving process in the JOB'S PROCESS
    # GROUP the moment the job's main process exits — and `nohup` + `&` +
    # `disown` do not change a process group. nohup only ignores SIGHUP,
    # `disown` only edits this shell's job table; the daemon inherits the
    # script's PGID either way and launchd SIGKILLs it seconds later.
    #
    # That produced the worst possible shape of failure: the watchdog started
    # Ollama, waited 5s, confirmed it healthy, logged "✅ Ollama responsive
    # again after restart" — and then died, taking Ollama with it. A log full of
    # successful restarts, and a daemon that was never up for more than a few
    # seconds after each one. Every five minutes, indefinitely.
    #
    # Turning on job control makes bash put each background job in its OWN
    # process group, which puts the daemon outside the one launchd sweeps. It
    # needs no controlling terminal, so it is safe in a non-interactive script,
    # and it is scoped tightly around the launch so nothing else inherits job
    # control. stdin comes from /dev/null because a process in a different
    # process group that reads the terminal takes SIGTTIN.
    #
    # The plist written by ollama-watchdog.sh --install also sets
    # AbandonProcessGroup, which fixes this from the other side. Both are here
    # deliberately: the plist only helps once an operator re-runs --install,
    # whereas this reaches an already-scheduled job on the next tick.
    set -m
    if [ -n "${OLLAMA_SERVE_HOST:-}" ]; then
        OLLAMA_HOST="$OLLAMA_SERVE_HOST" nohup "$cmd" serve </dev/null >> "${OLLAMA_SERVE_LOG:-$HOME/.ollama-server.log}" 2>&1 &
    else
        env -u OLLAMA_HOST nohup "$cmd" serve </dev/null >> "${OLLAMA_SERVE_LOG:-$HOME/.ollama-server.log}" 2>&1 &
    fi
    disown 2>/dev/null || true
    set +m
}

# Waits up to $2 seconds (default 15) for the daemon to answer at $1.
ollama_wait_healthy() {
    local probe_url="${1:-http://localhost:${OLLAMA_PORT}}" limit="${2:-15}" tries=0
    while [ "$tries" -lt "$limit" ]; do
        ollama_healthy "$probe_url" && return 0
        sleep 1
        tries=$((tries + 1))
    done
    ollama_healthy "$probe_url"
}

# Stops whichever way it's running. Tries every mechanism rather than guessing
# one, because the thing that started it may not be the thing calling this.
# Is Ollama registered as a Homebrew *service*? This is the question that
# matters, and `brew list ollama` is not it — that check fails for a CASK
# install even when Homebrew is very much managing the daemon. A real host hit
# exactly that: `command -v ollama` resolved to /opt/homebrew/bin/ollama, yet
# every brew-aware branch was skipped, so `brew services stop` never ran, the
# launchd job stayed loaded, and Ollama respawned within two seconds of every
# `pkill` — loopback-bound, forever. `brew services list` covers formula and
# cask alike.
_ollama_brew_service() {
    command -v brew >/dev/null 2>&1 || return 1
    brew services list 2>/dev/null | awk 'NR > 1 && $1 == "ollama" { found = 1 } END { exit !found }'
}

ollama_stop() {
    if [[ "$(uname)" == "Darwin" ]]; then
        # Unload the launchd job FIRST. Killing the process while its service
        # is still loaded just invites launchd to start it straight back up,
        # which is indistinguishable from the stop having silently failed.
        _ollama_brew_service && { brew services stop ollama >/dev/null 2>&1 || true; }
        pgrep -x "Ollama" >/dev/null 2>&1 && { killall Ollama 2>/dev/null || true; }
    elif command -v systemctl >/dev/null 2>&1 &&
         systemctl list-unit-files 2>/dev/null | grep -q '^ollama\.service'; then
        sudo systemctl stop ollama 2>/dev/null || true
    fi
    pkill -x ollama 2>/dev/null || true

    # Verify it actually stayed down. A supervisor we did not recognize will
    # respawn it within a second or two, and every caller of this function then
    # proceeds on the false premise that the port is free — starting a second
    # daemon beside the first rather than replacing it. Saying so here turns a
    # silent respawn into a visible one.
    sleep 2
    # Captured once rather than probed twice: ollama_listeners shells out to
    # lsof/ss/netstat plus awk, and re-running it to print what the test just
    # found would also mean the message could describe a different set of
    # listeners than the one that triggered it.
    local still_listening; still_listening="$(ollama_listeners)"
    if [ -n "$still_listening" ]; then
        echo "⚠️  Ollama is still listening after being stopped — something is supervising and restarting it:" >&2
        printf '%s\n' "$still_listening" | sed 's/^/       /' >&2
        echo "   Starting another one now would leave TWO daemons on this port, which is worse" >&2
        echo "   than the original problem. Find the supervisor before continuing:" >&2
        echo "     brew services list | grep -i ollama" >&2
        echo "     launchctl list | grep -i ollama" >&2
        echo "     ps -o pid,ppid,command -p \$(pgrep -x ollama | head -1)" >&2
        return 1
    fi
    return 0
}
