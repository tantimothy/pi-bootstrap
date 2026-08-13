#!/bin/bash
# Run via XDG autostart (wired up by set-resolution.sh) once an X11 session
# has actually started. The KMS console framebuffer override in cmdline.txt
# (also written by set-resolution.sh) only pins the boot/console mode — the
# Xorg modesetting driver that runs on top of KMS still probes the
# monitor's EDID on its own and picks its own preferred mode independent of
# that override. Confirmed live: `video=HDMI-A-1:1920x1080@60D` in
# cmdline.txt in place, yet `xrandr --query` showed HDMI-1 running at
# 3840x2160 (the monitor's native mode) once the desktop session launched.
# Pin every connected output that actually offers 1920x1080 to that mode
# explicitly, rather than hardcoding a single output name — HDMI-1 vs
# HDMI-A-1 vs HDMI-A-2 varies by driver/kernel version.
set -u

command -v xrandr >/dev/null 2>&1 || exit 0

xrandr --query 2>/dev/null | awk '/ connected/{print $1}' | while read -r output; do
    if xrandr --query 2>/dev/null | grep -A1 "^${output} connected" | grep -q '1920x1080'; then
        xrandr --output "$output" --mode 1920x1080 2>/dev/null || true
    fi
done
