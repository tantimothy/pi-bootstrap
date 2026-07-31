#!/usr/bin/env bash
# Installs pi-bootstrap's managed cost-and-fidelity policy into each
# NanoClaw group's durable CLAUDE.local.md.  NanoClaw composes CLAUDE.md on
# every agent spawn, so this is deliberately a group-local file instead.
#
# Usage: apply-nanoclaw-group-policy.sh <install-path> [group-folder]
# With no group-folder, every immediate directory under <install-path>/groups
# is updated.  The marker-delimited block is replaced atomically and all
# other user-authored group instructions are left untouched.

set -euo pipefail

INSTALL_PATH="${1:?Usage: $0 <install-path> [group-folder]}"
GROUP="${2:-}"
GROUPS_DIR="${INSTALL_PATH}/groups"
START_MARKER='<!-- PI_BOOTSTRAP_COST_AND_FIDELITY_POLICY_START -->'
END_MARKER='<!-- PI_BOOTSTRAP_COST_AND_FIDELITY_POLICY_END -->'

policy_block() {
    cat <<'EOF'
<!-- PI_BOOTSTRAP_COST_AND_FIDELITY_POLICY_START -->
## Operating policy: cost discipline and knowledge fidelity

### Cost discipline
- Treat LLM usage as a constrained shared monthly resource. Minimize token use whenever doing so does not reduce correctness, safety, or source fidelity.
- Prefer local, deterministic work first: file listing, hashing, deduplication, metadata inspection, text extraction, and link/asset validation.
- Work incrementally from the source manifest, index, and changed inputs. Do not re-read, re-summarize, or rewrite unchanged material.
- Read only the source sections needed for the task; batch related work; avoid speculative research and broad maintenance sweeps.
- Keep responses and logs concise. Do not narrate routine progress, repeat plans, or duplicate information.
- Before unusually large ingest, reprocessing, or maintenance work, state the expected scope and ask for approval.
- For work involving an existing topic, project, person, decision, preference, prior source, or cross-session question, run one focused mnemon recall first using the task's named entities and key terms.
- For a wholly new, self-contained source ingest, begin from the source manifest and wiki. Recall mnemon if the source refers to an existing entity/topic or the task requires reconciliation with prior knowledge.
- Reuse that recall for the current task; do not perform broad or repeated exploratory recalls unless the task scope materially changes.
- Store durable relationships, decisions, and preferences in mnemon. Do not store routine ingest bookkeeping or duplicate source text there.
- Never reduce source fidelity merely to save tokens: preserve originals, URLs, diagrams, provenance, and uncertainty.

### Source-of-truth and no-loss rule
- `sources/` is the immutable source archive. Never delete, overwrite, truncate, or replace original files.
- The wiki is derived knowledge, not a replacement for sources or mnemon.
- Every ingested source needs a stable source ID, original filename, SHA-256 hash, source URL if applicable, retrieval date, and ingest status.
- Every factual wiki claim must cite its source ID and a precise locator: page, heading, timestamp, or quoted passage.
- Preserve URLs exactly. Keep the original URL and any local/archive copy path; never replace a URL with a summary.
- Preserve diagrams and media: retain the original file, URL, embed, or source code; retain extracted image assets; add textual descriptions only as supplementary accessibility metadata.
- Preserve Mermaid and other diagram source verbatim when available.

### Safe incremental ingest
1. Register or verify the source in the manifest; hash it and skip identical already-ingested content.
2. Preserve the raw original before extracting or summarizing.
3. Extract locally where possible; send only relevant chunks to the model.
4. Update or add wiki pages with provenance and cross-links.
5. Update `index.md` and append an ingest record to `log.md`.
6. Verify every cited local asset and link exists. Record extraction limitations rather than silently omitting content.

### Maintenance
- Perform incremental maintenance only: changed sources, broken links, stale pages, or an explicitly requested scope.
- Never silently remove information. Mark material as superseded or deprecated and link to its replacement.
- Do not perform broad rewrites, consolidation, or deletion without explicit approval.
- If sources conflict, preserve both claims with provenance and describe the conflict.
<!-- PI_BOOTSTRAP_COST_AND_FIDELITY_POLICY_END -->
EOF
}

apply_policy() {
    local group_dir="$1" target tmp start_count end_count
    target="${group_dir}/CLAUDE.local.md"
    start_count=$(grep -Fxc "$START_MARKER" "$target" 2>/dev/null || true)
    end_count=$(grep -Fxc "$END_MARKER" "$target" 2>/dev/null || true)
    start_count="${start_count:-0}"
    end_count="${end_count:-0}"

    if { [ "$start_count" -eq 0 ] && [ "$end_count" -ne 0 ]; } || \
       { [ "$start_count" -ne 0 ] && [ "$end_count" -eq 0 ]; } || \
       [ "$start_count" -gt 1 ] || [ "$end_count" -gt 1 ]; then
        echo "⚠️  ${target} has malformed pi-bootstrap policy markers; left untouched." >&2
        return 1
    fi

    tmp=$(mktemp "${target}.tmp.XXXXXX")
    if [ -f "$target" ]; then
        awk -v start="$START_MARKER" -v end="$END_MARKER" '
            $0 == start { skipping = 1; next }
            skipping && $0 == end { skipping = 0; next }
            !skipping { print }
        ' "$target" > "$tmp"
    fi
    policy_block >> "$tmp"
    mv "$tmp" "$target"
    echo "✅ Applied cost-and-fidelity policy to ${target}"
}

if [ -n "$GROUP" ]; then
    group_dir="${GROUPS_DIR}/${GROUP}"
    if [ ! -d "$group_dir" ]; then
        echo "❌ No such NanoClaw group: ${group_dir}" >&2
        exit 1
    fi
    apply_policy "$group_dir"
    exit 0
fi

if [ ! -d "$GROUPS_DIR" ]; then
    echo "ℹ️  No NanoClaw groups directory yet; no group policy applied."
    exit 0
fi

found_group=false
while IFS= read -r -d '' group_dir; do
    found_group=true
    apply_policy "$group_dir"
done < <(find "$GROUPS_DIR" -mindepth 1 -maxdepth 1 -type d -print0)

if [ "$found_group" = false ]; then
    echo "ℹ️  No NanoClaw groups yet; no group policy applied."
fi
