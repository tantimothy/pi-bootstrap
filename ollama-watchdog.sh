#!/usr/bin/env bash
# ollama-watchdog.sh — periodically confirms Ollama is actually responsive
# (not just "a process exists"), and restarts it if not.
#
# Built after a real incident: Ollama's process was alive, and even
# `ollama ps` still showed a loaded model, but every chat request from
# Open WebUI hung forever with nothing in either app's logs — only a full
# Ollama restart fixed it. A liveness check that just greps for a running
# process would have missed exactly this, since the process WAS running;
# it's the daemon's own API that had stopped responding, not its existence.
#
# "Isn't launchd/systemd/brew services already doing this?" — no, and the
# distinction is the whole reason this exists. A service supervisor restarts a
# process that EXITED. The incident above had the process very much alive: it
# was the daemon's own HTTP API that had stopped answering, which no KeepAlive
# or Restart= directive can detect. The two are complementary, not redundant —
# the supervisor owns the process lifecycle, this owns API health.
#
# What HAS changed is that this script now drives the supervisor rather than
# fighting it: where Homebrew or systemd manages the daemon, restarts go through
# `brew services` / `systemctl` (see lib/ollama-lib.sh). Before that, a `pkill`
# here was undone by launchd within seconds, which looked exactly like the
# restart having silently failed.
#
# Usage:
#   ./ollama-watchdog.sh              # one-shot: check, restart if unhealthy, exit
#   ./ollama-watchdog.sh --check      # one-shot: check only, never restarts (exit 0/1)
#   ./ollama-watchdog.sh --restart    # force a restart regardless of health
#   ./ollama-watchdog.sh --status     # bind address, schedule, health, listeners
#   ./ollama-watchdog.sh --install    # schedule this to run automatically (launchd/cron)
#   ./ollama-watchdog.sh --uninstall  # remove the scheduled job
#   ./ollama-watchdog.sh --stop       # kill any in-flight run AND unschedule
#
# Env vars (export before invoking; --install bakes the values active at
# install time into the scheduled job, so set them before running --install
# specifically if you want non-default values on every future scheduled run):
#   OLLAMA_HOST               Ollama's own API base, used by THIS SCRIPT to
#                             probe it. Default: http://localhost:11434
#                             NOTE the name collision: `ollama serve` reads
#                             OLLAMA_HOST as its own BIND ADDRESS, a different
#                             meaning entirely. This script never leaks its
#                             probe URL into a server it starts — see
#                             restart_ollama() for why that matters.
#   OLLAMA_SERVE_HOST         Bind address to start `ollama serve` with, e.g.
#                             0.0.0.0:11434. Default: unset (let Ollama use its
#                             own default, 127.0.0.1:11434). Set this if
#                             containers need to reach Ollama via
#                             host.docker.internal — a loopback bind refuses
#                             those connections. Binding 0.0.0.0 also exposes
#                             Ollama to your local network, so it's opt-in.
#   OLLAMA_WATCHDOG_TIMEOUT   Seconds before a health check counts as failed. Default: 10
#   OLLAMA_WATCHDOG_INTERVAL  Seconds between scheduled runs, --install only. Default: 300
#   OLLAMA_WATCHDOG_LOG       Log file path. Default: ~/.ollama-watchdog.log
#   OLLAMA_REBIND_MIN_INTERVAL_MIN
#                             Minutes between attempts to rebind an Ollama that
#                             is responding but not on OLLAMA_SERVE_HOST — a
#                             state a macOS reboot produces on its own, since
#                             `launchctl setenv` does not survive one. Default:
#                             60. Rate-limited because that restart interrupts a
#                             daemon which is, by every other measure, working.
#   OLLAMA_REBIND_STAMP       Where the above records its last attempt.
#                             Default: ~/.ollama-watchdog-rebind.stamp
#
# What this does NOT catch: the health check hits Ollama's lightweight
# /api/tags endpoint (list installed models) — enough to confirm the HTTP
# API itself is alive and responding, which is what actually wedged in the
# incident this was built for. It does NOT run a real generation, so a
# scenario where /api/tags responds fine but the generation engine
# specifically is stuck would not be caught. Deliberate tradeoff: a real
# generate call needs a model already pulled, is slow, and burns resources
# on every check — not worth it for what's meant to run every few minutes.

set -uo pipefail
# Deliberately not "-e": a failed health check is an expected, common
# outcome here (that's the whole point of this script), not a reason to
# abort — every failure path is handled explicitly instead.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Force a UTF-8 locale before any emoji-laden output below prints — see
# lib/locale-lib.sh's own comment for why.
source "$REPO_DIR/lib/locale-lib.sh" || true
# Shared with environments/ollama and nanoclaw-mnemon so all three manage the
# same single native daemon identically. See lib/ollama-lib.sh.
source "$REPO_DIR/lib/ollama-lib.sh"

OS_TYPE="linux"
[[ "$(uname)" == "Darwin" ]] && OS_TYPE="macos"

OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
OLLAMA_SERVE_HOST="${OLLAMA_SERVE_HOST:-}"

# Bind address comes from environments/ollama/.env via the shared resolver —
# that environment owns this daemon's configuration, and this script restarts it
# on a schedule, so a scheduled restart must not revert the operator's binding.
# Resolved here too (not only inside ollama_start) so --status can report it.
ollama_resolve_serve_host

TIMEOUT="${OLLAMA_WATCHDOG_TIMEOUT:-10}"
INTERVAL="${OLLAMA_WATCHDOG_INTERVAL:-300}"
LOG_FILE="${OLLAMA_WATCHDOG_LOG:-$HOME/.ollama-watchdog.log}"

PLIST_LABEL="com.pi-bootstrap.ollama-watchdog"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
CRON_MARKER="# pi-bootstrap ollama-watchdog"

# Version-marked generated file, same convention (and for the same reason) as
# the patch blocks in environments/nanoclaw-mnemon/run.sh: an installed plist is
# written once and then never looked at again, so a fix to its CONTENT reaches
# nobody who already installed it. Bumping this makes the staleness visible —
# see _plist_is_current() — instead of leaving an operator with a schedule that
# is "installed" and quietly missing the fix. Bump it whenever the generated
# plist below changes in a way that matters at runtime.
#   v1  original: label, interval, RunAtLoad, log paths, Ollama env vars
#   v2  PATH (launchd's default omits Homebrew) + AbandonProcessGroup
#       (launchd was killing the daemon the tick started) — 2026-08-24
PLIST_VERSION=2
PLIST_VERSION_MARKER="pi-bootstrap:watchdog-plist v${PLIST_VERSION}"

# PATH for the scheduled job. launchd hands a job /usr/bin:/bin:/usr/sbin:/sbin
# and nothing else — no login shell, no /etc/paths — so `ollama` and `brew` are
# both off-PATH for every scheduled run on a stock Homebrew install. Baked here
# as well as repaired at runtime by lib/ollama-lib.sh's ollama_ensure_path():
# this covers anything the plist runs before that file is sourced, and records
# in the plist itself what the job actually needs.
_watchdog_plist_path() {
    local base="/usr/bin:/bin:/usr/sbin:/sbin" d out="" resolved
    out="$base"
    for resolved in "$(command -v "${OLLAMA_CMD:-ollama}" 2>/dev/null || true)" \
                    "$(command -v brew 2>/dev/null || true)"; do
        [ -n "$resolved" ] || continue
        d="$(dirname "$resolved")"
        case ":${out}:" in *":${d}:"*) ;; *) out="${out}:${d}" ;; esac
    done
    for d in /opt/homebrew/bin /opt/homebrew/sbin /usr/local/bin /usr/local/sbin; do
        [ -d "$d" ] || continue
        case ":${out}:" in *":${d}:"*) ;; *) out="${out}:${d}" ;; esac
    done
    printf '%s' "$out"
}

# Is the installed plist the one this script would write today? Only ever
# reports; rewriting it from here would mean `launchctl unload` on the very job
# this code is running as, which kills the run mid-way.
_plist_is_current() {
    [ -f "$PLIST_PATH" ] || return 1
    grep -qF "$PLIST_VERSION_MARKER" "$PLIST_PATH" 2>/dev/null
}

_warn_if_plist_stale() {
    [ "$OS_TYPE" = "macos" ] || return 0
    [ -f "$PLIST_PATH" ] || return 0
    _plist_is_current && return 0
    _log "⚠️  The scheduled LaunchAgent predates this version of the watchdog and is missing fixes it needs."
    _log "   Re-run: ./deploy.sh → Environments → ollama → 'Watchdog: Schedule Automatic Checks'"
}

_log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

# Real health check: hits Ollama's own API with a hard timeout, not just a
# process-exists grep — see the file header for why that distinction is
# the entire point of this script.
is_healthy() {
    curl -sf -m "$TIMEOUT" "$OLLAMA_HOST/api/tags" >/dev/null 2>&1
}

# Fully delegated to lib/ollama-lib.sh, which owns every platform path
# (Ollama.app, brew services, systemd unit, bare `ollama serve`) for stopping
# and starting. Keeping a second copy here is what let this script drift into
# binding loopback on every restart while the other two callers did not.
restart_ollama() {
    _log "🔄 Restarting Ollama..."
    ollama_stop
    sleep 2
    ollama_start "$OLLAMA_HOST"
}

notify() {
    local msg="$1"
    if [ "$OS_TYPE" = "macos" ] && command -v osascript &>/dev/null; then
        osascript -e "display notification \"$msg\" with title \"Ollama Watchdog\"" 2>/dev/null || true
    elif command -v notify-send &>/dev/null; then
        notify-send "Ollama Watchdog" "$msg" 2>/dev/null || true
    fi
}

# A reboot is the one transition that reliably un-does `launchctl setenv`.
#
# On macOS the bind address reaches a launchd-supervised Ollama (Homebrew's
# service, Ollama.app) only through `launchctl setenv OLLAMA_HOST`, and that is
# SESSION state: it is gone after a restart. So a host that reboots comes back
# with its supervisor dutifully starting Ollama on the default 127.0.0.1:11434,
# no matter what environments/ollama/.env says — and every host-side check
# passes, because they all probe localhost. From a container's point of view
# Ollama did not come back at all; from this script's point of view nothing was
# ever wrong. That gap is the entire reason this function exists rather than
# `is_healthy` simply returning 0 and stopping there.
#
# Rate-limited because it restarts a daemon that is, by every other measure,
# working. One attempt an hour: enough to recover a reboot automatically,
# not enough to thrash if some host-specific reason means it can never be
# satisfied.
OLLAMA_REBIND_STAMP="${OLLAMA_REBIND_STAMP:-$HOME/.ollama-watchdog-rebind.stamp}"
OLLAMA_REBIND_MIN_INTERVAL_MIN="${OLLAMA_REBIND_MIN_INTERVAL_MIN:-60}"

_rebind_attempted_recently() {
    [ -f "$OLLAMA_REBIND_STAMP" ] || return 1
    # `find -mmin` rather than `stat`, for the same BSD/GNU portability reason
    # lib/ollama-lib.sh's maintenance lock uses it.
    [ -n "$(find "$OLLAMA_REBIND_STAMP" -mmin "-${OLLAMA_REBIND_MIN_INTERVAL_MIN}" 2>/dev/null)" ]
}

check_binding_drift() {
    # Nothing configured means nothing to compare against, and a running daemon
    # is left strictly alone — same rule as ollama_start().
    [ -n "${OLLAMA_SERVE_HOST:-}" ] || return 0
    ollama_binding_satisfies_serve_host && return 0
    ollama_maintenance_active && return 0

    if _rebind_attempted_recently; then
        _log "⚠️  Ollama is up but still not bound to ${OLLAMA_SERVE_HOST} — containers are refused."
        _log "   A rebind was already attempted in the last ${OLLAMA_REBIND_MIN_INTERVAL_MIN}m; not retrying this tick."
        return 0
    fi

    _log "⚠️  Ollama is responding, but not on OLLAMA_SERVE_HOST=${OLLAMA_SERVE_HOST} — containers are refused."
    ollama_listeners | sed 's/^/     currently: /' | tee -a "$LOG_FILE"
    # Touched before the attempt, not after: a run that dies mid-restart must
    # still count against the rate limit.
    : > "$OLLAMA_REBIND_STAMP" 2>/dev/null || true
    _log "🔄 Rebinding Ollama..."
    ollama_start "$OLLAMA_HOST"
    sleep 5
    if is_healthy && ollama_binding_satisfies_serve_host; then
        _log "✅ Ollama rebound to ${OLLAMA_SERVE_HOST}"
        ollama_report_binding
        notify "Ollama was bound to the wrong address after a restart — fixed."
    else
        _log "❌ Rebind did not take — Ollama is still not reachable on ${OLLAMA_SERVE_HOST}."
        notify "Ollama is up but containers still can't reach it — check it manually."
    fi
}

do_check_and_restart() {
    if is_healthy; then
        check_binding_drift
        return 0
    fi
    _warn_if_plist_stale
    # A deploy is deliberately holding Ollama down (STOP/TEARDOWN/CLEAN).
    # Restarting here would fight it — potentially starting the daemon while
    # its binary is being removed — and would report a "recovery" that is
    # really interference. The lock expires on its own, so a crashed deploy
    # cannot mute this permanently.
    if ollama_maintenance_active; then
        _log "⏸️  Ollama is down, but a pi-bootstrap deploy holds the maintenance lock — leaving it alone."
        return 0
    fi
    _log "⚠️  Ollama not responding at $OLLAMA_HOST/api/tags within ${TIMEOUT}s"
    notify "Ollama wasn't responding — restarting it now."
    restart_ollama

    # Give it a moment, then confirm the restart actually worked — a
    # restart that silently fails would be worse than the original hang,
    # since a scheduled run gives no other feedback than this log/notify.
    sleep 5
    if is_healthy; then
        _log "✅ Ollama responsive again after restart"
        # "Responsive" is measured at the probe URL, which is localhost — and a
        # loopback-bound daemon passes that on every run while every container
        # is refused. --check and --status already report the real listen
        # address for that reason; this path needs it MORE, not less, because
        # it just restarted the daemon and the restart is the thing most likely
        # to have changed the binding (e.g. handing Ollama off from a service
        # supervisor that was overriding the bind address).
        ollama_report_binding
        # A restart whose whole purpose was the bind address, reporting success
        # on a localhost probe, is a false all-clear. On a scheduled run this
        # log line and the notification are the only feedback there is, so the
        # failure has to reach both — see the note above is_healthy.
        if [ -n "${OLLAMA_SERVE_HOST:-}" ] && ! ollama_binding_satisfies_serve_host; then
            _log "⚠️  ...but NOT on OLLAMA_SERVE_HOST=${OLLAMA_SERVE_HOST} — containers will still be refused."
            notify "Ollama is back up, but not bound to ${OLLAMA_SERVE_HOST} — containers still can't reach it."
        else
            notify "Ollama is back up."
        fi
    else
        _log "❌ Ollama still not responding after restart — needs manual attention"
        notify "Ollama restart didn't help — check it manually."
        return 1
    fi
}

# Writes (or overwrites) the LaunchAgent plist and loads it — unload first
# so a repeat --install (e.g. after changing OLLAMA_WATCHDOG_INTERVAL)
# cleanly replaces the old schedule instead of erroring "already loaded".
install_macos() {
    mkdir -p "$(dirname "$PLIST_PATH")"
    cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- Generated by pi-bootstrap's ollama-watchdog.sh install action. Do not
     hand-edit; a re-install overwrites this file wholesale. Note that an XML
     comment may not contain a double hyphen, so no flag is spelled out here.
     ${PLIST_VERSION_MARKER} -->
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${REPO_DIR}/ollama-watchdog.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>${INTERVAL}</integer>
    <key>RunAtLoad</key>
    <true/>
    <!-- Without this, launchd kills everything left in the job's process group
         when the job exits — including the \`ollama serve\` a tick just started,
         seconds after that tick logged the restart as successful. See the
         matching \`set -m\` in lib/ollama-lib.sh's ollama_start(), which fixes
         the same thing from the daemon's side and, unlike this key, applies
         without re-installing the schedule. -->
    <key>AbandonProcessGroup</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_FILE}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_FILE}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$(_watchdog_plist_path)</string>
        <key>OLLAMA_HOST</key>
        <string>${OLLAMA_HOST}</string>
        <key>OLLAMA_SERVE_HOST</key>
        <string>${OLLAMA_SERVE_HOST}</string>
        <key>OLLAMA_WATCHDOG_TIMEOUT</key>
        <string>${TIMEOUT}</string>
        <key>OLLAMA_WATCHDOG_LOG</key>
        <string>${LOG_FILE}</string>
    </dict>
</dict>
</plist>
EOF
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    launchctl load -w "$PLIST_PATH"
    echo "✅ Installed — runs every ${INTERVAL}s via launchd. Logs: $LOG_FILE"
    echo "   Plist: $PLIST_PATH"
}

uninstall_macos() {
    if [ -f "$PLIST_PATH" ]; then
        launchctl unload "$PLIST_PATH" 2>/dev/null || true
        rm -f "$PLIST_PATH"
        echo "✅ Uninstalled ($PLIST_PATH removed)."
    else
        echo "ℹ️  Not installed — nothing to do."
    fi
}

# cron's finest granularity is whole minutes — unlike launchd's StartInterval
# (raw seconds), a sub-minute OLLAMA_WATCHDOG_INTERVAL on Linux just gets
# rounded up to 1 minute rather than silently doing something else.
install_linux() {
    local cron_minutes=$(( (INTERVAL + 59) / 60 ))
    [ "$cron_minutes" -lt 1 ] && cron_minutes=1
    local cron_line="*/${cron_minutes} * * * * OLLAMA_HOST='${OLLAMA_HOST}' OLLAMA_SERVE_HOST='${OLLAMA_SERVE_HOST}' OLLAMA_WATCHDOG_TIMEOUT='${TIMEOUT}' OLLAMA_WATCHDOG_LOG='${LOG_FILE}' ${REPO_DIR}/ollama-watchdog.sh >> ${LOG_FILE} 2>&1 ${CRON_MARKER}"
    ( crontab -l 2>/dev/null | grep -vF "$CRON_MARKER"; echo "$cron_line" ) | crontab -
    echo "✅ Installed — runs every ${cron_minutes} minute(s) via cron. Logs: $LOG_FILE"
    echo "   Edit with: crontab -e"
}

uninstall_linux() {
    if crontab -l 2>/dev/null | grep -qF "$CRON_MARKER"; then
        crontab -l 2>/dev/null | grep -vF "$CRON_MARKER" | crontab -
        echo "✅ Uninstalled (cron entry removed)."
    else
        echo "ℹ️  Not installed — nothing to do."
    fi
}

# Stops the watchdog outright: kills anything in flight, then removes the
# schedule so it does not simply come back on the next tick.
#
# Both halves are needed. This script is one-shot rather than a daemon — it
# checks, acts, and exits — so most of the time there is no process to kill and
# the schedule IS the watchdog. But a run can be mid-restart when you decide to
# stop it, and on macOS launchd's RunAtLoad fires one immediately at load, so
# killing without unscheduling achieves nothing and unscheduling without
# killing can still leave a restart in progress.
stop_watchdog() {
    local pids
    # Exclude our own PID and our parent's: `pgrep -f` matches the very process
    # running this function, so a naive kill would take out the stop command
    # itself before it ever reached the unschedule below.
    pids=$(pgrep -f 'ollama-watchdog\.sh' 2>/dev/null | grep -v "^$$\$" | grep -v "^${PPID}\$" || true)
    if [ -n "$pids" ]; then
        echo "🛑 Stopping watchdog run(s) already in flight: $(echo $pids | tr '\n' ' ')"
        echo "$pids" | xargs kill 2>/dev/null || true
    else
        echo "ℹ️  No watchdog run currently in flight."
    fi

    if [ "$OS_TYPE" = "macos" ]; then uninstall_macos; else uninstall_linux; fi
    echo "✅ Watchdog stopped. Ollama itself is untouched and still running."
    echo "   Re-enable later with the 'Watchdog: Schedule Automatic Checks' action."
}

case "${1:-}" in
    --check)
        if is_healthy; then
            echo "✅ Ollama is responsive at $OLLAMA_HOST"
            # "Responsive" here means responsive AT THE PROBE URL, which is
            # localhost — and that succeeds whether or not anything in a
            # container can reach it. Reporting the actual listen address
            # alongside it is the difference between a health check and a
            # false all-clear: a loopback-bound daemon passes this check on
            # every run while every containerised consumer is refused. That
            # exact false-clear is what kept `ollama_available: false`
            # misdiagnosed through five rounds — see
            # docs/lessons-learned/nanoclaw-mnemon.md.
            ollama_report_binding
            exit 0
        else
            echo "❌ Ollama is NOT responding at $OLLAMA_HOST within ${TIMEOUT}s"
            exit 1
        fi
        ;;
    --restart)
        restart_ollama
        sleep 5
        is_healthy && { _log "✅ Ollama responsive after manual restart"; exit 0; }
        _log "❌ Ollama still not responding after manual restart"
        exit 1
        ;;
    --install)
        [ "$OS_TYPE" = "macos" ] && install_macos || install_linux
        ;;
    --uninstall)
        [ "$OS_TYPE" = "macos" ] && uninstall_macos || uninstall_linux
        ;;
    --stop)
        stop_watchdog
        ;;
    --status)
        echo "Probe URL:     $OLLAMA_HOST"
        # No apostrophe in this default value: a single quote inside a
        # ${VAR:-word} default is a quoting character to bash even within
        # double quotes, and silently swallows the rest of the file.
        echo "Bind address:  ${OLLAMA_SERVE_HOST:-<unset — Ollama default, 127.0.0.1:11434>}"
        echo "Log file:      $LOG_FILE"
        if [ "$OS_TYPE" = "macos" ]; then
            if [ -f "$PLIST_PATH" ]; then
                echo "Schedule:      installed (launchd, every ${INTERVAL}s)"
                echo "Plist:         $PLIST_PATH"
                if _plist_is_current; then
                    echo "Plist version: ${PLIST_VERSION_MARKER} (current)"
                else
                    echo "Plist version: OUTDATED — predates ${PLIST_VERSION_MARKER}"
                    echo "               Re-run 'Watchdog: Schedule Automatic Checks' to pick up fixes"
                    echo "               the installed job is missing (PATH, AbandonProcessGroup)."
                fi
            else
                echo "Schedule:      NOT installed — use 'Watchdog: Schedule Automatic Checks'"
            fi
        else
            if crontab -l 2>/dev/null | grep -qF "$CRON_MARKER"; then
                echo "Schedule:      installed (cron)"
                crontab -l 2>/dev/null | grep -F "$CRON_MARKER" | sed 's/^/               /'
            else
                echo "Schedule:      NOT installed — use 'Watchdog: Schedule Automatic Checks'"
            fi
        fi
        echo ""
        is_healthy && echo "Health:        ✅ responding" || echo "Health:        ❌ not responding"
        ollama_report_binding
        ;;
    "")
        do_check_and_restart
        ;;
    *)
        echo "Unknown argument: $1" >&2
        echo "Usage: $0 [--check|--restart|--status|--install|--uninstall|--stop]" >&2
        exit 1
        ;;
esac
