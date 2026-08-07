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
# Usage:
#   ./ollama-watchdog.sh              # one-shot: check, restart if unhealthy, exit
#   ./ollama-watchdog.sh --check      # one-shot: check only, never restarts (exit 0/1)
#   ./ollama-watchdog.sh --restart    # force a restart regardless of health
#   ./ollama-watchdog.sh --status     # bind address, schedule, health, listeners
#   ./ollama-watchdog.sh --install    # schedule this to run automatically (launchd/cron)
#   ./ollama-watchdog.sh --uninstall  # remove the scheduled job
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

# The `ollama` environment owns this daemon's configuration, and this script
# restarts it on a schedule — so without reading that config, a scheduled
# restart would quietly revert the operator's bind address, which is exactly
# what happened before. Read with grep rather than `source`: this is a
# root-level script and .env is not ours to execute. Anything already exported
# wins, so an explicit value on the command line still overrides the file.
_OLLAMA_ENV_FILE="$REPO_DIR/environments/ollama/.env"
if [ -z "$OLLAMA_SERVE_HOST" ] && [ -f "$_OLLAMA_ENV_FILE" ]; then
    OLLAMA_SERVE_HOST="$(grep -E '^[[:space:]]*OLLAMA_SERVE_HOST=' "$_OLLAMA_ENV_FILE" 2>/dev/null \
        | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
    OLLAMA_SERVE_HOST="${OLLAMA_SERVE_HOST:-}"
fi
TIMEOUT="${OLLAMA_WATCHDOG_TIMEOUT:-10}"
INTERVAL="${OLLAMA_WATCHDOG_INTERVAL:-300}"
LOG_FILE="${OLLAMA_WATCHDOG_LOG:-$HOME/.ollama-watchdog.log}"

PLIST_LABEL="com.pi-bootstrap.ollama-watchdog"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
CRON_MARKER="# pi-bootstrap ollama-watchdog"

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

do_check_and_restart() {
    if is_healthy; then
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
        notify "Ollama is back up."
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
    <key>StandardOutPath</key>
    <string>${LOG_FILE}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_FILE}</string>
    <key>EnvironmentVariables</key>
    <dict>
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

case "${1:-}" in
    --check)
        if is_healthy; then
            echo "✅ Ollama is responsive at $OLLAMA_HOST"
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
        echo "Usage: $0 [--check|--restart|--status|--install|--uninstall]" >&2
        exit 1
        ;;
esac
