#!/usr/bin/env bash
# Renders a group's mnemon insight graph as a clickable/draggable/zoomable
# interactive HTML network (pyvis), instead of scrolling through
# probe-mnemon-db.sh's text tables. Same group/store discovery and same
# "never open the live WAL file directly" snapshot approach as
# probe-mnemon-db.sh — see that script's header for why: mnemon runs its
# store in WAL mode, and this environment's real per-group data path is
# ${NANOCLAW_INSTALL_PATH}/data/v2-sessions/<group-id>/.claude-shared/mnemon/data/<store>/mnemon.db,
# not any of the ~/.mnemon/... paths an earlier, uncorrected chat guessed.
#
# The actual graph rendering (schema-correct: table `insights`, not
# `memories`; `edges(edge_type, weight, metadata)`, not
# `edges(type, description)`) lives in export-mnemon-graph.py, run against
# the snapshot this script produces — never the live file. Runs inside a
# private venv (.venv-mnemon-graph, created on first use) rather than the
# system/user Python, since Homebrew's Python on macOS — and PEP 668 in
# general — refuses `pip install` outright ("externally managed
# environment") without it.
#
# Usage:
#   ./export-mnemon-graph.sh                        # discover group/store, render, open
#   ./export-mnemon-graph.sh <group-session-id>      # skip group discovery

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

# A dedicated venv, not `pip install --user`/system pyvis — confirmed live
# that Homebrew's Python on macOS (and PEP 668 in general, on any
# externally-managed Python) refuses a bare `pip install`, --user included,
# with "externally managed environment". A venv sidesteps that restriction
# entirely rather than working around it with --break-system-packages,
# which risks the host's actual Homebrew Python install. Persisted under
# this environment's own dir (gitignored) so pyvis is only ever installed
# once, not on every run.
VENV_DIR="${ENV_DIR}/.venv-mnemon-graph"
PYTHON="${VENV_DIR}/bin/python3"
if [ ! -x "$PYTHON" ]; then
    echo "Creating a private virtualenv for this script's own Python deps: $VENV_DIR"
    python3 -m venv "$VENV_DIR"
fi

# Gated behind an explicit y/N prompt, same shape as run.sh's own
# ensure_ollama_ready() — this is the one script here that needs to modify
# anything on the host beyond mnemon.db itself, and that should never
# happen silently. Installing INTO the venv, never system/user site-packages.
if ! "$PYTHON" -c "import pyvis" 2>/dev/null; then
    echo "pyvis isn't installed — it's what actually renders the interactive HTML graph."
    read -rp "Install it now into ${VENV_DIR} (pip install pyvis)? [y/N] " REPLY
    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
        "$PYTHON" -m pip install --quiet pyvis
    else
        echo "❌ Skipping — nothing to render without pyvis." >&2
        exit 1
    fi
fi

# Snapshots a live, possibly-WAL sqlite file into a throwaway copy via the
# Online Backup API and echoes the copy's path — identical to
# probe-mnemon-db.sh's own _snapshot(); see that script's header for why
# `mktemp -d` with a bare XXXXXX template (not a single dotted-suffix file)
# and the `[ -s "$dst" ]` check both matter (confirmed live, on macOS, that
# skipping either one leads to silently querying an empty database instead
# of failing loudly).
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

# Same discovery as reload-mnemon.sh / probe-mnemon-db.sh: NanoClaw's own
# central DB (data/v2.db, agent_groups table) for real group names instead
# of opaque ag-<timestamp>-<hash> IDs.
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
# probe-mnemon-db.sh.
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

OUTPUT_DIR="${ENV_DIR}/exports"
mkdir -p "$OUTPUT_DIR"
OUTPUT_HTML="${OUTPUT_DIR}/mnemon-graph-${GROUP}-$(date +%Y%m%d-%H%M%S).html"

"$PYTHON" "$SCRIPT_DIR/export-mnemon-graph.py" "$SNAPSHOT" "$OUTPUT_HTML"

echo ""
echo "✅ Saved: $OUTPUT_HTML"
if command -v open &>/dev/null; then
    open "$OUTPUT_HTML"
elif command -v xdg-open &>/dev/null; then
    xdg-open "$OUTPUT_HTML" >/dev/null 2>&1 &
else
    echo "   Open it in a browser manually — no 'open'/'xdg-open' found on this host."
fi
