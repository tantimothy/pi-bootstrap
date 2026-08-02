#!/usr/bin/env bash
# Open a detachable admin session inside the gateway container. Grouped tmux
# sessions let multiple terminals share the same windows and conversation while
# keeping an independent current-window selection per connected terminal.
set -eu

TOOL="${1:-}"
WORKSPACE="/home/node/.openclaw/workspace"

case "$TOOL" in
    claude)
        SESSION="openclaw-claude"
        LAUNCH='claude --continue || claude'
        ;;
    codex)
        SESSION="openclaw-codex"
        LAUNCH='codex'
        ;;
    *)
        echo "Usage: openclaw-cli-tmux claude|codex" >&2
        exit 2
        ;;
esac

if tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux new-session -t "$SESSION" -s "client_${TOOL}_$$" \; set-option destroy-unattached on
else
    tmux new-session -s "$SESSION" -c "$WORKSPACE" sh -lc "$LAUNCH"
fi
