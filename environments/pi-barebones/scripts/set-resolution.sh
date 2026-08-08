#!/bin/bash
# Forces the Pi's console framebuffer AND X11 desktop to a fixed 1920x1080
# DMT mode. Without this, a Pi's HDMI auto-negotiation with some
# monitors/capture devices picks a mode the display can't show correctly
# (usually reported as "too big"/off-screen) on first connect.
#
# Also pins the desktop session to X11 (not Wayland/labwc, Raspberry Pi
# OS Bookworm's default) — the forced resolution and the xscreensaver
# block this environment installs both only apply under X11.
set -euo pipefail

if ! command -v raspi-config >/dev/null 2>&1; then
    echo "❌ raspi-config not found — this action only works on Raspberry Pi OS." >&2
    exit 1
fi

echo "🖥️  Switching desktop session to X11..."
sudo raspi-config nonint do_wayland W1

echo "🖥️  Forcing console + X11 resolution to 1920x1080 (DMT mode 82)..."
sudo raspi-config nonint do_resolution 2 82

echo "✅ Done. A reboot is required for this to take effect: sudo reboot"
