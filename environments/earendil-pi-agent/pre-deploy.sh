#!/usr/bin/env bash
# Run by lib/deploy-lib.sh's shared compose dispatch before `docker compose`
# ever touches anything (FAST/CLEAN only), with cwd already this
# environment's own directory.
#
# GUARDS THE authorized_keys SINGLE-FILE BIND MOUNT.
#
# docker-compose.yml mounts ${SSH_AUTHORIZED_KEYS_PATH} onto
# /run/host-authorized_keys — a single FILE, which is the exact shape
# docs/lessons-learned/nanoclaw-mnemon.md warns about. Docker's
# "auto-create if missing" behaviour for a bind-mount source always creates
# a DIRECTORY, never a file.
#
# Left unguarded, a host with no authorized_keys file produces this, and
# every step of it looks like something else:
#
#   1. Docker silently creates ~/.ssh/authorized_keys as a directory;
#   2. the entrypoint's `[ -f /run/host-authorized_keys ]` is false, so it
#      writes an EMPTY authorized_keys and warns into the container log
#      where nobody is looking;
#   3. the container starts and reports healthy;
#   4. ssh fails with "Permission denied (publickey)", which reads as a key
#      problem rather than a missing-file problem.
#
# That is a real sequence, hit on a fresh Mac. Refusing here turns four
# misleading symptoms into one message naming the fix.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
fi

# ONE-TIME MIGRATION from the old directory name (environments/pi, renamed so
# it is not confused with Raspberry Pi). Two things would otherwise break:
#  - the untracked .env stayed behind in environments/pi/;
#  - the old container "pi" still exists under compose project "pi", so the
#    new project's container_name (if CONTAINER_NAME is still "pi") collides.
# Data volumes are NOT touched: they are named explicitly from CONTAINER_NAME,
# and a carried-over .env keeps CONTAINER_NAME=pi, so they keep attaching.
OLD_DIR="$SCRIPT_DIR/../pi"
if [ ! -f .env ] && [ -f "$OLD_DIR/.env" ]; then
    cp "$OLD_DIR/.env" .env
    echo "ℹ️  Migrated .env from environments/pi/ (old directory name)."
fi
DOCKER_BIN="${DOCKER_CMD:-docker}"
if command -v ${DOCKER_BIN%% *} >/dev/null 2>&1; then
    OLD_ID="$($DOCKER_BIN ps -aq --filter "label=com.docker.compose.project=pi" --filter "label=com.docker.compose.service=pi" 2>/dev/null | head -1 || true)"
    if [ -n "$OLD_ID" ]; then
        echo "ℹ️  Removing the old compose project 'pi' container (volumes are kept)."
        $DOCKER_BIN rm -f "$OLD_ID" >/dev/null 2>&1 || true
    fi
fi

KEYS="${SSH_AUTHORIZED_KEYS_PATH:-$HOME/.ssh/authorized_keys}"
# Expand a leading ~ the way a .env reader does not.
case "$KEYS" in
    "~/"*) KEYS="$HOME/${KEYS#\~/}" ;;
    "~")   KEYS="$HOME" ;;
esac

if [ -d "$KEYS" ]; then
    echo "❌ $KEYS is a DIRECTORY, not a file." >&2
    echo "" >&2
    echo "   Docker created it. Its 'auto-create if missing' behaviour for a" >&2
    echo "   bind-mount source always makes a directory, never a file — so a" >&2
    echo "   previous deploy ran before the real file existed." >&2
    echo "" >&2
    echo "   Remove it and create the real thing:" >&2
    echo "     rmdir \"$KEYS\"" >&2
    echo "     cat ~/.ssh/id_ed25519.pub >> \"$KEYS\"" >&2
    echo "     chmod 600 \"$KEYS\"" >&2
    exit 1
fi

if [ ! -e "$KEYS" ]; then
    echo "❌ No authorized_keys file at $KEYS" >&2
    echo "" >&2
    echo "   This environment is reachable only over SSH with a public key," >&2
    echo "   so without this file there is no way in — and deploying first" >&2
    echo "   would make Docker create a DIRECTORY there, which is worse." >&2
    echo "" >&2
    echo "   Create it:" >&2
    echo "     mkdir -p \"$(dirname "$KEYS")\"" >&2
    echo "     cat ~/.ssh/id_ed25519.pub >> \"$KEYS\"   # or id_rsa.pub" >&2
    echo "     chmod 700 \"$(dirname "$KEYS")\" && chmod 600 \"$KEYS\"" >&2
    echo "" >&2
    echo "   No key yet?  ssh-keygen -t ed25519" >&2
    echo "" >&2
    echo "   Or point SSH_AUTHORIZED_KEYS_PATH in .env at a different file." >&2
    exit 1
fi

if [ ! -s "$KEYS" ]; then
    echo "❌ $KEYS exists but is EMPTY — SSH would reject every login." >&2
    echo "     cat ~/.ssh/id_ed25519.pub >> \"$KEYS\"" >&2
    exit 1
fi

# Present and non-empty, but is any line actually a key? A file of only
# comments would pass every check above and still lock you out.
if ! grep -qE '^[[:space:]]*(ssh-|ecdsa-|sk-)' "$KEYS"; then
    echo "⚠️  $KEYS has content but no line that looks like a public key." >&2
    echo "   Expected a line starting with ssh-ed25519 / ssh-rsa / ecdsa- / sk-." >&2
    echo "   Continuing, but SSH will likely reject you." >&2
fi
