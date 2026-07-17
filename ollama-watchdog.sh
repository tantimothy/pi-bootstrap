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
#   ./ollama-watchdog.sh --install    # schedule this to run automatically (launchd/cron)
#   ./ollama-watchdog.sh --uninstall  # remove the scheduled job
#
# Env vars (export before invoking; --install bakes the values active at
# install time into the scheduled job, so set them before running --install
# specifically if you want non-default values on every future scheduled run):
#   OLLAMA_HOST               Ollama's own API base. Default: http://localhost:11434
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

OS_TYPE="linux"
[[ "$(uname)" == "Darwin" ]] && OS_TYPE="macos"

OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
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

# macOS: prefer the menu-bar app (killall + reopen) if that's how it's
# running — that's the default install method and what actually owns the
# embedded server process in that case. Linux: prefer the official
# installer's systemd unit. Both fall back to a bare `ollama serve`
# process if neither of those applies.
restart_ollama() {
    if [ "$OS_TYPE" = "macos" ] && pgrep -x "Ollama" >/dev/null 2>&1; then
        _log "🔄 Restarting Ollama.app..."
        killall Ollama 2>/dev/null
        sleep 2
        open -a Ollama
        return
    fi

    if [ "$OS_TYPE" = "linux" ] && systemctl list-unit-files 2>/dev/null | grep -q '^ollama\.service'; then
        _log "🔄 Restarting ollama.service via systemctl..."
        sudo systemctl restart ollama
        return
    fi

    if pgrep -x "ollama" >/dev/null 2>&1; then
        _log "🔄 Restarting bare 'ollama serve' process..."
        pkill -x ollama 2>/dev/null
        sleep 2
    else
        _log "🔄 No existing Ollama process found — starting fresh..."
    fi
    nohup ollama serve >> "$LOG_FILE" 2>&1 &
    disown
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
    local cron_line="*/${cron_minutes} * * * * OLLAMA_HOST='${OLLAMA_HOST}' OLLAMA_WATCHDOG_TIMEOUT='${TIMEOUT}' OLLAMA_WATCHDOG_LOG='${LOG_FILE}' ${REPO_DIR}/ollama-watchdog.sh >> ${LOG_FILE} 2>&1 ${CRON_MARKER}"
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
    "")
        do_check_and_restart
        ;;
    *)
        echo "Unknown argument: $1" >&2
        echo "Usage: $0 [--check|--restart|--install|--uninstall]" >&2
        exit 1
        ;;
esac
