#!/usr/bin/env bash
# Opens a VNC session to the agent browser with the password already on the
# clipboard. Run from deploy.sh's action menu, or directly.
#
# The password is deliberately NOT put in the vnc:// URL: that would expose it
# in the process list and (on macOS) leave it in recent-servers history, and
# whether Screen Sharing accepts "vnc://:password@host" for a password-only
# server is not something this has been able to confirm. A clipboard paste is
# what the client's own prompt expects.
#
# VNC authentication only ever uses the first 8 characters of a password, and
# the macOS client enforces that, so the clipboard gets exactly those 8.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
[ -f "$ENV_DIR/.env" ] && { set -a; source "$ENV_DIR/.env"; set +a; }

CONTAINER_NAME="${CONTAINER_NAME:-browser}"
VNC_PORT="${VNC_PORT:-5901}"
DOCKER="${DOCKER_CMD:-docker}"

if ! "$DOCKER" ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo "❌ $CONTAINER_NAME is not running. Deploy the Agent Browser environment first (FAST)." >&2
    exit 1
fi

pw="$("$DOCKER" exec "$CONTAINER_NAME" cat /data/vnc-password 2>/dev/null | cut -c1-8 || true)"
if [ -z "$pw" ]; then
    echo "❌ Couldn't read /data/vnc-password from $CONTAINER_NAME (still starting? check: $DOCKER logs $CONTAINER_NAME)." >&2
    exit 1
fi

url="vnc://localhost:${VNC_PORT}"

copied=false
if command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "$pw" | pbcopy && copied=true
elif command -v wl-copy >/dev/null 2>&1; then
    printf '%s' "$pw" | wl-copy && copied=true
elif command -v xclip >/dev/null 2>&1; then
    printf '%s' "$pw" | xclip -selection clipboard && copied=true
fi

if [ "$copied" = true ]; then
    echo "🔑 VNC password copied to the clipboard — paste it when asked (⌘V)."
else
    echo "🔑 No clipboard tool found (pbcopy/wl-copy/xclip). VNC password: $pw"
fi

echo "🖥️  Opening $url ..."
if command -v open >/dev/null 2>&1; then
    open "$url"
elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" >/dev/null 2>&1 || echo "   Couldn't launch a handler; connect a VNC client to $url yourself."
else
    echo "   No opener found; connect a VNC client to $url yourself."
fi

if [ "$copied" = true ]; then
    echo "   (The password stays on the clipboard until you copy something else.)"
fi
echo "   VNC listens on this machine only. From another computer: ssh -L ${VNC_PORT}:localhost:${VNC_PORT} <user>@<this-host>, then open $url there."
