# ntopng — Deep Traffic Analysis

Deep per-flow network traffic analysis for your LAN: DPI (nDPI), historical/timeseries trends, top talkers, protocol breakdown. Split out into its own environment (rather than an on/off toggle bundled into `pihole-wireguard`) because it's genuinely heavyweight — DPI packet inspection plus its own Redis instance — and a Pi already running a busy stack may not have headroom for it alongside everything else.

If you just want simple always-on bandwidth/protocol stats with a much smaller footprint, `pihole-wireguard`'s bundled `darkstat` service covers that more cheaply. Reach for this environment specifically when you need per-flow DPI and historical trend data that darkstat doesn't provide.

## 📂 Services & Ports

| Service | Container | Port | Purpose |
|---------|-----------|------|---------|
| [ntopng](https://www.ntop.org/products/traffic-analysis/ntop/) | `ntopng` | 3002 (web) | Deep per-flow traffic analysis, DPI (nDPI), and historical trends |
| ntopng-redis | `ntopng-redis` | *(internal, loopback-only)* | Backs ntopng's historical/timeseries data |

---

## 🛠️ Prerequisites

1. **Docker & Compose Plugin Installed** — see the repo root `README.md` if you haven't set this up yet.
2. **A network interface to capture on** — `NTOPNG_INTERFACES` in `.env` must name a real interface visible via `ip link show` on the host (defaults to `eth0`).

---

## 🚀 Deployment & Automation Guide

### 1. Configure your environment

```bash
cd environments/ntopng
cp .env.example .env
# Edit NTOPNG_INTERFACES / NTOPNG_PORT if the defaults don't fit your setup
```

Or use the repo's interactive `deploy.sh` menu, which walks you through the same `.env` fields.

### 2. Deploy

```bash
./run.sh
```

First deploy builds the `ntopng` image locally (see [ARM builds](#arm-builds--why-this-is-built-locally) below) — this can take a few minutes on a Pi. `ntopng-redis` is pulled normally.

### 3. Log in

Visit `http://<pi-ip>:<NTOPNG_PORT>` (default port `3002`). First login is `admin`/`admin` — you'll be prompted to change it immediately; there's no env var to pre-seed a different password.

---

## 🎛️ Deployment Policies

Select a policy when deploying from the `deploy.sh` menu, or set `REBUILD_POLICY` when running `./run.sh` directly:

| Policy | Action |
|--------|--------|
| `FAST` | Start stack if not running; otherwise reconcile against `docker-compose.yml` (no rebuild) so config-only edits still take effect |
| `STOP` | Pause containers (resumable with FAST) |
| `TEARDOWN` | Stop + remove containers; data directories untouched |
| `CLEAN` | Pull/rebuild fresh, then stop + remove + redeploy |
| `INFO` | List data directories with sizes and useful commands |
| `WIPE` | Delete persisted data directories (irreversible — back up first) |

---

## 💾 Data Directories

### Local Directories (in `environments/ntopng/`)

| Directory | Contents |
|-----------|---------|
| `./ntopng-data/` | ntopng's own local state (host/interface config, license if any) |
| `./ntopng-redis-data/` | ntopng's Redis-backed historical/timeseries data — per-flow trends over days/weeks |

No named Docker volumes — everything is a host bind mount, picked up automatically by the repo's `backup.sh`.

---

## 🖥️ Desktop Integration

Run `../../install-desktop-entries.sh` (or the `[Desktop] Install Desktop Entries` option in `deploy.sh`) after deploying to add application-menu and Desktop icon shortcuts, grouped in their own **ntopng** submenu.

| Desktop entry | Opens |
|:---|:---|
| **ntopng** | `http://localhost:<NTOPNG_PORT>` in default browser |
| **ntopng Info** | This environment's generated `post-deploy-info.html` in default browser |

Port values are read from your `.env` at install time. Re-run the script if you change ports.

---

## 💡 Useful Commands

```bash
# Follow live logs
docker logs -f ntopng
docker logs -f ntopng-redis

# Full stack status
docker compose ps

# Pause / resume without losing data
REBUILD_POLICY=STOP ./run.sh
REBUILD_POLICY=FAST ./run.sh

# Full teardown (data directories untouched)
REBUILD_POLICY=TEARDOWN ./run.sh
```

---

## 🔒 Security Notes

### ntopng ships with default admin/admin credentials

There's no env var to pre-seed a different password — it always starts with the default `admin`/`admin` login and prompts you to change it the first time you sign in. Change it immediately on first login; until you do, anyone who can reach `NTOPNG_PORT` has full access to per-flow traffic data for your whole LAN.

### ntopng-redis is bound to loopback only

Both `ntopng` and `ntopng-redis` run with `network_mode: host` (needed for raw packet capture on the real interface) — this means Docker's bridge-network service discovery doesn't apply between them, so `ntopng` reaches Redis over `127.0.0.1:6379` rather than the `ntopng-redis` container name. `ntopng-redis` is started with `--bind 127.0.0.1 --protected-mode yes` specifically because host networking would otherwise expose an unauthenticated Redis instance to your entire LAN, not just this Pi.

---

## 🩺 Troubleshooting

### ARM builds — why this is built locally

**The official `ntop/ntopng` Docker image only publishes `linux/amd64`** — no ARM build exists under any tag, confirmed against Docker Hub's own API. Pulling it on a Pi crash-loops with `docker logs ntopng` showing `exec /run.sh: exec format error`.

Because of this, `ntopng` is **built locally** from `./Dockerfile` instead of pulled — `docker compose build` always runs natively on whatever CPU it's invoked on, so building it on the Pi itself targets the Pi's real architecture (arm64/armhf) automatically. The Dockerfile installs ntopng from ntop's own apt repository (`packages.ntop.org/RaspberryPI/apt-ntop.deb`), closely mirroring ntop's own official ARM64 build recipe ([`Dockerfile.ntopng_arm64.dev`](https://github.com/ntop/docker-ntop/blob/master/Dockerfile.ntopng_arm64.dev)).

This local-build path is unverified on real Raspberry Pi hardware as part of this repo — in particular, whether ntop's Raspberry-Pi-specific apt repo has packages for your exact Debian release (Bookworm vs. Trixie) isn't something that could be confirmed from a sandboxed dev environment (`packages.ntop.org` is outside what that environment could reach at all during development). If `docker compose build ntopng` (or the `ntopng` step during `./run.sh`) fails, the build log will show which apt step failed — that's the first thing to check.

### High CPU/memory usage

DPI packet inspection is inherently CPU-intensive, and `ntopng-redis`'s historical data grows over time. If your Pi is under load, check `docker stats ntopng ntopng-redis` — reducing the number of interfaces in `NTOPNG_INTERFACES`, or periodically clearing old data in `./ntopng-redis-data`, are the two main levers.
