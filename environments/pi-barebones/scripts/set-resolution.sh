#!/bin/bash
# Forces the Pi's console framebuffer to a fixed 1920x1080 mode. Without
# this, a Pi's HDMI auto-negotiation with some monitors/capture devices
# picks a mode the display can't show correctly (usually reported as
# "too big"/off-screen) on first connect.
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

echo "🖥️  Forcing console resolution to 1920x1080 (DMT mode 82)..."
sudo raspi-config nonint do_resolution 2 82

# do_resolution only writes the legacy hdmi_group/hdmi_mode config.txt keys.
# Bookworm's default graphics driver (vc4-kms-v3d, full KMS) ignores those
# in favor of a `video=` kernel cmdline override and just auto-negotiates
# the display's native mode instead — so on a KMS system the two lines
# above silently do nothing and the console stays at whatever the monitor
# advertised. Force the KMS-native override too, when that driver is active.
#
# Deliberately WITHOUT the `D` ("force this timing even if the display
# doesn't advertise it as valid") flag some guides suggest — real-world
# failure: with `D` set, a Pi that later re-negotiated with the same
# monitor came up to a completely blank display with no HDMI signal at
# all, on every subsequent boot, requiring the SD card to be pulled and
# cmdline.txt edited by hand to recover. Without `D`, the kernel only
# applies the mode if the connected display's own EDID actually reports
# it as supported — safe by construction, at the cost of doing nothing on
# a display that doesn't list 1920x1080 as one of its own modes.
CONFIG_FILE=""
for candidate in /boot/firmware/config.txt /boot/config.txt; do
    [ -f "$candidate" ] && { CONFIG_FILE="$candidate"; break; }
done
CMDLINE_FILE=""
for candidate in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
    [ -f "$candidate" ] && { CMDLINE_FILE="$candidate"; break; }
done

if [ -n "$CONFIG_FILE" ] && [ -n "$CMDLINE_FILE" ] && grep -q '^dtoverlay=vc4-kms-v3d' "$CONFIG_FILE"; then
    echo "🖥️  KMS driver detected — requesting video=HDMI-A-1:1920x1080@60 on $CMDLINE_FILE..."
    CURRENT="$(cat "$CMDLINE_FILE")"
    # Strip any video= param this action added on a previous run first, so
    # repeat runs stay idempotent instead of accumulating duplicates.
    CURRENT="$(echo "$CURRENT" | sed -E 's/(^| )video=HDMI-A-1:[^ ]*//g')"
    NEW="$(echo "$CURRENT video=HDMI-A-1:1920x1080@60" | tr -s ' ')"
    printf '%s' "$NEW" | sudo tee "$CMDLINE_FILE" >/dev/null
fi

# Xorg's own modesetting driver re-probes the monitor's EDID once the
# desktop session starts and can pick its own preferred (often higher,
# e.g. native 4K) mode independent of the console override above. An
# earlier version of this action tried to correct that live, after the
# fact, via an `xrandr` call wired into X11's login autostart — on real
# hardware that live mode-switch against an already-running session froze
# the desktop outright and left the Pi unable to bring up a display on any
# subsequent boot. This does the same job a fundamentally safer way: a
# declarative Xorg startup config that tells the driver what mode to
# prefer *before* it ever picks one, rather than switching an already-
# running session. Confirmed working: reboot, desktop comes up directly at
# 1920x1080, no live switch involved. Worst case if the output name below
# doesn't match this Pi's actual connector, Xorg just ignores the
# unmatched Monitor section and falls back to its normal auto-detected
# mode — no lockout risk like the cmdline/live-switch approaches above.
#
# "HDMI-1" assumes the first HDMI port, matching the same assumption the
# video=HDMI-A-1 cmdline override above already makes — if your monitor is
# on the Pi's second HDMI port, edit this file to "HDMI-2" after running:
# `xrandr --query` (from a terminal on the desktop) to confirm the name.
echo "🖥️  Pinning X11 to prefer 1920x1080 on startup (declarative config, not a live switch)..."
sudo mkdir -p /etc/X11/xorg.conf.d
sudo tee /etc/X11/xorg.conf.d/10-monitor.conf > /dev/null << 'EOF'
Section "Monitor"
    Identifier "HDMI-1"
    Option "PreferredMode" "1920x1080"
EndSection
EOF

echo "✅ Done. A reboot is required for this to take effect: sudo reboot"
