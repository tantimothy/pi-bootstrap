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
# a different window of the same underlying conversation state. Creates
# the base "claude" session (with `claude --continue` as its first window)
# only the first time ever, or after anything that kills the container's
# tmux server (a restart, STOP/FAST, TEARDOWN/redeploy, CLEAN rebuild);
# every later connection groups onto it instead.
#
# Gated on an explicit `tmux has-session -t claude` check, NOT on whether
# `tmux new-session -t claude -s ...` itself fails — confirmed directly,
# against a real reproduction (in the sibling nanoclaw-mnemon/nanoclaw
# environments, which copied this exact pattern), that it doesn't fail the
# way this used to assume: tmux's `-t` group-session form silently CREATES
# the named group if it doesn't already exist, rather than erroring, so
# the old `... -t claude ... || tmux new-session -s claude ... claude ...`
# pattern never actually fell through to the `claude`-launching branch on
# a truly fresh tmux server — it always "succeeded" at the first command
# instead, leaving a plain shell (no `claude` process at all) as that
# first session's only window. This means every very-first SSH login ever
# (or the first since anything killed the tmux server) would have dropped
# into plain bash instead of `claude` — a real, previously-unverified bug
# in this exact script, only caught once the sibling environments' copies
# were debugged against a live reproduction.
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
#
# Each branch is `exec`'d directly (no need for a trailing `exit`, unlike
# the old failure-fallback version): the `has-session` check up front
# already decided which one to run, so there's no fallback path left that
# would need a live shell to fall through to on failure.
case "$-" in
    *i*)
        if [ -z "$TMUX" ] && [ -n "$SSH_TTY" ]; then
            MODEL_ARGS=""
            [ -n "$CLAUDE_MODEL" ] && MODEL_ARGS="--model $CLAUDE_MODEL"
            if tmux has-session -t claude 2>/dev/null; then
                exec tmux new-session -t claude -s "client_$$" \; set-option destroy-unattached on
            else
                # `claude --continue` exits outright ("No conversation
                # found to continue") rather than falling back to a fresh
                # conversation itself, when there's genuinely nothing to
                # resume yet (e.g. the very first SSH login ever) —
                # confirmed directly against the sibling nanoclaw-mnemon
                # environment's identical mechanism: the whole tmux
                # window/session closed the instant that happened.
                # `--continue` is still tried first, since claude_cli_home
                # is a real persistent volume — most logins after the
                # first genuinely do have a conversation to resume.
                exec tmux new-session -s claude -c "$HOME/workspace" sh -c "claude --continue $MODEL_ARGS || claude $MODEL_ARGS"
            fi
        fi
        ;;
esac
