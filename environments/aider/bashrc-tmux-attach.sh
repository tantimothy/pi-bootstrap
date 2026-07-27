#!/bin/sh
# Sourced by /etc/profile on every login shell (interactive SSH logins only
# — `ssh host some-command` runs a non-login shell and never reaches this
# file at all, so scripted/non-interactive SSH use is unaffected).
#
# Identical grouped-session mechanism to claude-cli's own
# bashrc-tmux-attach.sh — see that file's own comment for the full
# explanation of why grouped, not a plain `-A` attach-or-create: `-A` alone
# forces every simultaneously-connected client to look at the exact same
# window at once, where the `-t aider -s "client_$$"` form instead gives
# each connection its own independent current-window pointer onto the same
# shared session. Falls through to actually creating the base "aider"
# session (with `aider` as its first window) only the first time ever, or
# after anything that kills the container's tmux server (a restart,
# STOP/FAST, TEARDOWN/redeploy, CLEAN rebuild).
#
# AIDER_MODEL (see .env.example) — optional, passed as `--model` only on
# that same first-ever base-session creation: once the base session (and
# the `aider` process inside it) already exists, later connections are
# grouping onto it, not relaunching `aider` with different flags. Change
# AIDER_MODEL and it takes effect on the next restart (FAST is enough — no
# rebuild).
case "$-" in
    *i*)
        if [ -z "$TMUX" ] && [ -n "$SSH_TTY" ]; then
            MODEL_ARGS=""
            [ -n "$AIDER_MODEL" ] && MODEL_ARGS="--model $AIDER_MODEL"
            tmux new-session -t aider -s "client_$$" \; set-option destroy-unattached on 2>/dev/null \
            || tmux new-session -s aider -c "$HOME/workspace" aider $MODEL_ARGS
            exit
        fi
        ;;
esac
