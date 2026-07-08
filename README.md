# 🐳 Pi Bootstrap

A lightweight TUI hub for deploying and managing containerized environments on a Raspberry Pi. Run `deploy.sh` to get an interactive menu — select an environment, configure it, and it handles the rest.

```bash
# Clone and run
git clone https://github.com/tantimothy/pi-bootstrap.git
cd pi-bootstrap
./deploy.sh
```

Or run directly on a fresh Pi without cloning:

```bash
curl -sSL -H "Authorization: token <your_github_token>" \
  -H "Accept: application/vnd.github.v3.raw" \
  https://tantimothy:<your_github_token>@raw.githubusercontent.com/tantimothy/pi-bootstrap/master/deploy.sh | bash
```

---

## 🗂️ Environments

| Environment | Description |
|:---|:---|
| [dragonos-sdr](environments/dragonos-sdr/) | Software-defined radio toolkit — GQRX, GNU Radio, RTL-SDR utilities, HackRF tools, ADS-B aircraft tracking (dump1090, readsb), rtl_433 sensor decoding, APRS packet radio (direwolf), ACARS aircraft messages (acarsdec), FM/pager/EAS decoding (multimon-ng) |
| [pihole-wireguard](environments/pihole-wireguard/) | Network stack — Pi-hole DNS ad-blocker + WireGuard VPN (wg-easy) + full monitoring suite (Prometheus, Grafana, Uptime Kuma, node/speedtest/blackbox exporters) + PADD terminal dashboard |
| [kali-pentest](environments/kali-pentest/) | Headless Kali Linux pentest environment — wireless attacks (Wifite2, aircrack-ng suite, hcxdumptool), network MITM (Bettercap, Nmap, tshark), exploitation (Metasploit), wardriving (Kismet + GPS) |
| [internet-pi](environments/internet-pi/) | Ansible-managed Raspberry Pi — Pi-hole, Prometheus, Grafana, Speedtest Exporter, Blackbox Exporter, Node Exporter (based on [geerlingguy/internet-pi](https://github.com/geerlingguy/internet-pi)) |
| [nanoclaw](environments/nanoclaw/) | AI / LLM tools — Ollama (local model inference), whisper.cpp (speech-to-text), Claude API integration |
| [pi-barebones](environments/pi-barebones/) | Minimal Pi setup — tmux, fastfetch system info, PADD Pi-hole dashboard, custom `.bashrc` tweaks |

---

## 🖥️ Desktop Menu Integration

On a Pi with a desktop environment (LXDE, XFCE, GNOME), run once to register all environments as clickable desktop entries. This is also available as menu options in `./deploy.sh` — "[Desktop] Install Desktop Entries" and "[Desktop] Uninstall Desktop Entries":

```bash
./install-desktop-entries.sh

# To remove them
./install-desktop-entries.sh --uninstall
```

This installs entries to `~/.local/share/applications/` (the application menu) **and** mirrors each one onto `~/Desktop` (or your actual XDG Desktop folder, if it differs) as a clickable icon — copied there executable and, where `gio` is available, marked "trusted" so it launches directly instead of showing as inert text or prompting to trust it on every click. Each environment also gets its own submenu (e.g. "Pi-hole + WireGuard") in the application menu, instead of its entries scattering into existing folders like Internet or System Tools. What each type does:

| Entry type | How it opens |
|:---|:---|
| GQRX, GNU Radio Companion | X11 socket passthrough — window appears directly on the Pi desktop |
| SDR menu, Kali, NanoClaw | Opens in your desktop's default terminal emulator |
| Pi-hole, Grafana, Uptime Kuma, WireGuard, darkstat, Dozzle | A `Type=Link` desktop entry pointing at `http://localhost:<port>` — opened directly by the desktop environment's own default URL handler, no wrapper script involved |
| `<Environment> Info` | Same `Type=Link` mechanism, pointed at that environment's generated `post-deploy-info.html` (see below) via a `file://` URL |

Ports for the web UI entries are read from each environment's `.env` at install time, so they stay correct after reconfiguration. Re-run the script if you change ports.

`Type=Link` entries need the desktop environment to have *some* default handler registered for `http://`/`file://` URLs (typically automatic once a browser is installed) — on a minimal setup with no browser ever configured as default, these can silently no-op on click. Stock Raspberry Pi OS Desktop images ship Chromium pre-registered, so this is expected to just work there.

Only environments that are actually deployed get entries. Re-running the installer keeps the menu in sync: it registers entries for anything newly deployed, and removes entries for anything that isn't (or was undeployed since) — so stale shortcuts don't linger. "Deployed" is detected differently per environment, since each has a different way of showing it's actually running rather than just built:

| Environment | "Deployed" signal |
|:---|:---|
| pihole-wireguard | The `pihole` container exists |
| nanoclaw | The `nanoclaw.service` systemd unit is registered |
| dragonos-sdr, kali-pentest | A local `.deployed` marker that `run.sh` creates the moment it launches the container (these run with `--rm`, so a cached image alone doesn't prove the environment was actually used) |

New entries appear in the menu automatically on Raspberry Pi OS; no manual refresh is needed.

### 📄 Post-deploy info page

Every environment's `info.sh` (both right after `run.sh` deploys it, and any time you open "INFO" from `./deploy.sh`) also (re)generates `environments/<env>/post-deploy-info.html` — a self-contained HTML page with the same data directories, useful commands, and notes as the terminal listing, except any web UI URLs are clickable links. It's not tracked in git (regenerated fresh each time) but is opened directly by that environment's `<Environment> Info` desktop entry above.

---

## 💾 Backup & Restore

`backup.sh` builds one archive containing every deployed environment's persistent data (data directories + named Docker volumes) and, by default, each environment's `.env` file. This is also available as menu options in `./deploy.sh` — "[Backup] Create Backup Archive" and "[Backup] Restore From Archive":

```bash
./backup.sh                    # back up every environment, .env included
./backup.sh --no-env           # exclude .env files (data dirs/volumes only)
./backup.sh -o /path/to/dir    # write the archive somewhere other than the current directory
```

The archive is only ever written **locally** — copying it to another machine (`scp`, `rsync`, a USB drive, cloud sync, AirDrop, whatever) is up to you. That keeps this deliberately dependency-free: no assumptions about SSH keys, network access, or the destination machine's OS. A `.tar.gz` opens the same way on Linux, macOS, and Windows.

```bash
./restore.sh <path-to-backup.tar.gz>              # interactive: pick which environment to restore
./restore.sh <path-to-backup.tar.gz> <env-name>   # restore one specific environment
./restore.sh <path-to-backup.tar.gz> all          # restore every environment in the archive
```

Restoring works the same whether it's the same Pi or a brand new machine — clone this repo, run `./restore.sh`, then redeploy each restored environment via `./deploy.sh` (or its `run.sh`, `REBUILD_POLICY=FAST`). Each environment's data directories are restored to their exact original absolute paths (some live inside `environments/<env>/`, others under `$HOME` — `restore.sh` preserves whichever it was), and named Docker volumes are recreated and repopulated from their own nested archive inside the backup.

**Security note:** since `.env` files (containing Pi-hole/Grafana passwords, WireGuard keys config, API tokens, etc.) are included by default, treat a backup archive as sensitive — it's only as safe as wherever you send it.

---

## 🏗️ How It Works

### Routing Priority

`deploy.sh` scans each selected environment folder and picks the first match:

```text
environments/your-env/
│
├── 1. run.sh          →  delegates everything to the script (most flexible)
├── 2. docker-compose.yml  →  runs `docker compose up -d`
└── 3. Dockerfile      →  builds and runs a single container on port 80
```

### Permission Wrapper

`deploy.sh` never assumes the user is in the `docker` group. It tests `/var/run/docker.sock` access and automatically prepends `sudo` if needed, exporting the resolved command as `$DOCKER_CMD` so all child environments inherit it.

### Policy Matrix

Every environment receives a `REBUILD_POLICY` variable:

| Policy | Container behaviour | Image cache |
|:---|:---|:---|
| `FAST` *(default)* | Reuse or reconcile whatever's already running rather than exiting silently stale — the exact mechanism varies by environment (Docker Compose's own config-hash recreate, re-running an idempotent Ansible playbook, or a custom config-drift hash for plain `docker run` environments); see each environment's README for specifics | Reuse local layer cache; rebuild/pull only what's missing |
| `CLEAN` | Build or pull the replacement *before* touching the existing containers, so a failed build/pull leaves the previous working setup untouched instead of leaving nothing running; some environments (e.g. `pihole-wireguard`) also keep the previous container as an explicit rollback fallback | Force `--no-cache` build or fresh `pull`, depending on environment |
| `STOP` | Pause containers (resumable with FAST) | — |
| `TEARDOWN` | Stop + remove containers; data untouched | — |
| `INFO` | Show data directories, sizes, and useful commands (scrollable via `less` in an interactive terminal) | — |
| `WIPE` | Delete persisted data directories (irreversible) | — |

### Secret Pre-Processor

Each environment has a `.env.example` file. `deploy.sh` reads it to:
1. Show each variable's inline `#` comment as a scrollable info card
2. Generate a `dialog` form pre-filled with defaults
3. Write the result to a local `.env` file (gitignored — never committed)

---

## 🛠️ Adding a New Environment

Drop a folder into `environments/` — `deploy.sh` discovers it automatically.

### Folder Layout

```text
environments/
└── my-environment/
    ├── .env.example        # required: drives the TUI config form
    ├── run.sh              # archetype 1: custom script (highest priority)
    ├── docker-compose.yml  # archetype 2: multi-container stack
    └── Dockerfile          # archetype 3: single container (lowest priority)
```

### `.env.example` Format

Every variable needs a `#` comment immediately above it — that comment becomes the form label shown to the user:

```ini
# Name used by the dashboard to track container state.
CONTAINER_NAME=my-app

# Port to expose the web UI on.
WEB_PORT=8080

# Leave blank to force the user to set it explicitly.
API_SECRET_KEY=
```

### `CONTAINER_NAME`

Declare every container the environment manages, space-separated. The orchestrator uses this list for FAST checks, CLEAN teardown, STOP, and INFO:

```ini
# Single container
CONTAINER_NAME=my-app

# Multi-container stack — all names, space-separated
CONTAINER_NAME="pihole wg-easy prometheus grafana"
```

### Archetype 1: `run.sh` (Custom Script)

Use this when you need host network config, kernel drivers, hardware pass-through (USB SDR, Wi-Fi card, GPS), or multi-step pre-deployment logic.

Key rules:
- **Never** hardcode `docker` — use `DOCKER=${DOCKER_CMD:-docker}` to inherit the sudo wrapper
- Source `.env` with `set -a; source "$SCRIPT_DIR/.env"; set +a`
- Create volume paths with `mkdir -p` *before* `docker run` — otherwise Docker creates them as root
- Re-bind TTY with `exec 0</dev/tty` before any `-it` container so it works when invoked via `curl | bash`

```bash
#!/bin/bash
DOCKER=${DOCKER_CMD:-docker}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a; source "$SCRIPT_DIR/.env"; set +a
fi

IMAGE_NAME="my-app:latest"
IMAGE_EXISTS=$($DOCKER images -q "$IMAGE_NAME" 2>/dev/null)

$DOCKER stop "$CONTAINER_NAME" 2>/dev/null
$DOCKER rm   "$CONTAINER_NAME" 2>/dev/null

if [ "${REBUILD_POLICY:-FAST}" = "CLEAN" ] || [ -z "$IMAGE_EXISTS" ]; then
    $DOCKER build --no-cache -t "$IMAGE_NAME" "$SCRIPT_DIR"
fi

mkdir -p "${HOST_DATA_PATH:-$SCRIPT_DIR/data}"

exec 0</dev/tty; exec 1>/dev/tty; exec 2>/dev/tty

$DOCKER run -it --rm \
  --name "$CONTAINER_NAME" \
  -v "${HOST_DATA_PATH:-$SCRIPT_DIR/data}:/data" \
  "$IMAGE_NAME"
```

### Archetype 2: `docker-compose.yml` (Multi-Container Stack)

Docker Compose picks up the generated `.env` automatically. Match every `container_name:` in your compose file to the names in `CONTAINER_NAME`:

```yaml
services:
  myapp:
    container_name: my-app
    image: myimage:latest
    ports:
      - "${WEB_PORT:-8080}:8080"
    restart: unless-stopped
```

### Archetype 3: `Dockerfile` (Single Container Fallback)

No `run.sh` or `docker-compose.yml` needed. The orchestrator builds the image, injects variables via `--env-file .env`, and maps port 80. For anything beyond a basic single-container setup, use Archetype 1 or 2 instead.
