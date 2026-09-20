#!/bin/sh
# Attach each interactive SSH login to a client-specific session grouped
# with the persistent "codex" base session. Grouping shares windows/history
# while allowing simultaneous clients to view different windows.
case "$-" in
    *i*)
        # Act on an interactive login we own: a plain SSH session, OR a
        # pane spawned by a herdr server running INSIDE this container
        # (reached via `herdr machine add ssh://codex@host:PORT`). A herdr
        # pane has no SSH_TTY, so the old SSH-only guard skipped it.
        if [ -z "$TMUX" ] && { [ -n "$SSH_TTY" ] || [ "${HERDR_ENV:-}" = "1" ]; }; then
            MODEL_ARGS=""
            [ -n "${CODEX_MODEL:-}" ] && MODEL_ARGS="--model $CODEX_MODEL"
            # ─── Inside a Herdr pane: run the agent directly, no tmux ──
            #
            # herdr sets HERDR_ENV=1 and HERDR_PANE_ID on every process it
            # spawns in a pane (src/pane.rs:156,168).
            #
            # This is what makes the blocked/working/idle sidebar work.
            # Herdr identifies an agent from the LOCAL foreground process
            # name (identify_agent_in_job), so it has to see `codex` —
            # wrapping it in tmux is exactly what hides it, and is why a
            # pane SSH'd in from the host shows no agent at all.
            #
            # Persistence is not lost: the container's own herdr server
            # owns this session and keeps it across disconnects, which is
            # the job tmux does on the plain-SSH path below.
            if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
                cd "$HOME/workspace" 2>/dev/null || true
                exec sh -c "codex resume --last $MODEL_ARGS || codex $MODEL_ARGS"
            fi

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
