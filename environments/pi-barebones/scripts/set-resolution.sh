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

# do_resolution only writes the legacy hdmi_group/hdmi_mode config.txt keys.
# Bookworm's default graphics driver (vc4-kms-v3d, full KMS) ignores those
# in favor of a `video=` kernel cmdline override and just auto-negotiates
# the display's native mode instead — so on a KMS system the two lines
# above silently do nothing and the screen stays at whatever the monitor
# advertised. Force the KMS-native override too, when that driver is active.
CONFIG_FILE=""
for candidate in /boot/firmware/config.txt /boot/config.txt; do
    [ -f "$candidate" ] && { CONFIG_FILE="$candidate"; break; }
done
CMDLINE_FILE=""
for candidate in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
    [ -f "$candidate" ] && { CMDLINE_FILE="$candidate"; break; }
done

if [ -n "$CONFIG_FILE" ] && [ -n "$CMDLINE_FILE" ] && grep -q '^dtoverlay=vc4-kms-v3d' "$CONFIG_FILE"; then
    echo "🖥️  KMS driver detected — forcing video=HDMI-A-1:1920x1080@60D on $CMDLINE_FILE..."
    CURRENT="$(cat "$CMDLINE_FILE")"
    # Strip any video= param this action added on a previous run first, so
    # repeat runs stay idempotent instead of accumulating duplicates.
    CURRENT="$(echo "$CURRENT" | sed -E 's/(^| )video=HDMI-A-1:[^ ]*//g')"
    NEW="$(echo "$CURRENT video=HDMI-A-1:1920x1080@60D" | tr -s ' ')"
    printf '%s' "$NEW" | sudo tee "$CMDLINE_FILE" >/dev/null
fi

# Even with the KMS console override above, Xorg's own modesetting driver
# re-probes the monitor's EDID once the desktop session starts and can pick
# its own preferred (often higher, e.g. native 4K) mode regardless — seen
# live via `xrandr --query` reporting the monitor's native mode active
# despite the cmdline.txt override being in place. Pin it explicitly on
# every X11 login via the same XDG autostart mechanism this environment
# already uses for xscreensaver (see run.sh).
TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME=$(eval echo "~$TARGET_USER")
FORCE_RES_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/force-x11-resolution.sh"

echo "🖥️  Wiring up X11 login autostart to pin 1920x1080 against EDID re-negotiation..."
sudo -u "$TARGET_USER" mkdir -p "$TARGET_HOME/.config/autostart"
sudo tee "$TARGET_HOME/.config/autostart/force-x11-resolution.desktop" > /dev/null << EOF
[Desktop Entry]
Type=Application
Name=Force 1920x1080 resolution
Comment=Pins X11 to 1920x1080 (Xorg re-probes EDID and ignores the KMS console override otherwise)
Exec=$FORCE_RES_SCRIPT
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF
sudo chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.config/autostart/force-x11-resolution.desktop"

echo "✅ Done. A reboot is required for this to take effect: sudo reboot"
