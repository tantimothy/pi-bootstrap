#!/usr/bin/env bash
# Reads a group's real mnemon.db directly (read-only) to answer "what is
# actually in mnemon's memory graph" — instead of trusting mnemon's own
# `embed --status`/`recall` output or guessing at its schema.
#
# Schema and default path confirmed directly against mnemon's own upstream
# source (github.com/mnemon-dev/mnemon, internal/store/db.go and
# internal/store — NOT documented anywhere in this repo before now, and
# NOT what either of two independent AI guesses claimed):
#   - table `insights` (NOT `memories`): id, content, category, importance,
#     tags (JSON TEXT column), entities (JSON TEXT column), source,
#     access_count, created_at, updated_at, deleted_at, last_accessed_at,
#     embedding BLOB, effective_importance
#   - table `edges` (real, but NOT the guessed shape): source_id, target_id,
#     edge_type CHECK IN ('temporal','semantic','causal','entity'), weight,
#     metadata (JSON TEXT), created_at — composite PK (source_id, target_id,
#     edge_type), no `id` or `description` column
#   - table `oplog`: an audit log (operation, insight_id, detail,
#     created_at) — NOT a tags table; there is no separate tags table at all
#   - default file: {MNEMON_DATA_DIR}/data/{store}/mnemon.db, store
#     defaulting to "default"
#
# This environment bakes MNEMON_DATA_DIR=/home/node/.claude/mnemon into the
# agent image (see run.sh's apply_mnemon_patch()), and that container path
# is the bind-mounted .claude-shared dir reload-mnemon.sh already targets —
# so the real host file is:
#   ${INSTALL_PATH}/data/v2-sessions/<group-id>/.claude-shared/mnemon/data/<store>/mnemon.db
#
# Read-only for a reason: mnemon itself may hold this file open (WAL mode,
# per db.go) while an agent container is live. `sqlite3 -readonly` avoids
# ever being the thing that corrupts or blocks a write mnemon is mid-doing.
#
# Usage:
#   ./probe-mnemon-db.sh summary        # schema + table counts + edge-type breakdown
#   ./probe-mnemon-db.sh top            # top insights by effective_importance
#   ./probe-mnemon-db.sh shell          # interactive `sqlite3 -readonly` session
#   ./probe-mnemon-db.sh <mode> <group-session-id>   # skip discovery, target one directly

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
[ -f "$ENV_DIR/.env" ] && { set -a; source "$ENV_DIR/.env"; set +a; }
INSTALL_PATH="${NANOCLAW_INSTALL_PATH:-$HOME/nanoclaw-mnemon}"

if [ "${NANOCLAW_SETUP:-mnemon}" != "mnemon" ]; then
    echo "❌ Mnemon is disabled (NANOCLAW_SETUP=plain); there is no mnemon.db to probe." >&2
    exit 1
fi

if ! command -v sqlite3 &>/dev/null; then
    echo "❌ sqlite3 isn't installed on this host — install it (e.g. 'apt install sqlite3' /" >&2
    echo "   'brew install sqlite3') and try again. This probes the real bind-mounted file" >&2
    echo "   directly, so it needs a host-side sqlite3, not a container one." >&2
    exit 1
fi

MODE="${1:-summary}"
case "$MODE" in
    summary|top|shell) ;;
    *) echo "❌ Unknown mode: $MODE (expected: summary, top, shell)" >&2; exit 1 ;;
esac

# Same discovery as reload-mnemon.sh: NanoClaw's own central DB
# (data/v2.db, agent_groups table) for real group names instead of opaque
# ag-<timestamp>-<hash> IDs. -readonly here too, same reason.
GROUP="${2:-}"
if [ -z "$GROUP" ]; then
    DB_PATH="${INSTALL_PATH}/data/v2.db"
    GROUP_IDS=()
    GROUP_NAMES=()
    if [ -f "$DB_PATH" ]; then
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
        echo "Usage: $0 $MODE <group-session-id>" >&2
        echo "  (Couldn't auto-discover groups — $DB_PATH not found yet.)" >&2
        echo "  Available group sessions:" >&2
        ls "${INSTALL_PATH}/data/v2-sessions" 2>/dev/null | sed 's/^/    /' >&2 || echo "    (install path not found — deploy nanoclaw-mnemon first)" >&2
        exit 1
    fi
fi

MNEMON_DIR="${INSTALL_PATH}/data/v2-sessions/${GROUP}/.claude-shared/mnemon/data"
if [ ! -d "$MNEMON_DIR" ]; then
    echo "❌ No mnemon data dir for this group yet: $MNEMON_DIR" >&2
    echo "   (mnemon creates it on first 'mnemon setup' inside the agent container —" >&2
    echo "   nothing to probe until this group has had at least one agent session run.)" >&2
    exit 1
fi

# Named stores (MNEMON_STORE) are real and this environment doesn't pin one,
# so more than one can legitimately exist per group — pick if there's only
# one, prompt otherwise, same shape as the group picker above.
STORES=()
while IFS= read -r f; do
    [ -n "$f" ] && STORES+=("$(basename "$(dirname "$f")")")
done < <(find "$MNEMON_DIR" -mindepth 2 -maxdepth 2 -name mnemon.db 2>/dev/null | sort)

if [ "${#STORES[@]}" -eq 0 ]; then
    echo "❌ No mnemon.db found under $MNEMON_DIR" >&2
    exit 1
elif [ "${#STORES[@]}" -eq 1 ]; then
    STORE="${STORES[0]}"
else
    echo "Which store?"
    for i in "${!STORES[@]}"; do
        echo "  $((i + 1))) ${STORES[$i]}"
    done
    read -rp "Number: " CHOICE
    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "${#STORES[@]}" ]; then
        echo "❌ Not a valid choice: $CHOICE" >&2
        exit 1
    fi
    STORE="${STORES[$((CHOICE - 1))]}"
fi

DB_FILE="${MNEMON_DIR}/${STORE}/mnemon.db"
echo "🔎 Probing: $DB_FILE"
echo ""

case "$MODE" in
    summary)
        sqlite3 -readonly "$DB_FILE" <<'SQL'
.headers on
.mode column
SELECT 'insights (total)' AS what, COUNT(*) AS n FROM insights
UNION ALL
SELECT 'insights (not deleted)', COUNT(*) FROM insights WHERE deleted_at IS NULL
UNION ALL
SELECT 'edges (total)', COUNT(*) FROM edges
UNION ALL
SELECT 'oplog entries', COUNT(*) FROM oplog;

SELECT edge_type, COUNT(*) AS n FROM edges GROUP BY edge_type ORDER BY n DESC;

SELECT category, COUNT(*) AS n FROM insights WHERE deleted_at IS NULL GROUP BY category ORDER BY n DESC;
SQL
        ;;
    top)
        sqlite3 -readonly "$DB_FILE" <<'SQL'
.headers on
.mode column
.width 6 6 60
SELECT importance, ROUND(effective_importance, 2) AS eff, substr(content, 1, 80) AS content
FROM insights
WHERE deleted_at IS NULL
ORDER BY effective_importance DESC, importance DESC
LIMIT 25;
SQL
        ;;
    shell)
        echo "   (read-only — writes will fail by design; .schema and .tables are useful first)"
        exec sqlite3 -readonly "$DB_FILE"
        ;;
esac
