#!/bin/sh
# Backs open-claude-session.sh's container-mode branch — invoked via
# `docker exec -it <container> bash -lc "cd /root && nanoclaw-claude-tmux.sh"`.
# Identical to the nanoclaw-mnemon environment's own copy of this script —
# see that file's own comment for the full explanation.
#
# Opens (or joins) a persistent, detachable tmux "claude" session inside
# this container's own /root — same grouped-session pattern as the
# standalone claude-cli environment's own bashrc-tmux-attach.sh (see that
# file's own comment for the full explanation of why grouped, not `-A`
# attach-or-create). Each `docker exec -it` invocation of this script gets
# its own window grouped onto the shared "claude" base session, so two
# simultaneous connections (e.g. one from deploy.sh's menu, one run by hand
# from a terminal) can each sit on a different window instead of one
# forcibly mirroring whichever window the other switches to.
#
# Creates the base "claude" session (with `claude --continue` as its first
# window) only the first time ever, or after anything that kills this
# container's tmux server (a restart, STOP/FAST, TEARDOWN/redeploy, CLEAN
# rebuild); every later connection groups onto it instead.
#
# Gated on an explicit `tmux has-session -t claude` check, NOT on whether
# `tmux new-session -t claude -s ...` itself fails — confirmed directly,
# against a real reproduction, that it doesn't fail the way this used to
# assume: tmux's `-t` group-session form silently CREATES the named group
# if it doesn't already exist, rather than erroring, so the old
# `... -t claude ... || tmux new-session -s claude ... claude ...` pattern
# never actually fell through to the `claude`-launching branch on a truly
# fresh tmux server — it always "succeeded" at the first command instead,
# leaving a plain shell (no `claude` process at all) as that first
# session's only window. `has-session` checks for a session literally
# named "claude" up front, which is the thing that actually needs to not
# exist yet for this to be the real first-ever connection.
#
# CLAUDE_MODEL (see .env.example) — set via `docker run -e` at container
# creation, so it's already in this exec'd process's own environment with
# no extra wiring needed (unlike claude-cli's SSH-login case, `docker exec`
# inherits the container's configured environment directly). Passed as
# `--model` only on that same first-ever base-session creation, for the
# same reason `--continue` only applies there: once the base session (and
# the `claude` process inside it) already exists, later connections are
# grouping onto it, not relaunching `claude` with different flags. Change
# CLAUDE_MODEL and it takes effect on the next container recreation (see
# scripts/choose-model.sh).
MODEL_ARGS=""
[ -n "$CLAUDE_MODEL" ] && MODEL_ARGS="--model $CLAUDE_MODEL"
if tmux has-session -t claude 2>/dev/null; then
    tmux new-session -t claude -s "client_$$" \; set-option destroy-unattached on
else
    # `claude --continue` exits outright ("No conversation found to
    # continue") rather than falling back to a fresh conversation itself,
    # when there's genuinely nothing to resume — confirmed directly
    # against a real deploy of the sibling nanoclaw-mnemon environment
    # (identical mechanism): the whole tmux window (and, since it's the
    # only one, the session and the `docker exec -it` connection along
    # with it) closed the instant that happened, dropping straight back to
    # deploy.sh's menu with no usable session at all. Since this
    # environment has no persisted `~/.claude` state across container
    # recreation by design (see docs/lessons-learned/nanoclaw-mnemon.md's
    # "Ultimately reverted, not shipped" entry), that's the case on every
    # single first launch after a recreation, not a rare edge case — so
    # `|| claude $MODEL_ARGS` isn't a defensive nicety here, it's required
    # for this to ever work at all post-recreation. `--continue` is still
    # tried first, since a conversation CAN exist within the same
    # container's lifetime if `claude` was exited and this session
    # relaunched without the container itself being recreated.
    tmux new-session -s claude -c /root sh -c "claude --continue $MODEL_ARGS || claude $MODEL_ARGS"
fi
