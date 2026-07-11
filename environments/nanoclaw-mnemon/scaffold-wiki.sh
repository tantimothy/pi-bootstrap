#!/usr/bin/env bash
# Scaffolds the purely mechanical, non-collaborative part of NanoClaw's own
# `/add-karpathy-llm-wiki` skill (.claude/skills/add-karpathy-llm-wiki/SKILL.md
# in nanocoai/nanoclaw) for one group: the wiki/ and sources/ directories plus
# empty index.md/log.md, all safe to re-run (skipped if already present).
#
# What this does NOT do — and can't, by the skill's own design: pick a
# domain, decide what the wiki's schema should look like, write the tailored
# container/skills/wiki/SKILL.md, or wire a CLAUDE.md/CLAUDE.local.md section.
# Those steps are explicitly collaborative in the upstream skill (it
# discusses the domain with the user, then writes a schema shaped by that
# conversation) — running them unattended would just produce a generic,
# shallow wiki. Run `/add-karpathy-llm-wiki` yourself in a Claude Code
# session against the group once this scaffold exists; see this script's
# own output for the exact command.
#
# Usage: ./scaffold-wiki.sh <group-folder>
#   <group-folder> is the directory name under groups/, i.e. the same value
#   as `agentGroup.folder` — check `docker exec nanoclaw-mnemon ls groups/`
#   if unsure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/.env" ] && { set -a; source "$SCRIPT_DIR/.env"; set +a; }
INSTALL_PATH="${NANOCLAW_INSTALL_PATH:-$HOME/nanoclaw-mnemon}"

GROUP="${1:-}"
if [ -z "$GROUP" ]; then
    echo "Usage: $0 <group-folder>" >&2
    echo "  Available groups:" >&2
    ls "${INSTALL_PATH}/groups" 2>/dev/null | sed 's/^/    /' >&2 || echo "    (install path not found — deploy nanoclaw-mnemon first)" >&2
    exit 1
fi

GROUP_DIR="${INSTALL_PATH}/groups/${GROUP}"
if [ ! -d "$GROUP_DIR" ]; then
    echo "❌ No such group: $GROUP_DIR" >&2
    echo "   Register the group in NanoClaw first, then re-run this script." >&2
    exit 1
fi

WIKI_DIR="${GROUP_DIR}/wiki"
SOURCES_DIR="${GROUP_DIR}/sources"

mkdir -p "$WIKI_DIR" "$SOURCES_DIR"

if [ ! -f "${WIKI_DIR}/index.md" ]; then
    cat > "${WIKI_DIR}/index.md" <<'EOF'
# Wiki Index

Content-oriented catalog of every wiki page — link, one-line summary, updated on every ingest. See the pattern's "Indexing and Logging" section for conventions.
EOF
    echo "✅ Created ${WIKI_DIR}/index.md"
else
    echo "⏭️  ${WIKI_DIR}/index.md already exists — left untouched"
fi

if [ ! -f "${WIKI_DIR}/log.md" ]; then
    cat > "${WIKI_DIR}/log.md" <<'EOF'
# Wiki Log

Append-only chronological record. Each entry starts with `## [YYYY-MM-DD] ingest|query|lint | <title>` so it stays greppable, e.g. `grep "^## \[" log.md | tail -5`.
EOF
    echo "✅ Created ${WIKI_DIR}/log.md"
else
    echo "⏭️  ${WIKI_DIR}/log.md already exists — left untouched"
fi

echo "✅ ${SOURCES_DIR} ready"
echo ""
echo "Directories are in place. The rest is collaborative by design — run this"
echo "inside a Claude Code session against the group to design the schema and"
echo "wire it into the agent's instructions:"
echo ""
echo "   docker exec -it nanoclaw-mnemon bash -lc \"cd \$NANOCLAW_INSTALL_PATH && claude\""
echo "   > /add-karpathy-llm-wiki"
echo ""
echo "Note: that skill's own doc (as of this writing) edits the group's"
echo "CLAUDE.md directly, but NanoClaw's container-runner now regenerates"
echo "CLAUDE.md fresh on every container spawn (\"Composed at spawn — do not"
echo "edit\", per src/claude-md-compose.ts) and says per-group content belongs"
echo "in CLAUDE.local.md instead. If the skill writes to CLAUDE.md, redirect"
echo "it to groups/${GROUP}/CLAUDE.local.md so the wiki section survives the"
echo "next container restart — check which file it actually used afterward."
