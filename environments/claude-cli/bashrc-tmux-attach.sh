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
# --continue (not bare `claude`) only matters for the OTHER case: no live
# tmux session to attach to at all — `-A` skips re-running this command
# entirely when one already exists, so this only fires on the very first
# connection ever, or after anything that kills the container's processes
# (a restart, STOP/FAST, TEARDOWN/redeploy, CLEAN rebuild). tmux itself
# doesn't survive that even though ~/.claude (session history, OAuth state)
# does, since it's a named volume — without --continue, that gap meant every
# restart silently dropped you into a brand-new conversation instead of
# picking the real one back up. `claude --continue` resumes the most recent
# conversation in ~/workspace if one exists; see README's "How Login Works"
# for the manual `claude --resume` alternative if you want an older one
# specifically instead of just the latest.
case "$-" in
    *i*)
        if [ -z "$TMUX" ] && [ -n "$SSH_TTY" ]; then
            exec tmux new-session -A -s claude -c "$HOME/workspace" claude --continue
        fi
        ;;
esac
