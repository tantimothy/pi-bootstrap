#!/bin/sh
# Sourced by /etc/profile on every login shell (interactive SSH logins only —
# `ssh host some-command` runs a non-login shell and never reaches this file
# at all, so scripted/non-interactive SSH use is unaffected).
#
# Attaches to the persistent "claude" tmux session (creating it on first
# connect), running `claude --continue` in the bind-mounted workspace. tmux
# is what makes this survive a dropped SSH connection and lets a second
# device reconnect straight into the same live conversation instead of
# starting a fresh one — detach with the usual tmux prefix (Ctrl-b d) to
# leave it running, or just close the terminal, same effect.
#
# Same grouped-session pattern as pi-barebones' own .bashrc.tmux (see that
# file's comment for the full explanation), not a plain `-A` attach-or-
# create: `-A` alone forces every simultaneously-connected client to look
# at the exact same window at once — switch windows from one SSH session
# and every other one watching jumps too. The `-t claude -s "client_$$"`
# form instead creates a new session, GROUPED with "claude" (sharing its
# window list and history), giving this one connection its own independent
# current-window pointer — so two SSH sessions in at once can each sit on
# a different window of the same underlying conversation state. Falls
# through to actually creating the base "claude" session (with `claude
# --continue` as its first window) only the first time ever, or after
# anything that kills the container's tmux server (a restart, STOP/FAST,
# TEARDOWN/redeploy, CLEAN rebuild) — the base session's own first attempt
# to group onto itself fails cleanly (2>/dev/null) and falls through to
# creating it instead. Neither branch is `exec`'d directly (unlike the old
# `-A` version) since the fallback needs a live shell to fall through to
# on failure — `exit` at the end instead, so detaching still closes the
# SSH connection either way rather than leaving a bare shell behind.
#
# --continue (not bare `claude`) resumes the most recent conversation in
# ~/workspace if one exists — see README's "How Login Works" for the
# manual `claude --resume` alternative if you want an older one
# specifically instead of just the latest. Only used on the base session's
# very first creation; a client grouping onto an already-running base
# session is just watching/driving that same already-running `claude`
# process, not launching a second one.
#
# CLAUDE_MODEL (see .env.example) — optional, passed as `--model` only on
# that same first-ever base-session creation, for the same reason
# --continue only applies there: once the base session (and the `claude`
# process inside it) already exists, later connections are grouping onto
# it, not relaunching `claude` with different flags. Change CLAUDE_MODEL
# and it takes effect on the next restart (FAST is enough — no rebuild).
case "$-" in
    *i*)
        if [ -z "$TMUX" ] && [ -n "$SSH_TTY" ]; then
            MODEL_ARGS=""
            [ -n "$CLAUDE_MODEL" ] && MODEL_ARGS="--model $CLAUDE_MODEL"
            tmux new-session -t claude -s "client_$$" \; set-option destroy-unattached on 2>/dev/null \
            || tmux new-session -s claude -c "$HOME/workspace" claude --continue $MODEL_ARGS
            exit
        fi
        ;;
esac
