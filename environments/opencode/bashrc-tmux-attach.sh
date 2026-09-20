#!/bin/sh
# Attach each interactive SSH login to a client-specific session grouped
# with the persistent "opencode" base session. Grouping shares
# windows/history while allowing simultaneous clients to view different
# windows.
case "$-" in
    *i*)
        # Act on an interactive login we own: a plain SSH session, OR a
        # pane spawned by a herdr server running INSIDE this container
        # (reached via `herdr machine add ssh://opencode@host:PORT`). A herdr
        # pane has no SSH_TTY, so the old SSH-only guard skipped it.
        if [ -z "$TMUX" ] && { [ -n "$SSH_TTY" ] || [ "${HERDR_ENV:-}" = "1" ]; }; then
            OC_ARGS=""
            [ -n "${OPENCODE_MODEL:-}" ] && OC_ARGS="$OC_ARGS --model $OPENCODE_MODEL"
            [ -n "${OPENCODE_AGENT:-}" ] && OC_ARGS="$OC_ARGS --agent $OPENCODE_AGENT"
            # OPENCODE_AUTO_APPROVE is deliberately opt-in. --auto approves
            # every permission not explicitly denied, which turns OpenCode's
            # permission system — the main thing distinguishing it from pi's
            # YOLO-by-default posture — off.
            [ "${OPENCODE_AUTO_APPROVE:-}" = "1" ] && OC_ARGS="$OC_ARGS --auto"
            # ─── Inside a Herdr pane: run the agent directly, no tmux ──
            #
            # herdr sets HERDR_ENV=1 and HERDR_PANE_ID on every process it
            # spawns in a pane (src/pane.rs:156,168).
            #
            # This is what makes the blocked/working/idle sidebar work.
            # Herdr identifies an agent from the LOCAL foreground process
            # name (identify_agent_in_job), so it has to see `opencode` —
            # wrapping it in tmux is exactly what hides it, and is why a
            # pane SSH'd in from the host shows no agent at all.
            #
            # Persistence is not lost: the container's own herdr server
            # owns this session and keeps it across disconnects, which is
            # the job tmux does on the plain-SSH path below.
            if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
                cd "$HOME/workspace" 2>/dev/null || true
                exec sh -c "opencode -c $OC_ARGS || opencode $OC_ARGS"
            fi

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
