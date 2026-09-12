#!/bin/sh
# Attach each interactive SSH login to a client-specific session grouped
# with the persistent "pi" base session. Grouping shares windows/history
# while allowing simultaneous clients to view different windows.
case "$-" in
    *i*)
        if [ -z "$TMUX" ] && [ -n "$SSH_TTY" ]; then
            PI_ARGS=""
            [ -n "${PI_MODEL:-}" ] && PI_ARGS="$PI_ARGS --model $PI_MODEL"
            [ -n "${PI_THINKING:-}" ] && PI_ARGS="$PI_ARGS --thinking $PI_THINKING"
            if tmux has-session -t pi 2>/dev/null; then
                exec tmux new-session -t pi -s "client_$$" \; set-option destroy-unattached on
            else
                # -c continues the most recent session for this cwd; a bare
                # `pi` is the fallback for the very first launch, when there
                # is nothing to continue. Same shape as codex-cli's
                # `codex resume --last || codex`.
                exec tmux new-session -s pi -c "$HOME/workspace" sh -c "pi -c $PI_ARGS || pi $PI_ARGS"
            fi
        fi
        ;;
esac
