# pi-barebones — Lessons Learned

## Session: "Set Resolution" custom action didn't actually change the resolution

**Status:** Fixed

**Summary:** The "Set Resolution to 1920x1080 (Console + X11)" custom action
ran without error but had no visible effect on a Bookworm Pi using the
`vc4-kms-v3d` (full KMS) graphics driver — first the action itself failed to
even launch, then once launched it silently did nothing, then once it did
something the console was correct but the X11 desktop still came up at the
monitor's native (higher) resolution.

**Symptom (round 1):** Selecting the action produced
`bash: /scripts/set-resolution.sh: No such file or directory` — an absolute
path missing the environment directory prefix entirely.

**Root cause (round 1):** `deploy.sh`'s custom-action dispatcher
(`ACTION_*` handling) set `ENV_DIR` before calling `_yaml_expand` on the
action's `command:` string, but never set `SCRIPT_DIR` — so
`info.yaml`'s `bash ${SCRIPT_DIR}/scripts/set-resolution.sh` expanded with
an empty `SCRIPT_DIR`. Every other YAML-driven loader (`info-lib.sh`'s
`run_info_yaml`) sets `SCRIPT_DIR` before expanding; this dispatch path was
the one place that didn't.

**Fix (round 1):** Set `SCRIPT_DIR="$TARGET_WORKSPACE_DIR"` alongside
`ENV_DIR` in `deploy.sh`'s `ACTION_*` dispatch block, before the
`_yaml_expand` call.

**Symptom (round 2):** After the path fix, the action ran and reported
success, and rebooted — but the display was still at the wrong (too large)
resolution.

**Root cause (round 2):** `raspi-config nonint do_resolution 2 82` only
writes the legacy `hdmi_group`/`hdmi_mode` keys to `config.txt`. Bookworm's
default graphics driver, `vc4-kms-v3d` (full KMS), ignores those keys
entirely in favor of a `video=` kernel cmdline parameter (or EDID
auto-negotiation if none is set) — confirmed live via
`cat /boot/firmware/config.txt` (showing `dtoverlay=vc4-kms-v3d` plus the
now-inert `hdmi_group=2`/`hdmi_mode=82`) and `cat /boot/firmware/cmdline.txt`
(no `video=` override present at all).

**Fix (round 2):** `set-resolution.sh` now also detects `vc4-kms-v3d` in
`config.txt` and writes `video=HDMI-A-1:1920x1080@60D` onto
`cmdline.txt` directly (idempotently — stripping any prior run's override
before re-adding).

**Symptom (round 3):** After the cmdline.txt fix and another reboot, the
console came up correctly, but the moment the X11 desktop session launched,
the screen reverted to a much larger resolution (everything on-screen
became tiny).

**Root cause (round 3):** Confirmed via `DISPLAY=:0 xrandr --query`: the
monitor was a native 4K display, and Xorg's `modesetting` driver (running
on top of KMS) re-probed the monitor's EDID on its own once the desktop
session started and picked its own preferred mode (3840x2160), independent
of the KMS console override set by `video=` on the kernel cmdline. The
cmdline override only pins the console/boot framebuffer mode — it does not
constrain what Xorg negotiates once it takes over the display.

**Fix (round 3):** Added `scripts/force-x11-resolution.sh`, which pins
every connected output that lists 1920x1080 as an available mode to that
mode via `xrandr`, and wired it up as an XDG autostart entry
(`~/.config/autostart/force-x11-resolution.desktop`) — the same mechanism
this environment already uses for xscreensaver's autostart (see `run.sh`)
— so it reapplies on every X11 login rather than only at boot.

## General Lessons

- **A fixed resolution on a Raspberry Pi under KMS has three independent
  layers that all need to agree, not one:** the legacy `config.txt`
  `hdmi_group`/`hdmi_mode` keys (inert under `vc4-kms-v3d`), the kernel
  cmdline `video=` override (pins the console/boot framebuffer), and
  whatever Xorg's `modesetting` driver negotiates once a desktop session
  actually starts (independent of both of the above, and can silently win).
  A fix that stops at `raspi-config nonint do_resolution` only touches the
  first, inert layer — the failure looks identical ("still wrong
  resolution") whether zero, one, or two of the three layers are actually
  fixed, so each layer has to be verified independently rather than assumed
  fixed because the command that's supposed to set it exited 0.
- Same "reaching the running process is the deliverable, not writing the
  file" pattern documented for `nanoclaw-mnemon`'s patch blocks (see
  `docs/lessons-learned/general.md`) applies here in a different shape: a
  boot-time config change (`video=` on cmdline.txt) does not reach a
  process that starts later and does its own independent negotiation
  (Xorg's EDID probe) — it has to be re-asserted at the point that later
  process actually starts, not just once at boot.
