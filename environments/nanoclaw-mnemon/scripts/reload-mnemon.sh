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
# Usage:
#   ./reload-mnemon.sh                  # auto-picks if there's only one
#                                        # group, otherwise prompts with a
#                                        # numbered list of real group names
#   ./reload-mnemon.sh <group-session-id>  # skip discovery, target one directly
#     — the directory name under data/v2-sessions/, e.g.
#     ag-1783945827013-hhyk7w — NOT the same as scaffold-wiki.sh's own
#     <group-folder> argument (groups/<folder>, a different identifier
#     NanoClaw also uses).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/.env" ] && { set -a; source "$SCRIPT_DIR/.env"; set +a; }
INSTALL_PATH="${NANOCLAW_INSTALL_PATH:-$HOME/nanoclaw-mnemon}"
DOCKER="${DOCKER_CMD:-docker}"

GROUP="${1:-}"
if [ -z "$GROUP" ]; then
    # Auto-discovery from NanoClaw's own central DB (data/v2.db,
    # agent_groups table: id, name, folder — confirmed directly against
    # its own src/db/agent-groups.ts) rather than just listing raw
    # data/v2-sessions/ folder names, so you get real group names to pick
    # from instead of opaque ag-<timestamp>-<hash> IDs. -readonly: this
    # script must never be the thing that writes to NanoClaw's own live
    # DB. Falls back to the old manual-ID flow if sqlite3 isn't installed
    # or the DB doesn't exist yet — never fatal on its own.
    DB_PATH="${INSTALL_PATH}/data/v2.db"
    GROUP_IDS=()
    GROUP_NAMES=()
    if command -v sqlite3 &>/dev/null && [ -f "$DB_PATH" ]; then
        while IFS=$'\t' read -r db_id db_name; do
            [ -n "$db_id" ] || continue
            GROUP_IDS+=("$db_id")
            GROUP_NAMES+=("$db_name")
        done < <(sqlite3 -readonly -separator "$(printf '\t')" "$DB_PATH" "SELECT id, name FROM agent_groups ORDER BY name;" 2>/dev/null)
    fi

    if [ "${#GROUP_IDS[@]}" -eq 1 ]; then
        GROUP="${GROUP_IDS[0]}"
        echo "Only one group registered — using it: ${GROUP_NAMES[0]} ($GROUP)"
    elif [ "${#GROUP_IDS[@]}" -gt 1 ]; then
        echo "Which group?"
        for i in "${!GROUP_IDS[@]}"; do
            echo "  $((i + 1))) ${GROUP_NAMES[$i]}  (${GROUP_IDS[$i]})"
        done
        read -rp "Number: " CHOICE
        if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "${#GROUP_IDS[@]}" ]; then
            echo "❌ Not a valid choice: $CHOICE" >&2
            exit 1
        fi
        GROUP="${GROUP_IDS[$((CHOICE - 1))]}"
    else
        echo "Usage: $0 <group-session-id>" >&2
        echo "  (Couldn't auto-discover groups — sqlite3 not installed, or $DB_PATH not found yet.)" >&2
        echo "  Available group sessions:" >&2
        ls "${INSTALL_PATH}/data/v2-sessions" 2>/dev/null | sed 's/^/    /' >&2 || echo "    (install path not found — deploy nanoclaw-mnemon first)" >&2
        exit 1
    fi
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
