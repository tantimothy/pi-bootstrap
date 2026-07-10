# Portainer — Container Visualization & Management

A web UI for seeing and managing what's actually running across this Pi's Docker environments — containers, networks, volumes, images, live stats, start/stop/exec — with a live topology view. Split out into its own environment (rather than folded into an existing one) because it's general-purpose Docker tooling, not tied to any single service stack — it's just as useful for `pihole-wireguard` as for `ntopng` or anything else deployed on this Pi.

## 📂 Services & Ports

| Service | Container | Port | Purpose |
|---------|-----------|------|---------|
| [Portainer CE](https://www.portainer.io/) | `portainer` | 9000 (HTTP), 9443 (HTTPS) | Full container/network/volume/image management UI, live topology view |

Confirmed multi-arch (`amd64`/`arm64`/`armv7`) directly against the Docker Hub registry API — no local build required on a Pi.

---

## 🛠️ Prerequisites

**Docker & Compose Plugin Installed** — see the repo root `README.md` if you haven't set this up yet.

---

## 🚀 Deployment & Automation Guide

### 1. Configure your environment

```bash
cd environments/portainer
cp .env.example .env
# Edit ports if the defaults don't fit your setup
```

Or use the repo's interactive `deploy.sh` menu, which walks you through the same `.env` fields.

### 2. Deploy

```bash
./run.sh
```

### 3. Create the admin account — within 5 minutes

Visit `http://<pi-ip>:9000` **immediately** after first deploy. Portainer gives you a 5-minute window after its first start to create the initial admin account; miss it and the container times out the setup form. If that happens, `docker restart portainer` gets you a fresh 5-minute window.

Recent Portainer versions (2.43 / 2.39.4+) also require a one-time **setup token** during that window, printed to the container's own logs — grab it with:

```bash
docker logs portainer 2>&1 | grep setup_token
```

Paste the token into the setup screen alongside your chosen username/password. It's consumed the moment setup completes, so there's nothing to save afterward.

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

### Named Docker Volumes

| Volume | Contents |
|--------|---------|
| `portainer_data` | Portainer's own app state — users, endpoints, stacks it manages |

No local bind-mount directories — everything Portainer persists lives in the named volume above.

The volume name is pinned explicitly in `docker-compose.yml` (`name: portainer_data`) rather than left to Compose's default project-name prefixing. Without that, moving or re-cloning this environment into a differently-named directory would silently create a new, empty volume instead of reusing the existing one — orphaning your admin account and any other Portainer settings in the old, differently-prefixed volume. If you deployed this environment before this fix and then renamed/moved the directory, check `docker volume ls` for a leftover volume from the old path (e.g. `portainer-dockge_portainer_data`) — your original data is there, not lost, just disconnected.

---

## 🖥️ Desktop Integration

Run `../../install-desktop-entries.sh` (or the `[Desktop] Install Desktop Entries` option in `deploy.sh`) after deploying to add application-menu and Desktop icon shortcuts, grouped in their own **Portainer** submenu.

| Desktop entry | Opens |
|:---|:---|
| **Portainer** | `http://localhost:<PORTAINER_PORT>` in default browser |
| **Portainer Info** | This environment's generated `post-deploy-info.html` in default browser |

Port values are read from your `.env` at install time. Re-run the script if you change ports.

---

## 💡 Useful Commands

```bash
# Follow live logs
docker logs -f portainer

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

### The container mounts `/var/run/docker.sock` read-write

This is **root-equivalent access to the host**, not a sandboxed permission — anyone who can reach the web UI, or anyone who compromises the container image, can create a privileged container, mount the host filesystem, and take over the whole Pi. The login screen is not a substitute for network-level access control:

- Only deploy this environment on a trusted LAN.
- Set a strong password the moment you create the admin account.
- If you're already running (or plan to run) a reverse proxy + auth gate in front of other services on this Pi (see `docs/future-enhancements/`), put this UI behind it too — it's at least as sensitive as anything else on the network.

### Portainer's 5-minute initial-setup window

Documented Portainer behavior: the very first time the container starts, it opens a short window (5 minutes) to create the initial admin account before the setup form times out for security reasons. If you miss it, `docker restart portainer` (or re-running `./run.sh`) gives you a new window — no data is lost, since nothing was created yet.

---

## 🩺 Troubleshooting

### Setup form says the window expired

`docker restart portainer` and revisit `http://<pi-ip>:9000` right away — see [Portainer's 5-minute initial-setup window](#portainers-5-minute-initial-setup-window) above.

### Clicking "Create user" during setup seems to do nothing

This is a known Portainer UI quirk — the account is often created successfully in the background even though the button appears unresponsive. Reload the page and try logging in with the credentials you just set before assuming it failed. If login also fails, check for a password-length validation error (recent versions require 12+ characters) or an expired setup token/window, per the section above.
