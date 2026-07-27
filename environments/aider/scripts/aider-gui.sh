#!/bin/sh
# Frontend Option A — Aider's own built-in browser GUI (`aider --gui`),
# launched inside the SAME container the SSH/tmux service already runs in
# (not a separate container — see docker-compose.yml's own comment on why
# this differs from Option B/OpenVSCode Server). Runs in a dedicated,
# detached tmux session ("aider-gui", separate from the SSH login
# session's own "aider" session) so it keeps running in the background
# after this script's own docker exec returns — you don't need to keep an
# SSH connection open for the browser tab to keep working.
#
# EXPERIMENTAL, per Aider's own documentation (aider.chat/docs/usage/
# browser.html calls this an "experimental browser version") — not
# independently verified against a live deploy in this repo. If
# `aider --gui` errors out or the browser can't reach it, that's Aider's
# own feature, not a bug in this wiring; check `docker logs
# ${CONTAINER_NAME:-aider}` and Aider's own GitHub issues first. See
# docs/future-enhancements/aider.md for the open verification item.
#
# Invoked via: docker exec -d <container> bash -lc "aider-gui.sh"
# (detached, -d not -it — see the custom_actions entry in info.yaml).

if tmux has-session -t aider-gui 2>/dev/null; then
    echo "aider-gui tmux session is already running — nothing to do."
    echo "Browse to http://<host>:\${AIDER_GUI_PORT:-8501} if you haven't already."
    exit 0
fi

MODEL_ARGS=""
[ -n "$AIDER_MODEL" ] && MODEL_ARGS="--model $AIDER_MODEL"

# STREAMLIT_SERVER_ADDRESS=0.0.0.0 — Aider's --gui runs a Streamlit server
# under the hood; without this it may bind to localhost only, which is
# unreachable from outside the container regardless of the docker-compose
# port mapping. STREAMLIT_SERVER_HEADLESS=true suppresses Streamlit's own
# "open in browser" prompt, which has no browser to open inside a
# container and would otherwise sit there waiting for input that never
# comes.
tmux new-session -d -s aider-gui -c "$HOME/workspace" \
    env STREAMLIT_SERVER_ADDRESS=0.0.0.0 STREAMLIT_SERVER_HEADLESS=true \
    aider --gui $MODEL_ARGS

echo "✅ Started — browse to http://<host>:\${AIDER_GUI_PORT:-8501}"
echo "   (give it a few seconds to finish starting up)"
echo "   Stop it: docker exec <container name> tmux kill-session -t aider-gui"
