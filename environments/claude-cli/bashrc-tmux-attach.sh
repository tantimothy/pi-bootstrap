#!/bin/sh
# Sourced by /etc/profile on every login shell (interactive SSH logins only —
# `ssh host some-command` runs a non-login shell and never reaches this file
# at all, so scripted/non-interactive SSH use is unaffected).
#
# Attaches to the persistent "claude" tmux session (creating it on first
# connect), running `claude` in the bind-mounted workspace. tmux is what
# makes this survive a dropped SSH connection and lets a second device
# reconnect straight into the same live conversation instead of starting a
# fresh one — detach with the usual tmux prefix (Ctrl-b d) to leave it
# running, or just close the terminal, same effect.
case "$-" in
    *i*)
        if [ -z "$TMUX" ] && [ -n "$SSH_TTY" ]; then
            exec tmux new-session -A -s claude -c "$HOME/workspace" claude
        fi
        ;;
esac
