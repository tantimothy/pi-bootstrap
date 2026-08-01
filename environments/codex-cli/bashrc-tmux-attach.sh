#!/bin/sh
# Attach each interactive SSH login to a client-specific session grouped
# with the persistent "codex" base session. Grouping shares windows/history
# while allowing simultaneous clients to view different windows.
case "$-" in
    *i*)
        if [ -z "$TMUX" ] && [ -n "$SSH_TTY" ]; then
            MODEL_ARGS=""
            [ -n "${CODEX_MODEL:-}" ] && MODEL_ARGS="--model $CODEX_MODEL"
            if tmux has-session -t codex 2>/dev/null; then
                exec tmux new-session -t codex -s "client_$$" \; set-option destroy-unattached on
            else
                # Resume the latest conversation for this workspace when one
                # exists; otherwise start a new interactive session.
                exec tmux new-session -s codex -c "$HOME/workspace" sh -c "codex resume --last $MODEL_ARGS || codex $MODEL_ARGS"
            fi
        fi
        ;;
esac
