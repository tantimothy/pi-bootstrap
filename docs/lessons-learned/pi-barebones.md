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

**Symptom (round 4 — real hardware incident):** After the round 3 fix and a
reboot, the desktop froze completely the moment the GUI session came up.
The next reboot produced a fully blank monitor (no signal at all) and the
Pi was unreachable over SSH too — a full lockout, not just a display glitch.
Recovery required physically pulling the SD card, mounting its FAT32 boot
partition on another machine, and hand-editing `cmdline.txt`/`config.txt`
to strip the changes this action had written, before the Pi would boot
again at all.

**Root cause (round 4):** Two compounding risks, both now reverted:
1. The `video=HDMI-A-1:1920x1080@60D` cmdline override from round 2 used
   the `D` flag — "force this timing even if the display doesn't advertise
   it as valid." That bypasses the kernel's own EDID-validity check
   entirely; forcing an unvalidated mode is exactly the kind of thing that
   can leave a display with no signal at all if anything about the forced
   timing doesn't actually work with that display/cable/adapter.
2. The round 3 autostart entry ran `xrandr --output ... --mode 1920x1080`
   against an **already-running** X session on every login. Live mode
   switches against the Broadcom/VC4 GPU driver are known to be flaky —
   forcing one unsupervised, with no human watching to catch a bad
   transition, is a real risk on this hardware, not a hypothetical one. It
   coincided exactly with the freeze.
   
   The full-lockout-on-every-subsequent-boot part (not just one bad
   session) most likely came from #1 — a cmdline-level kernel parameter is
   evaluated before networking or SSH ever comes up, which is consistent
   with "no SSH either." Recovering by editing *only* the FAT32 boot
   partition (not the root filesystem) and having that be sufficient to
   restore boot also rules out filesystem corruption from the unclean
   power-cycle — this was a boot-config/KMS problem, not disk damage.

**Fix (round 4):** Reworked `set-resolution.sh` to be conservative instead
of clever:
- Dropped the `D` flag from the `video=` override — `video=HDMI-A-1:1920x1080@60`
  now only applies if the connected display's own EDID actually reports
  that mode as supported. Safe by construction, at the cost of doing
  nothing on a display that doesn't advertise 1920x1080 itself.
- Removed `force-x11-resolution.sh` and its autostart entry entirely — no
  more automatic mode-forcing against a live X session. If the X11 desktop
  is still at the wrong resolution after a reboot, the README now
  documents running `xrandr --output <name> --mode 1920x1080` manually,
  once, from a terminal on the desktop — a human present to notice if it
  goes wrong, not an unsupervised login hook.

## General Lessons

- **A "fix" for a Pi's own display/boot configuration is running on
  irreplaceable, physically-remote hardware with no snapshot/rollback** —
  unlike a container or a file in this repo, a bad `cmdline.txt` or a live
  GPU mode-switch can leave the device requiring physical access (pulling
  the SD card) to recover at all. That changes the risk calculus
  completely: prefer the conservative option that does less but fails
  safe (a `video=` override without a force flag, applied only if the
  display already claims to support it) over the more complete one that
  can leave the device totally inaccessible if it's wrong (`D`-forced
  modes, live unsupervised mode-switches). "It worked in my one test" is
  not the same bar as "safe to leave running unsupervised on hardware I
  can't immediately get physical access to."
- Kernel/firmware-level flags with names like "force" (`D` in a `video=`
  mode string, `hdmi_force_hotplug`, etc.) exist specifically to bypass a
  safety/validity check — that's exactly the check that exists to prevent
  the failure mode seen here. Treat any "force" flag on boot-critical
  hardware config as a last resort behind a documented, deliberate
  tradeoff, not a default to reach for to make a stubborn resolution
  problem go away.

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
