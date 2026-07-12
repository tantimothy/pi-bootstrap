#!/usr/bin/env bash
# Data lives in info.yaml, not here — see lib/info-lib.sh's run_info_yaml.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_DIR/lib/info-lib.sh"
run_info_yaml "$SCRIPT_DIR" "${1:-list}"
