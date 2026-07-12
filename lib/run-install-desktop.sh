#!/usr/bin/env bash
# Dispatches to an environment's own install-desktop.sh override if it has
# one, otherwise calls the generic YAML-driven driver
# (lib/desktop-lib.sh's run_desktop_install_yaml) directly against its
# desktop-entries.yaml. Every caller should invoke this instead of a
# per-environment install-desktop.sh path — most environments no longer
# have their own; only nanoclaw does, for host-vs-container deploy-mode
# branching that isn't expressible as YAML data. An environment with
# neither file (internet-pi, pi-barebones — no desktop entries at all) is
# a silent no-op, matching every call site's previous existence-guard
# behavior.
#
# Usage: run-install-desktop.sh <env_dir> [--uninstall]
set -euo pipefail

ENV_DIR="$1"; shift
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -x "$ENV_DIR/install-desktop.sh" ]; then
    exec bash "$ENV_DIR/install-desktop.sh" "$@"
fi

if [ -f "$ENV_DIR/desktop-entries.yaml" ]; then
    source "$REPO_DIR/lib/desktop-lib.sh"
    run_desktop_install_yaml "$ENV_DIR" "$@"
fi
