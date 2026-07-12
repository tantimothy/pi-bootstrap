#!/usr/bin/env bash
# Dispatches to an environment's own info.sh override if it has one,
# otherwise calls the generic YAML-driven driver (lib/info-lib.sh's
# run_info_yaml) directly against its info.yaml. Every caller should
# invoke this instead of a per-environment info.sh path — most
# environments no longer have their own info.sh; only nanoclaw (OS-
# dependent service commands) and internet-pi (PIHOLE_ENABLE/
# MONITORING_ENABLE feature flags) do, for branching that isn't
# expressible as YAML data.
#
# Usage: run-info.sh <env_dir> <action>
#   action: list | delete | manifest | list-dirs
#
# Assumes the caller has already confirmed the environment has SOME info
# source (info.sh or info.yaml) — this script doesn't print a "no info"
# message itself, since some actions (manifest, list-dirs) are
# machine-readable and a human message on stdout would corrupt that output.
#
# Deliberately NOT `set -euo pipefail` — no original info.sh ever had it
# either (unlike install-desktop.sh, which always did), and lib/info-lib.sh's
# code relies on that: several docker/du lookups there tolerate a non-zero
# exit deep in a pipeline without an explicit `|| true` on every single one,
# expecting the calling script to just not be in strict mode.

ENV_DIR="$1"
ACTION="${2:-list}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -x "$ENV_DIR/info.sh" ]; then
    exec bash "$ENV_DIR/info.sh" "$ACTION"
fi

source "$REPO_DIR/lib/info-lib.sh"
run_info_yaml "$ENV_DIR" "$ACTION"
