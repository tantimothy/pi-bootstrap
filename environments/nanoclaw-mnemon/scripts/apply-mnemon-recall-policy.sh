#!/usr/bin/env bash
# Adds the Mnemon-only recall extension to a group's durable CLAUDE.local.md.
# The generic cost-and-fidelity policy is maintained separately in lib/ because
# it applies to both NanoClaw environments.
#
# Usage: apply-mnemon-recall-policy.sh <install-path> [group-folder]

set -euo pipefail

INSTALL_PATH="${1:?Usage: $0 <install-path> [group-folder]}"
GROUP="${2:-}"
GROUPS_DIR="${INSTALL_PATH}/groups"
START_MARKER='<!-- PI_BOOTSTRAP_MNEMON_RECALL_POLICY_START -->'
END_MARKER='<!-- PI_BOOTSTRAP_MNEMON_RECALL_POLICY_END -->'

policy_block() {
    cat <<'EOF'
<!-- PI_BOOTSTRAP_MNEMON_RECALL_POLICY_START -->
### Mnemon recall
- For work involving an existing topic, project, person, decision, preference, prior source, or cross-session question, run one focused mnemon recall first using the task's named entities and key terms.
- For a wholly new, self-contained source ingest, begin from the source manifest and wiki. Recall mnemon if the source refers to an existing entity/topic or the task requires reconciliation with prior knowledge.
- Reuse that recall for the current task; do not perform broad or repeated exploratory recalls unless the task scope materially changes.
- Store durable relationships, decisions, and preferences in mnemon. Do not store routine ingest bookkeeping or duplicate source text there.
<!-- PI_BOOTSTRAP_MNEMON_RECALL_POLICY_END -->
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
        echo "⚠️  ${target} has malformed Mnemon policy markers; left untouched." >&2
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
    echo "✅ Applied Mnemon recall policy to ${target}"
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
    echo "ℹ️  No NanoClaw groups directory yet; no Mnemon recall policy applied."
    exit 0
fi

found_group=false
while IFS= read -r -d '' group_dir; do
    found_group=true
    apply_policy "$group_dir"
done < <(find "$GROUPS_DIR" -mindepth 1 -maxdepth 1 -type d -print0)

if [ "$found_group" = false ]; then
    echo "ℹ️  No NanoClaw groups yet; no Mnemon recall policy applied."
fi
