#!/usr/bin/env bash
# Re-run OpenClaw's official interactive onboarding against this environment's
# persistent state. Existing settings are retained as defaults unless the user
# explicitly chooses to reset them in the wizard.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

DOCKER="${DOCKER_CMD:-docker}"
exec "$DOCKER" compose run --rm --no-deps --entrypoint node openclaw-gateway \
    dist/index.js onboard --mode local --no-install-daemon
