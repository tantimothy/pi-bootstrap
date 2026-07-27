# Classic Mac VNC — Basilisk II / SheepShaver over VNC

Runs [Basilisk II](https://basilisk.cebix.net) (Mac OS 7/8, 68k) or
[SheepShaver](https://sheepshaver.cebix.net) (Mac OS 9, PowerPC) — same
[kanjitalk755/macemu](https://github.com/kanjitalk755/macemu) source this
repo's own `macintoshpi` environment uses — headless behind a VNC server,
so you can connect from any machine with a VNC client. No physical
monitor/keyboard on the Pi needed.

---

## ⚠️ Read Before Deploying

- **UNVERIFIED**: this environment's `Dockerfile` hasn't been build-tested
  against a real Docker daemon — none was available while writing it. The
  emulator source, pinned revision, ROM/hard-disk-image URLs, and `.cfg`
  shape are all copied directly from `macintoshpi`'s own build scripts,
  which *are* confirmed working on real Raspberry Pi hardware — only "built
  against Debian's ordinary SDL2 and run headless under Xvfb + x11vnc
  instead of macintoshpi's own KMS-only build" is new here. If the first
  `docker compose build` hits a missing dependency or a configure/build
  failure, that's expected territory for a from-source build that's never
  actually run — check the build log against the exact `./configure`
  flags in `Dockerfile` before assuming something's fundamentally wrong.
- **ROM and hard-disk images are fetched from the same third-party sources
  `macintoshpi` itself already uses** (a community ROM archive on GitHub,
  and pre-built System 7/8/9 hard-disk images from a personal
  archive server) — not something Apple officially distributes. This repo
  isn't redistributing anything itself; `entrypoint.sh` just fetches the
  same URLs on first start, same as `macintoshpi`'s `build_all.sh` already
  does. If either source ever goes away, first start will fail with a
  fetch error — nothing this repo can control.
- **VNC has no built-in encryption.** Set `VNC_PASSWORD` in `.env` before
  exposing `VNC_PORT` beyond localhost — see `.env.example`.
- **No audio, no CD-ROM, no real hardware modem/BBS networking** — this is
  a deliberately lighter alternative to `macintoshpi` (see "vs.
  macintoshpi" below), not a replacement for it.

---

## Why This Needs Its Own Environment (vs. `macintoshpi`)

`macintoshpi`'s own SDL2 build is compiled with `--disable-video-x11
--disable-video-wayland` and only `--enable-video-kmsdrm` — full-screen,
direct-to-display, no window manager, *by design* (see that environment's
own README: "the whole point of the project is avoiding the overhead of a
window manager"). Nothing built against that SDL2 can ever open an X
display, so VNC was never an option there short of recompiling SDL2 itself
with X11 support — a real fork of `macintoshpi`'s own build, not a config
toggle.

This environment sidesteps that entirely: it builds the same emulator
source against Debian's *ordinary* `libsdl2-dev` package (X11-capable out
of the box), runs it inside a headless `Xvfb` virtual display, and shares
that display over VNC with `x11vnc`. No patching of Basilisk
II/SheepShaver's own build needed — only the video backend they're linked
against differs.

**Trade-off:** you lose everything `macintoshpi` provides beyond the
emulator itself — real hardware modem/telnet-BBS networking (`sheep_net`
kernel driver), CDEmu CD-image mounting, VICE (Commodore 64/128/PET),
SyncTERM, dual-boot-with-BMC64, boot-time resolution switching. If you
need any of those, use `macintoshpi` (with a monitor attached) instead.

---

## Performance on arm64 / Apple Silicon

SheepShaver (Mac OS 9, PowerPC) has **no JIT on arm64 hosts** — it falls
back to pure interpretation there, noticeably slower than the JIT-
accelerated path it gets on x86_64. This isn't specific to this
environment; it's SheepShaver's own upstream limitation, confirmed
directly (not assumed) — see
[kanjitalk755/macemu](https://github.com/kanjitalk755/macemu) and the
[E-Maculation](https://www.emaculation.com/doku.php/sheepshaver) community
wiki. Basilisk II (Mac OS 7/8, 68k) doesn't share this specific limitation
the same way, though this environment disables JIT unconditionally for
both regardless (`jit false` in the generated `.cfg`, matching
`macintoshpi`'s own default) — for stability across whatever architecture
this actually builds on, not just performance. If Mac OS 9 feels sluggish
on your Pi (or any arm64/Apple Silicon Docker host), that's expected;
Mac OS 7/8 will generally feel snappier.

---

## Deployment

```bash
./deploy.sh   # → Environments → Retro Computing → Classic Mac VNC → FAST
```

or directly:

```bash
docker compose up -d --build
```

First start downloads the selected Mac OS version's ROM and hard-disk
image (cached under `data/macos<version>/` afterward — not re-downloaded
on later starts or redeploys). Then connect any VNC client to
`<pi-ip>:5900` (or whatever `VNC_PORT` you set).

## ⚙️ Configuration (`.env`)

| Variable | Default | What it does |
|----------|---------|---------------|
| `MAC_OS_VERSION` | `8` | `7` (System 7.5.5, Basilisk II), `8` (Mac OS 8, Basilisk II), or `9` (Mac OS 9, SheepShaver). Each keeps its own saved disk under `data/macos<version>/` — switching this later doesn't touch the others. |
| `VNC_PORT` | `5900` | Host port to connect a VNC client to. |
| `VNC_PASSWORD` | *(empty)* | Strongly recommended — see the warning above. |
| `SCREEN_WIDTH` / `SCREEN_HEIGHT` | `800` / `600` | Emulated screen resolution — the emulator's own window fills this exactly. |

Changing `MAC_OS_VERSION` after first deploy switches which OS boots on
the *next* restart (FAST is enough — no rebuild needed, since the
emulator binaries for all three versions are already baked into the
image).

## 🎛️ Deployment Policies

Standard `docker-compose.yml` semantics (`FAST`/`STOP`/`TEARDOWN`/`CLEAN`/
`INFO`/`WIPE`) — see
[ntopng](../ntopng/README.md) or
[pi-barebones](../pi-barebones/README.md) for how the generic dispatcher
handles each. `WIPE` deletes `data/` — the emulated Mac's saved disk(s)
along with it; ROM files just get re-downloaded on the next start.

---

## Sources

- Emulator: [kanjitalk755/macemu](https://github.com/kanjitalk755/macemu)
  (Basilisk II + SheepShaver), same pinned revision this repo's own
  [macintoshpi](../macintoshpi/README.md) environment uses.
- ROM files: [macmade/Macintosh-ROMs](https://github.com/macmade/Macintosh-ROMs)
  (Mac OS 7/8) and a third-party S3 bucket (Mac OS 9) — the same sources
  `macintoshpi`'s own `build_all.sh` already fetches from.
- Hard-disk images: a personal archive server (`homer-retro.space`) that
  `macintoshpi`'s own build scripts also pull pre-built System 7/8/9
  installs from.
- SheepShaver's `NATMEM_OFFSET` ARM fix: the same patch file
  `macintoshpi`'s own build applies, fetched directly from that project's
  repo so it stays in sync with upstream rather than a duplicated copy
  drifting out of date.
