# MacintoshPi — Mac OS 7/8/9 Emulation on Raspberry Pi

Wraps [jaromaz/MacintoshPi](https://github.com/jaromaz/MacintoshPi): full-screen Basilisk II (Mac OS 7/8) and SheepShaver (Mac OS 9) with sound, networking and modem emulation, running directly from the Raspberry Pi OS command line — no X.org, no desktop, no Docker.

This is not a Docker environment — everything it does is host-level compilation and package installation, running directly on the Pi.

---

## ⚙️ Why This Needs a Custom `run.sh`

`deploy.sh`'s generic fallback only knows how to build/run a Docker image or `docker compose up` a stack. MacintoshPi has no `Dockerfile`/`docker-compose.yml` on purpose — it needs things a container can't give it:

- **Direct SDL2/KMS framebuffer access** for full-screen, X-less rendering — the whole point of the project is avoiding the overhead of a window manager.
- **Kernel modules built against the running kernel** — the SheepShaver/Basilisk II `NetDriver` (`sheep_net`) for emulated networking, and `tty0tty` for the virtual modem.
- **A launcher that reboots the Pi** (`mac os9-768`, etc.) to switch `/boot/config.txt` resolution before launching a given system — see `launcher/mac` upstream.
- **A systemd service** (`vmodem.service`) for the virtual modem, running continuously alongside whichever Mac OS/VICE session is active.

None of that is expressible as a container. `run.sh` orchestrates fetching and running upstream's own installer scripts unmodified — it doesn't reimplement any of their logic.

---

## ⚠️ Read Before Deploying

- **Officially supported boards**: Raspberry Pi Zero 2 W, 2, 2B, 3, 3A+, 3B, 3B+. **Not Pi 4 or 5.**
- **Takes about two hours** — everything is compiled from source (SDL2, Basilisk II, SheepShaver, VICE, CDEmu's `vhba` kernel module, `tty0tty`, SyncTERM). Run it inside `tmux` (see `pi-barebones`) if you're over SSH, so a dropped connection doesn't kill the build.
- **Needs a stable internet connection** and a few hundred MB of downloads (ROMs, pre-built hard disk images, source tarballs).
- **`sudo` is required** — the installer installs system packages, kernel modules and a systemd unit.
- **Re-running the full install overwrites your Mac OS hard disks.** Upstream's own `MacOS_version()` function deletes and re-downloads each `macos7`/`macos8`/`macos9` directory (ROM + fresh HDD image) on every run of `build_all.sh`. This `run.sh` guards against that: once deployed, **FAST is a no-op** that just reports status — use the **custom actions** below to reinstall one component at a time, or **CLEAN** (which explicitly warns you) to rebuild everything from scratch.

---

## OS Compatibility — Bookworm Is Already Supported

Upstream's own `README.md` still says installation "must be" a *clean, full Raspberry Pi OS (oldold Legacy) Buster image* — that line is stale. [PR #44](https://github.com/jaromaz/MacintoshPi/pull/44) ("Port to Raspbian 2025-05-13"), merged into `master` in October 2025, already updated every build script (`macos7.sh`/`macos8.sh`/`macos9.sh`/`vice.sh`/`cdemu.sh`/`vmodem.sh`/`syncterm.sh`) for current **Raspberry Pi OS Bookworm** (Debian 12) — updated package names, dropped packages no longer in Debian's repos (`libesd0-dev`, the old `tcpser`/`netcat` packages), and removed the hardcoded `pi`-user requirement. This `run.sh` always clones upstream's current default branch, so it picks up that Bookworm support automatically — no patching needed on our side.

**Practical takeaway:** install this on a current Raspberry Pi OS (Bookworm, 32-bit/armhf — the project does not target 64-bit) in CLI/Lite mode, not a legacy Buster image. If a future upstream change breaks Bookworm again, pin `MACINTOSHPI_REF` in `.env` to the last known-good commit and file an issue upstream.

---

## 🔧 Project Components

| Tool | Description |
|------|-------------|
| [Basilisk II](https://basilisk.cebix.net) | 68K emulator — Mac OS 7 (System 7.5.5) and Mac OS 8 |
| [SheepShaver](https://sheepshaver.cebix.net) | PowerPC emulator — Mac OS 9 |
| [VICE](https://vice-emu.sourceforge.io) | Commodore 64/128/PET emulator |
| MacintoshPi Virtual Modem | `tty0tty` + `tcpser` — connects any of the above (or Raspberry Pi OS itself) to telnet BBSs |
| [CDEmu](https://cdemu.sourceforge.io) | Mounts CD/DVD images (iso/toast/cue/bin/mds/mdf) as `/dev/sr0` |
| MacintoshPi Launcher | The `mac` command — boots a given system at its optimal resolution, with startup chimes |
| [SyncTERM](https://syncterm.bbsdev.net) | Full-screen BBS terminal, compiled against SDL |

Full details, ROM/software sourcing, and dual-boot-with-BMC64 instructions: [upstream's README](https://github.com/jaromaz/MacintoshPi#readme).

---

## Deployment

```bash
./deploy.sh   # → Environments → MacintoshPi → FAST
```

or directly:

```bash
chmod +x run.sh
./run.sh
```

## 🎛️ Deployment Policies

| Policy | Action |
|--------|--------|
| `FAST` | First run: clones upstream and runs `build_all.sh` (~2 hours). Already deployed: no-op status check — **never re-downloads your Mac OS disks**. |
| `CLEAN` | Force a full reinstall from a fresh clone — **overwrites every Mac OS hard disk image**. Confirm you don't need anything on them first. |
| `STOP` | Stops the virtual modem systemd service. Mac OS/VICE sessions are interactive foreground processes (exit with `CTRL+SHIFT+ESC`), not background services, so there's nothing else to pause. |
| `TEARDOWN` | Stops and disables the virtual modem service, clears the deployed marker (so the next FAST reinstalls). Leaves installed files in place — use `WIPE` to actually remove them. |
| `INFO` | Lists install directories and useful commands. |
| `WIPE` | Deletes `/usr/share/macintoshpi`, `/etc/macintoshpi`, and the vendored source checkout — **including every Mac OS hard disk image**. Your `~/Downloads` shared folder is untouched. |

Custom actions (in `deploy.sh`'s per-environment menu) let you reinstall a single component — Mac OS 9, Mac OS 8, Mac OS 7, VICE, CDEmu, Virtual Modem, or SyncTERM — without touching the others.

---

## 💡 Useful Commands

```bash
mac os9                    # Launch Mac OS 9 (SheepShaver), full screen — CTRL+SHIFT+ESC to quit
mac os8                    # Launch Mac OS 8 (Basilisk II)
mac os7                    # Launch Mac OS 7 / System 7.5.5 (Basilisk II)
mac os9 file.img           # Launch with an extra .img/.dsk mounted as a second drive
mac os9-768                # Reboot into 768-row resolution, then auto-launch Mac OS 9

cdload image.toast         # Mount a CD/DVD image (appears as /dev/sr0 and on the Mac desktop)
cdunload                   # Unmount it

sudo systemctl status vmodem    # Virtual modem status
sudo systemctl restart vmodem   # Restart (needed after every kernel update)
nano /etc/vmodem.conf           # Change modem speed (default 2400 bps)
```

`~/Downloads` is shared with every emulated Mac OS as a "Unix" drive — copy files both ways (apps can't be launched directly from it). Software must predate 2000 to run against these ROMs; see upstream's README for download sources (Macintosh Garden, Macintosh Repository, etc.) and the three install methods depending on file type (`.sit`/`.toast`, `.sit`/`.img`/`.dsk`, plain `.sit`).
