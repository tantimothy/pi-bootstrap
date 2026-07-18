#!/usr/bin/env bash
# Re-runs mnemon's own setup against one group's real, persistent
# .claude-shared directory immediately — instead of waiting for that
# group's next real chat message to spawn a fresh agent container and
# hoping it picks up whatever's currently baked into the image.
#
# Built directly out of a real debugging session: confirmed live, inside
# a real agent-sandbox container, that "mnemon setup --yes --global" (run
# as the same user/HOME NanoClaw's own entrypoint.sh uses) correctly
# writes mnemon's hooks/skill files into ~/.claude/settings.json — this
# script does exactly that against a specific group's REAL host-mounted
# directory, not a throwaway one, so the effect is immediate and
# permanent for that group, without needing NanoClaw's own container
# lifecycle to cooperate at all.
#
# Usage: ./reload-mnemon.sh <group-session-id>
#   <group-session-id> is the directory name under data/v2-sessions/, e.g.
#   ag-1783945827013-hhyk7w — NOT the same as scaffold-wiki.sh's own
#   <group-folder> argument (groups/<folder>, a different identifier
#   NanoClaw also uses) — check `ls data/v2-sessions/` if unsure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/.env" ] && { set -a; source "$SCRIPT_DIR/.env"; set +a; }
INSTALL_PATH="${NANOCLAW_INSTALL_PATH:-$HOME/nanoclaw-mnemon}"
DOCKER="${DOCKER_CMD:-docker}"

GROUP="${1:-}"
if [ -z "$GROUP" ]; then
    echo "Usage: $0 <group-session-id>" >&2
    echo "  Available group sessions:" >&2
    ls "${INSTALL_PATH}/data/v2-sessions" 2>/dev/null | sed 's/^/    /' >&2 || echo "    (install path not found — deploy nanoclaw-mnemon first)" >&2
    exit 1
fi

CLAUDE_DIR="${INSTALL_PATH}/data/v2-sessions/${GROUP}/.claude-shared"
if [ ! -d "$CLAUDE_DIR" ]; then
    echo "❌ No such group session: $CLAUDE_DIR" >&2
    echo "   Available group sessions:" >&2
    ls "${INSTALL_PATH}/data/v2-sessions" 2>/dev/null | sed 's/^/    /' >&2
    exit 1
fi

# Resolved the same way container/build.sh names it (nanoclaw-agent-v2-<slug>)
# rather than hardcoded, so this stays correct across rebuilds without
# editing this script every time the slug changes.
IMAGE_TAG=$($DOCKER images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -m1 '^nanoclaw-agent-v2-' || true)
if [ -z "$IMAGE_TAG" ]; then
    echo "❌ No nanoclaw-agent-v2-* image found — deploy nanoclaw-mnemon (FAST or CLEAN, at least once) first." >&2
    exit 1
fi

echo "🧠 Re-running mnemon setup for group session: $GROUP"
echo "   Directory: $CLAUDE_DIR"
echo "   Image:     $IMAGE_TAG"
echo ""

# --user root + an explicit chown first: the bind-mounted host directory's
# ownership doesn't necessarily match the container's own "node" user
# (confirmed a real, non-hypothetical concern — this same investigation
# hit a container-vs-host UID mismatch earlier this session), and mnemon
# needs to actually write into it. Then su into node for the real command,
# since mnemon's own HOME-relative auto-detection (see this environment's
# own README, "Mnemon Integration" — confirmed directly this session) only
# resolves correctly as the same user/HOME NanoClaw's entrypoint.sh itself
# runs it as.
$DOCKER run --rm --user root \
    -v "${CLAUDE_DIR}:/home/node/.claude" \
    --entrypoint bash \
    "$IMAGE_TAG" \
    -c 'chown -R node:node /home/node/.claude && su node -c "HOME=/home/node mnemon setup --yes --global"'

echo ""
echo "✅ Done — mnemon's hooks/skill files should now be current for this group."
echo "   Verify: cat ${CLAUDE_DIR}/settings.json"
