#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOG_FILE="${OLLAMA_MODEL_CATALOG:-$SCRIPT_DIR/../models.tsv}"

awk -F '\t' '
BEGIN {
    hardware[1] = "Raspberry Pi 4/5 — 4 GB baseline"
    hardware[2] = "Apple Silicon Mac or Raspberry Pi 4/5 — 8 GB additions"
    hardware[3] = "Apple Silicon Mac — 16 GB additions"

    use_key[1] = "wiki"
    use_key[2] = "embeddings"
    use_key[3] = "general"
    use_key[4] = "coding"
    use_key[5] = "reasoning"
    use_key[6] = "fast"
    use_key[7] = "multilingual"
    use_key[8] = "long-context"

    print "# Ollama Model Hardware and Use-Case Matrix"
    print ""
    print "This pivot-style matrix is generated from [`models.tsv`](models.tsv)."
    print "Each model appears once, grouped by the minimum hardware tier that"
    print "introduces it. Read from top to bottom to see what additional RAM unlocks."
    print "Usage columns mirror the **Pull a Recommended Model → Suggested use** menu."
    print ""
    print "A checkmark means the supplied model articles recommend that model for"
    print "the use case. Models in a lower tier remain available to the higher tiers."
    print "Hardware membership is planning guidance rather than a guarantee; the live"
    print "pull assessment also considers available RAM and memory pressure."
    print ""
}
$0 !~ /^#/ {
    count++
    model[count] = $1
    model_hardware[count] = $6
    model_uses[count] = $7
    model_notes[count] = $8
    if (("," model_hardware[count] ",") ~ /,pi4,/) {
        model_tier[count] = 1
    } else if (("," model_hardware[count] ",") ~ /,(mac8|pi8),/) {
        model_tier[count] = 2
    } else {
        model_tier[count] = 3
    }
}
END {
    print "| Model | Wiki | Embeddings | General | Coding | Reasoning | Fast | Multilingual | Long context | Description |"
    print "|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|---|"
    for (tier = 1; tier <= 3; tier++) {
        printf "| **%s** ", hardware[tier]
        for (column = 1; column <= 9; column++) {
            printf "| "
        }
        print "|"
        for (row = 1; row <= count; row++) {
            if (model_tier[row] == tier) {
                printf "| `%s` ", model[row]
                for (use = 1; use <= 8; use++) {
                    printf "| %s ", (("," model_uses[row] ",") ~ ("," use_key[use] ",")) ? "✓" : ""
                }
                printf "| %s |\n", model_notes[row]
            }
        }
    }
}
' "$CATALOG_FILE"
