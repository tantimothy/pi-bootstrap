#!/usr/bin/env bash
# Run by lib/deploy-lib.sh's shared compose dispatch before `docker compose`
# ever touches anything (FAST/CLEAN only — see that file's own comment for
# the generic hook this backs), with cwd already this environment's own
# directory.
#
# Ensures ./data/claude-json/claude.json exists with valid JSON content
# before docker-compose.yml's bind mount onto /home/claude/.claude.json
# attaches to it. Needs to be a real, pre-existing FILE — Docker's own
# "auto-create if missing" behavior for a bind-mount source always creates
# a directory, never a file, silently breaking the mount's whole purpose —
# and it needs VALID JSON specifically, not just any file: Claude Code's
# own installer/runtime reads and parses this exact path if it already
# exists, and fails outright on invalid content (confirmed directly: a
# zero-byte placeholder broke this same file's own Docker build once
# already — see docs/lessons-learned/claude-cli.md).
#
# A Docker *named volume* mounted directly onto this exact file path was
# tried first (and shipped for a while) — it hit a separate, also-confirmed
# bug: at least one Docker implementation (OrbStack) doesn't reliably
# auto-detect file-vs-directory type for a fresh volume attached to a
# single-file destination, failing with "source .../merged/home/claude/
# .claude.json is not directory" on every deploy regardless of file
# content or naming. A bind mount sidesteps that type-detection entirely,
# but its host source has none of Docker's own copy-up magic either — it
# just needs to already be correct, which is what this script alone is
# responsible for. Living under ./data/ (not loose at the top level) also
# means it rides along with info.yaml's own data_dirs entry for backup/WIPE
# coverage, same as nanoclaw-mnemon's groups/+data/.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

mkdir -p ./data/claude-json
[ -f ./data/claude-json/claude.json ] || echo '{}' > ./data/claude-json/claude.json
