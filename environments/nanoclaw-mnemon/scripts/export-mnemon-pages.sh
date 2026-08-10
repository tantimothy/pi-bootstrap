#!/usr/bin/env bash
# Renders a group's mnemon insight graph as a navigable set of static HTML
# pages (an index plus one page per insight, edges as real links) — an
# alternative to export-mnemon-graph.sh's force-directed network, which
# turns unreadable once a store has a few thousand edges (confirmed live:
# 353 insights / 4262 edges rendered as an indecipherable tangle).
#
# Same group/store discovery and same "never open the live WAL file
# directly" snapshot approach as probe-mnemon-db.sh / export-mnemon-graph.sh
# — see those scripts' headers for why: mnemon runs its store in WAL mode,
# and this environment's real per-group data path is
# ${NANOCLAW_INSTALL_PATH}/data/v2-sessions/<group-id>/.claude-shared/mnemon/data/<store>/mnemon.db,
# not any of the ~/.mnemon/... paths an earlier, uncorrected chat guessed.
#
# Unlike export-mnemon-graph.sh, no venv/pip install here — the actual
# rendering (export-mnemon-pages.py) is pure stdlib (sqlite3, html, json,
# pathlib), no pyvis needed for plain HTML pages.
#
# Usage:
#   ./export-mnemon-pages.sh                        # discover group/store, render, open
#   ./export-mnemon-pages.sh <group-session-id>      # skip group discovery

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
[ -f "$ENV_DIR/.env" ] && { set -a; source "$ENV_DIR/.env"; set +a; }
INSTALL_PATH="${NANOCLAW_INSTALL_PATH:-$HOME/nanoclaw-mnemon}"

if [ "${NANOCLAW_SETUP:-mnemon}" != "mnemon" ]; then
    echo "❌ Mnemon is disabled (NANOCLAW_SETUP=plain); there is no mnemon.db to export." >&2
    exit 1
fi

if ! command -v sqlite3 &>/dev/null; then
    echo "❌ sqlite3 isn't installed on this host — install it (e.g. 'apt install sqlite3' /" >&2
    echo "   'brew install sqlite3') and try again." >&2
    exit 1
fi

if ! command -v python3 &>/dev/null; then
    echo "❌ python3 isn't installed on this host — install it and try again." >&2
    exit 1
fi

# Snapshots a live, possibly-WAL sqlite file into a throwaway copy via the
# Online Backup API and echoes the copy's path — identical to
# probe-mnemon-db.sh's / export-mnemon-graph.sh's own _snapshot(); see
# those scripts' headers for why `mktemp -d` with a bare XXXXXX template
# (not a single dotted-suffix file) and the `[ -s "$dst" ]` check both
# matter (confirmed live, on macOS, that skipping either one leads to
# silently querying an empty database instead of failing loudly).
_snapshot() {
    local src="$1" dir dst
    dir="$(mktemp -d "${TMPDIR:-/tmp}/mnemon-export.XXXXXX")" || return 1
    dst="$dir/snapshot.db"
    if ! sqlite3 "$src" ".backup '$dst'" 2>/dev/null || [ ! -s "$dst" ]; then
        rm -rf "$dir"
        return 1
    fi
    echo "$dst"
}

TMP_DIRS=()
_cleanup() { for d in "${TMP_DIRS[@]:-}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

# Same discovery as reload-mnemon.sh / probe-mnemon-db.sh /
# export-mnemon-graph.sh: NanoClaw's own central DB (data/v2.db,
# agent_groups table) for real group names instead of opaque
# ag-<timestamp>-<hash> IDs.
GROUP="${1:-}"
if [ -z "$GROUP" ]; then
    DB_PATH="${INSTALL_PATH}/data/v2.db"
    GROUP_IDS=()
    GROUP_NAMES=()
    if [ -f "$DB_PATH" ]; then
        V2_SNAPSHOT="$(_snapshot "$DB_PATH" || true)"
        if [ -n "${V2_SNAPSHOT:-}" ]; then
            TMP_DIRS+=("$(dirname "$V2_SNAPSHOT")")
            while IFS=$'\t' read -r db_id db_name; do
                [ -n "$db_id" ] || continue
                GROUP_IDS+=("$db_id")
                GROUP_NAMES+=("$db_name")
            done < <(sqlite3 -separator "$(printf '\t')" "$V2_SNAPSHOT" "SELECT id, name FROM agent_groups ORDER BY name;" 2>/dev/null)
        fi
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
        echo "  (Couldn't auto-discover groups — $DB_PATH not found yet.)" >&2
        echo "  Available group sessions:" >&2
        ls "${INSTALL_PATH}/data/v2-sessions" 2>/dev/null | sed 's/^/    /' >&2 || echo "    (install path not found — deploy nanoclaw-mnemon first)" >&2
        exit 1
    fi
fi

MNEMON_DIR="${INSTALL_PATH}/data/v2-sessions/${GROUP}/.claude-shared/mnemon/data"
if [ ! -d "$MNEMON_DIR" ]; then
    echo "❌ No mnemon data dir for this group yet: $MNEMON_DIR" >&2
    exit 1
fi

# Named stores (MNEMON_STORE) are real and this environment doesn't pin
# one, so more than one can legitimately exist per group — same picker as
# probe-mnemon-db.sh / export-mnemon-graph.sh.
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
echo "🔎 Exporting: $DB_FILE"

SNAPSHOT="$(_snapshot "$DB_FILE")" || {
    echo "❌ Couldn't snapshot $DB_FILE — check it exists and is readable." >&2
    exit 1
}
TMP_DIRS+=("$(dirname "$SNAPSHOT")")

OUTPUT_DIR="${ENV_DIR}/exports/mnemon-pages-${GROUP}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUTPUT_DIR"

python3 "$SCRIPT_DIR/export-mnemon-pages.py" "$SNAPSHOT" "$OUTPUT_DIR"

INDEX_HTML="${OUTPUT_DIR}/index.html"
echo ""
echo "✅ Saved: $INDEX_HTML"
# Auto-open is a nicety, not the deliverable — the file above is. Confirmed
# live (export-mnemon-graph.sh) that `open` can fail even when it exists on
# PATH (macOS RBSRequestErrorDomain "Launch failed", seen when deploy.sh's
# own process isn't attached to a full GUI/Aqua session — e.g. driven over
# SSH). Under `set -e`, an unguarded failure there would exit 1 and make a
# genuinely successful export look like an error, so both branches are
# explicitly non-fatal here regardless of whether the launch actually
# succeeded.
if command -v open &>/dev/null; then
    open "$INDEX_HTML" 2>/dev/null || echo "   Couldn't auto-open it — open the path above manually."
elif command -v xdg-open &>/dev/null; then
    ( xdg-open "$INDEX_HTML" >/dev/null 2>&1 & ) || echo "   Couldn't auto-open it — open the path above manually."
else
    echo "   Open it in a browser manually — no 'open'/'xdg-open' found on this host."
fi
