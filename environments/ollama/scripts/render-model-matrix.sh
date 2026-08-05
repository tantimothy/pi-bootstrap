#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOG_FILE="${OLLAMA_MODEL_CATALOG:-$SCRIPT_DIR/../models.tsv}"

awk -F '\t' '
BEGIN {
    hardware[1] = "mac16|Apple Silicon Mac — 16 GB"
    hardware[2] = "mac8|Apple Silicon Mac — 8 GB"
    hardware[3] = "pi8|Raspberry Pi 4/5 — 8 GB"
    hardware[4] = "pi4|Raspberry Pi 4/5 — 4 GB"

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
    print "Models are grouped by supported RAM/machine tier; usage columns mirror"
    print "the **Pull a Recommended Model → Suggested use** menu."
    print ""
    print "A checkmark means the supplied model articles recommend that model for"
    print "the use case. Hardware membership is planning guidance rather than a"
    print "guarantee; the live pull assessment also considers available RAM and"
    print "memory pressure."
    print ""
}
$0 !~ /^#/ {
    count++
    model[count] = $1
    model_hardware[count] = $6
    model_uses[count] = $7
}
END {
    for (tier = 1; tier <= 4; tier++) {
        split(hardware[tier], tier_parts, "|")
        print "## " tier_parts[2]
        print ""
        print "| Model | Wiki | Embeddings | General | Coding | Reasoning | Fast | Multilingual | Long context |"
        print "|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|"
        for (row = 1; row <= count; row++) {
            if (("," model_hardware[row] ",") ~ ("," tier_parts[1] ",")) {
                printf "| `%s` ", model[row]
                for (use = 1; use <= 8; use++) {
                    printf "| %s ", (("," model_uses[row] ",") ~ ("," use_key[use] ",")) ? "✓" : ""
                }
                print "|"
            }
        }
        if (tier < 4) {
            print ""
        }
    }
}
' "$CATALOG_FILE"
