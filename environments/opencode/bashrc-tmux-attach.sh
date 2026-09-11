#!/bin/sh
# Attach each interactive SSH login to a client-specific session grouped
# with the persistent "opencode" base session. Grouping shares
# windows/history while allowing simultaneous clients to view different
# windows.
case "$-" in
    *i*)
        if [ -z "$TMUX" ] && [ -n "$SSH_TTY" ]; then
            OC_ARGS=""
            [ -n "${OPENCODE_MODEL:-}" ] && OC_ARGS="$OC_ARGS --model $OPENCODE_MODEL"
            [ -n "${OPENCODE_AGENT:-}" ] && OC_ARGS="$OC_ARGS --agent $OPENCODE_AGENT"
            # OPENCODE_AUTO_APPROVE is deliberately opt-in. --auto approves
            # every permission not explicitly denied, which turns OpenCode's
            # permission system — the main thing distinguishing it from pi's
            # YOLO-by-default posture — off.
            [ "${OPENCODE_AUTO_APPROVE:-}" = "1" ] && OC_ARGS="$OC_ARGS --auto"
            if tmux has-session -t opencode 2>/dev/null; then
                exec tmux new-session -t opencode -s "client_$$" \; set-option destroy-unattached on
            else
                # -c continues the last session; a bare invocation is the
                # fallback for the very first launch, when there is nothing
                # to continue. Same shape as codex-cli and pi.
                exec tmux new-session -s opencode -c "$HOME/workspace" sh -c "opencode -c $OC_ARGS || opencode $OC_ARGS"
            fi
        fi
        ;;
esac
