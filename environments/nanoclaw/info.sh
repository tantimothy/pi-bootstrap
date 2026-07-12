#!/usr/bin/env bash
# Data lives in info.yaml; the OS-dependent service-commands prefix is
# selected here (the one piece that isn't static data) — see
# lib/info-lib.sh's _load_info_yaml.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_DIR/lib/info-lib.sh"

_load_info_yaml "$SCRIPT_DIR" "${1:-list}"

OS_TYPE="linux"
[[ "$(uname)" == "Darwin" ]] && OS_TYPE="macos"

if [ "$OS_TYPE" = "macos" ]; then
    SERVICE_COMMANDS="$(_yaml_expand "$(_yq '.useful_commands_macos // ""' "$SCRIPT_DIR/info.yaml")")"
else
    SERVICE_COMMANDS="$(_yaml_expand "$(_yq '.useful_commands_host // ""' "$SCRIPT_DIR/info.yaml")")"
fi
USEFUL_COMMANDS="${SERVICE_COMMANDS}
${USEFUL_COMMANDS}"

run_info
