#!/bin/bash
# Starts, in order: a virtual display, a window manager, a VNC server on it,
# Chromium with its DevTools (CDP) port, and a socat relay exposing that port.
#
# Chromium is the foreground process on purpose: if it dies the container
# exits and `restart: unless-stopped` brings the whole stack back, instead of
# leaving a VNC desktop with no browser in it.
set -euo pipefail

DATA=/data
PROFILE="$DATA/profile"
PW_FILE="$DATA/vnc-password"
mkdir -p "$PROFILE"

# A VNC server with no password is an unauthenticated remote desktop. If none
# was configured, generate one once and keep it in the volume so it stays
# stable across restarts; it is printed below and readable with the
# `docker exec` command in info.yaml.
if [ -n "${VNC_PASSWORD:-}" ]; then
    printf '%s' "$VNC_PASSWORD" > "$PW_FILE"
elif [ ! -s "$PW_FILE" ]; then
    head -c 12 /dev/urandom | base64 | tr -d '/+=' | head -c 12 > "$PW_FILE"
    echo "🔑 VNC_PASSWORD not set — generated one and saved it to $PW_FILE (inside the volume)."
fi
chmod 600 "$PW_FILE"
x11vnc -storepasswd "$(cat "$PW_FILE")" /tmp/vncpasswd >/dev/null 2>&1

export DISPLAY=:1
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1
Xvfb :1 -screen 0 "${SCREEN_SIZE:-1440x900}x24" -nolisten tcp &
for _ in $(seq 1 50); do
    [ -e /tmp/.X11-unix/X1 ] && break
    sleep 0.1
done
fluxbox >/dev/null 2>&1 &
x11vnc -display :1 -forever -shared -noxdamage -rfbauth /tmp/vncpasswd -rfbport 5900 -quiet &

# Chromium refuses to start on a profile whose previous owner didn't exit
# cleanly (the hostname in the lock no longer matches after a container
# recreate). These are locks, not data.
rm -f "$PROFILE"/SingletonLock "$PROFILE"/SingletonCookie "$PROFILE"/SingletonSocket

# Chromium only ever binds CDP to loopback, so it is relayed on 9222.
# CDP_ALLOW_RANGE (e.g. 192.168.1.0/24) restricts which source addresses the
# relay accepts; unset means any.
socat "TCP-LISTEN:9222,fork,reuseaddr${CDP_ALLOW_RANGE:+,range=$CDP_ALLOW_RANGE}" TCP:127.0.0.1:9223 &

echo "🌐 Browser up — VNC on :5900, CDP on :9222."

# --no-sandbox: the container runs as root, which Chromium's sandbox refuses.
# --disable-dev-shm-usage: belt-and-braces alongside compose's shm_size.
# Remote-debugging flags: a non-default --user-data-dir is REQUIRED — recent
# Chromium silently ignores --remote-debugging-port on the default profile.
chromium \
    --no-sandbox --disable-dev-shm-usage --disable-gpu \
    --no-first-run --no-default-browser-check \
    --user-data-dir="$PROFILE" \
    --remote-debugging-port=9223 --remote-debugging-address=127.0.0.1 \
    --window-position=0,0 --window-size="$(echo "${SCREEN_SIZE:-1440x900}" | tr x ,)" \
    ${CHROMIUM_EXTRA_FLAGS:-}
