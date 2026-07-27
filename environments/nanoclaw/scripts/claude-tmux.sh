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
# Falls through to actually creating the base "claude" session (with
# `claude --continue` as its first window) only the first time ever, or
# after anything that kills this container's tmux server (a restart,
# STOP/FAST, TEARDOWN/redeploy, CLEAN rebuild) — the base session's own
# first attempt to group onto itself fails cleanly (2>/dev/null) and falls
# through to creating it instead.
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
tmux new-session -t claude -s "client_$$" \; set-option destroy-unattached on 2>/dev/null \
|| tmux new-session -s claude -c /root claude --continue $MODEL_ARGS
