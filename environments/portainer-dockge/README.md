# Portainer + Dockge — Container Visualization & Management

Two complementary web UIs for seeing and managing what's actually running across this Pi's Docker environments: **Portainer** for full container/network/volume/image management with a live topology view, and **Dockge** for lighter, compose-file-focused stack management. Split into their own environment (rather than folded into an existing one) because they're general-purpose Docker tooling, not tied to any single service stack — they're just as useful for `pihole-wireguard` as for `ntopng` or anything else deployed on this Pi.

Deploy one, both, or neither — they're independent services in the same `docker-compose.yml` and don't depend on each other.

## 📂 Services & Ports

| Service | Container | Port | Purpose |
|---------|-----------|------|---------|
| [Portainer CE](https://www.portainer.io/) | `portainer` | 9000 (HTTP), 9443 (HTTPS) | Full container/network/volume/image management UI, live topology view |
| [Dockge](https://github.com/louislam/dockge) | `dockge` | 5001 (HTTP) | Lightweight compose-stack management UI (start/stop/edit/logs per stack) |

Both are confirmed multi-arch (`amd64`/`arm64`/`armv7`) directly against the Docker Hub registry API — no local build required on a Pi.

---

## 🛠️ Prerequisites

**Docker & Compose Plugin Installed** — see the repo root `README.md` if you haven't set this up yet.

---

## 🚀 Deployment & Automation Guide

### 1. Configure your environment

```bash
cd environments/portainer-dockge
cp .env.example .env
# Edit ports if the defaults don't fit your setup
```

Or use the repo's interactive `deploy.sh` menu, which walks you through the same `.env` fields.

### 2. Deploy

```bash
./run.sh
```

### 3. Create the Portainer admin account — within 5 minutes

Visit `http://<pi-ip>:9000` **immediately** after first deploy. Portainer gives you a 5-minute window after its first start to create the initial admin account; miss it and the container times out the setup form. If that happens, `docker restart portainer` gets you a fresh 5-minute window.

Dockge has no such timeout — visit `http://<pi-ip>:5001` whenever convenient and create your account there.

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

### Local Directories (in `environments/portainer-dockge/`)

| Directory | Contents |
|-----------|---------|
| `./dockge-data/` | Dockge's own app state (settings, terminal history) |
| `./stacks/` | Dockge's compose-stack directory — any stacks you create/import through its UI |

### Named Docker Volumes

| Volume | Contents |
|--------|---------|
| `portainer_data` | Portainer's own app state — users, endpoints, stacks it manages |

---

## 🖥️ Desktop Integration

Run `../../install-desktop-entries.sh` (or the `[Desktop] Install Desktop Entries` option in `deploy.sh`) after deploying to add application-menu and Desktop icon shortcuts, grouped in their own **Portainer + Dockge** submenu.

| Desktop entry | Opens |
|:---|:---|
| **Portainer** | `http://localhost:<PORTAINER_PORT>` in default browser |
| **Dockge** | `http://localhost:<DOCKGE_PORT>` in default browser |
| **Portainer + Dockge Info** | This environment's generated `post-deploy-info.html` in default browser |

Port values are read from your `.env` at install time. Re-run the script if you change ports.

---

## 💡 Useful Commands

```bash
# Follow live logs
docker logs -f portainer
docker logs -f dockge

# Full stack status
docker compose ps

# Pause / resume without losing data
REBUILD_POLICY=STOP ./run.sh
REBUILD_POLICY=FAST ./run.sh

# Full teardown (data directories untouched)
REBUILD_POLICY=TEARDOWN ./run.sh
```

---

## 🔒 Security & Design Notes

### Both containers mount `/var/run/docker.sock` read-write

This is **root-equivalent access to the host**, not a sandboxed permission — anyone who can reach either web UI, or anyone who compromises either container image, can create a privileged container, mount the host filesystem, and take over the whole Pi. Neither UI's own login screen is a substitute for network-level access control:

- Only deploy this environment on a trusted LAN.
- Set a strong password for both Portainer and Dockge the moment you create their accounts.
- If you're already running (or plan to run) a reverse proxy + auth gate in front of other services on this Pi (see `docs/future-enhancements/`), put both of these UIs behind it too — they're at least as sensitive as anything else on the network.

### Portainer's 5-minute initial-setup window

Documented Portainer behavior: the very first time the container starts, it opens a short window (5 minutes) to create the initial admin account before the setup form times out for security reasons. If you miss it, `docker restart portainer` (or re-running `./run.sh`) gives you a new window — no data is lost, since nothing was created yet.

### Why Dockge's stacks directory is separate from this repo's `environments/`

Dockge expects to own and directly edit whatever directory it points at (`DOCKGE_STACKS_DIR`) — it writes `docker-compose.yml` files there itself and calls `docker compose` against them directly, bypassing this repo's own `run.sh`/`deploy.sh`/`info.sh`/backup lifecycle entirely. Pointing it at this repo's own `environments/` directory would let Dockge silently rewrite or redeploy environments outside of that lifecycle (no `info.sh` manifest tracking, no consistent `.env` handling, no desktop-entry refresh). Instead, `run.sh` gives Dockge its own scratch directory (`./stacks`, computed as an absolute path since Dockge's bind mount requires host-side and container-side paths to match exactly) — use Dockge for stacks you want to manage *outside* this repo's structure, and this repo's own `deploy.sh`/`run.sh` scripts for everything under `environments/`.

---

## 🩺 Troubleshooting

### Dockge stack actions fail with a path-related error

Dockge invokes `docker compose` against `DOCKGE_STACKS_DIR` via the mounted Docker socket, which talks to the **host's** dockerd — not a path inside the `dockge` container. If you've moved this repo's clone location, just re-run `./run.sh`; it recomputes `DOCKGE_STACKS_DIR` as an absolute path from wherever the repo currently lives and recreates the container with the corrected bind mount.

### Portainer setup form says the window expired

`docker restart portainer` and revisit `http://<pi-ip>:9000` right away — see [Portainer's 5-minute initial-setup window](#portainers-5-minute-initial-setup-window) above.
