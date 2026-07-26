# SheepShaver — Classic Mac OS (7–9.0.4) in Docker

Wraps [cmiles74/docker-sheepshaver](https://github.com/cmiles74/docker-sheepshaver): a Debian Wheezy container with [SheepShaver](https://sheepshaver.cebix.net) (PowerPC Mac emulator) built from source, forwarded to the host's X11 display and audio.

---

## ⚙️ Why This Needs a Custom `run.sh`

The upstream image needs a fully interactive, privileged, X11-forwarded `docker run` — not a background service stack, so a plain `docker-compose.yml` doesn't fit (same shape as `dragonos-sdr`/`kali-pentest`):

- **X11 forwarding** — mounts `/tmp/.X11-unix` and sets `DISPLAY` so the SheepShaver window (and its GUI config screen) shows up on the host desktop.
- **`--privileged` mode** — required for the container to access `/dev/sheep_net`, a custom kernel network device, when using bridged networking.
- **Host audio passthrough** — `/dev/snd` plus the host's PulseAudio socket, so the emulated Mac has sound.
- **User-provided ROM/disk files** that must exist on the host before the emulator can boot — `run.sh` checks for these and warns rather than silently failing.

---

## ⚠️ About the Debian Wheezy Base

SheepShaver's build needs **GCC 4.6** specifically — newer GCCs fail to compile it cleanly (ABI/compile errors). The only realistic way to get that toolchain today is an EOL Debian release, so the `Dockerfile` deliberately stays on `debian:wheezy` (EOL since 2016) rather than porting the emulator forward.

Two fixes on top of upstream's own `Dockerfile` were needed just to make it buildable today, since Wheezy was pulled from Debian's regular mirrors:

- **`apt` sources repointed to `archive.debian.org`** — `deb.debian.org` 404s on Wheezy now; the archive keeps EOL releases indefinitely.
- **`Acquire::Check-Valid-Until "false"`** — the archived `Release` file's `Valid-Until` timestamp is long past, which `apt` treats as an untrusted/expired repo by default. This is the standard, widely-documented fix for building against any archived EOL Debian/Ubuntu suite, not something specific to this project.

**This hasn't been verified against a live `docker build`** in the environment this was set up in (no Docker daemon available there) — flagging that plainly rather than claiming it's confirmed working. If the build still fails on your hardware, check `archive.debian.org`'s current layout for Wheezy and adjust `Dockerfile`'s `sources.list` accordingly.

### Architecture

SheepShaver's own PowerPC JIT is the only emulation layer this image is designed for. Running the **x86-only** Wheezy container itself under cross-architecture emulation (e.g. via QEMU on a Raspberry Pi or Apple Silicon Mac) stacks a second layer of emulation underneath the first and is likely to be very slow, if it works at all. This is best run on an x86_64 Docker host; ARM hosts are unsupported territory for this particular environment (unlike the rest of this repo, which increasingly targets Pi/ARM directly).

---

## Before You Deploy

You need, on the host:

1. **A Macintosh ROM file** — must predate 2000 (2000+ ROMs don't work with SheepShaver). See [Macintosh Repository](https://www.macintoshrepository.org/7038-all-macintosh-roms-68k-ppc).
2. **A hard disk image** — create it through SheepShaver's own GUI on first run (leave `SS_NO_GUI=false` until you've done this), or bring an existing one.
3. **Installation media** (optional, for a fresh install) — an ISO/`.toast` file, mounted read-only. A writable install image makes the emulated Mac think it's a "copy" and refuse to boot.

Drop the ROM and disk image into `data/` (or point `SS_DATA_PATH` in `.env` elsewhere), matching the filenames in `.env.example`'s `SS_ROM`/`SS_DISK`.

---

## Deployment

```bash
cp .env.example .env   # edit SS_ROM/SS_DISK/etc. to match your files
./deploy.sh             # → Environments → SheepShaver → FAST
```

or directly:

```bash
chmod +x run.sh
./run.sh
```

## 🎛️ Deployment Policies

| Policy | Action |
|--------|--------|
| `FAST` | Build the image if missing, then launch. If already running, just reports that (SheepShaver is a single interactive session — nothing to reattach to). |
| `CLEAN` | Rebuild the image from scratch (`--no-cache`) before launching. |
| `STOP` | Stops the container if still up. |
| `TEARDOWN` | Stops and removes the container. ROM/disk under `data/` are untouched. |
| `INFO` | Lists data directories and useful commands. |
| `WIPE` | Deletes `data/` and `shared/` — **including your ROM and hard disk image**. |

---

## Networking

Default is **`SS_NET=slirp`** — user-mode networking, no host device required. Switching to **`SS_NET=ether`** (bridged) needs a `sheep_net` kernel module built on the host from [macemu's NetDriver](https://github.com/cebix/macemu/tree/master/BasiliskII/src/Unix/Linux/NetDriver) — the same module the `macintoshpi` environment in this repo builds for its own Basilisk II/SheepShaver setup. `run.sh` checks for `/dev/sheep_net` and falls back to `slirp` automatically if it's missing and `SS_NET=ether` was requested.

---

## 💡 Useful Commands

```bash
docker build -t pi-bootstrap-sheepshaver .          # Rebuild the image manually
docker run --rm -it --entrypoint bash pi-bootstrap-sheepshaver   # Shell into the image
ls data/                                             # Your ROM/disk/config
ls shared/                                           # Files shared with the emulated Mac (appears as an extra drive)
```

**Troubleshooting a black screen**: turn off the GUI (`SS_NO_GUI=true` in `.env`) and rely on the command-line settings instead — this is a known SheepShaver quirk, not specific to this container.
