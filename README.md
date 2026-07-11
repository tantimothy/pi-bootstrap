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
curl -fsSL -A "pi-bootstrap-installer" https://raw.githubusercontent.com/tantimothy/pi-bootstrap/master/deploy.sh | bash
```

`raw.githubusercontent.com` is served by a CDN with its own abuse/rate-limiting layer, separate
from the GitHub API's normal limits — it can return a 429 "scraping" page if hit repeatedly in
a short window (e.g. re-running this a few times while testing/debugging) or from a request
that looks like generic bot traffic (no auth, no distinguishing User-Agent). If you hit that,
wait a few minutes and retry, or just use the `git clone` method above instead — it doesn't go
through this raw-content path at all, so it isn't subject to the same rate-limiting.

The `-f` flag matters either way: without it, curl treats any HTTP error response — including
that 429 page — as "success" and pipes its body straight into `bash`, which executes it as
garbled commands instead of failing cleanly.

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
| [ntopng](environments/ntopng/) | Deep per-flow traffic analysis — DPI (nDPI), historical/timeseries trends via Redis. Split out as its own environment since it's heavyweight; pairs well alongside pihole-wireguard on a Pi with headroom to spare |
| [portainer](environments/portainer/) | Container visualization & management — full container/network/volume/image management UI with a live topology view. General-purpose Docker tooling, useful alongside any other environment on this Pi |

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
| Pi-hole, Grafana, Uptime Kuma, WireGuard, darkstat, Dozzle, ntopng, Portainer | Menu: tries `xdg-open`, then falls back through several other browser launchers against `http://localhost:<port>`. Desktop icon: a `Type=Link` entry opened directly by the desktop's default URL handler |
| `<Environment> Info` | Same as above, pointed at that environment's generated `post-deploy-info.html` (see below) via a `file://` URL |

Ports for the web UI entries are read from each environment's `.env` at install time, so they stay correct after reconfiguration. Re-run the script if you change ports.

The menu entry and the Desktop icon for these are deliberately two different desktop-entry flavors, not one file copied to both places: the application menu only lists `Type=Application` entries on some desktop environments (`Type=Link` is silently filtered out of the menu, even though it works fine as a Desktop icon there) — so the menu copy uses `Type=Application` with a browser-fallback `Exec=`, and the Desktop copy uses the simpler `Type=Link`.

Only environments that are actually deployed get entries. Re-running the installer keeps the menu in sync: it registers entries for anything newly deployed, and removes entries for anything that isn't (or was undeployed since) — so stale shortcuts don't linger. "Deployed" is detected differently per environment, since each has a different way of showing it's actually running rather than just built:

| Environment | "Deployed" signal |
|:---|:---|
| pihole-wireguard | The `pihole` container exists |
| ntopng | The `ntopng` container exists |
| portainer | The `portainer` container exists |
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

## 🔍 Checking for Image Updates

`FAST` deliberately doesn't pull a fresh image for a container that's already running (see the Policy Matrix below) — only `CLEAN` does. That means a container can quietly fall behind upstream indefinitely if you only ever redeploy with `FAST`. `check-updates.sh` answers "what's actually out of date right now" without touching anything:

```bash
./check-updates.sh
```

Also available as "Check Updates" under "[Manage] Containers & Images" in `./deploy.sh`, alongside listing/deleting containers and images. For every currently-running container across every environment, it pulls that container's exact image reference fresh (refreshing only Docker's local cache — a running container keeps using the image ID it already started from, so this never disrupts anything live) and compares the freshly-pulled image ID against what's actually running. A mismatch means an update is available but not yet applied.

**Locally-built images** (e.g. `darkstat`, `ntopng`, `dragonos-sdr`, `kali-pentest` — all built from a Dockerfile via `apt-get`, not pulled from a registry) have no tag to `docker pull` and compare, so they're checked differently: `apt-get update` is run live inside the running container (read-only — it only refreshes package-list metadata, nothing is installed or restarted) to see if any installed apt package has a newer version, and the Dockerfile's own `FROM` line is checked by pulling that base tag fresh and comparing it against the image's actual build history. Either one being out of date is reported as an update available; an image with no `apt-get` at all (nothing in this repo currently) would be reported as skipped instead.

A plain `./check-updates.sh` run is purely informational — it never restarts or recreates anything, matching this repo's deliberate choice not to auto-update (see `docs/future-enhancements/pihole-wireguard-additional-services.md`'s "Not recommended: Watchtower" section for why).

To actually apply what it finds, either redeploy that container's whole environment with `REBUILD_POLICY=CLEAN ./run.sh`, or target just the flagged containers:

```bash
./check-updates.sh --apply
```

This re-runs the same scan, then asks individually — one `[y/N]` per flagged container, nothing is ever applied without an explicit yes — whether to recreate it right now. Everything else in that container's environment is left untouched (`docker compose up -d --no-deps --force-recreate <name>` for compose-managed services); locally-built apt images get an actual rebuild first (`docker compose build --no-cache` for compose-managed services, or `lib/deploy-lib.sh`'s shared `deploy_environment()` — the same mechanics `deploy.sh` itself uses — for single-container environments like `dragonos-sdr`/`kali-pentest`, with or without their own `run.sh`) — the new image always finishes building before the old container is touched, so a failed rebuild never leaves you with nothing running. A container whose environment can't be determined is reported and left for you to apply manually.

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

Options 2 and 3 (no `run.sh`) still get the essentials generically, without writing any custom script: `CLEAN` builds/pulls fresh images *before* touching what's currently running (a failed build leaves the old container(s) untouched, same safety property every `run.sh` implements by hand), data directories from `info.sh`'s `DATA_DIRS` are pre-created before Docker ever touches them as a bind-mount target, desktop entries refresh automatically after a successful deploy, and `check-updates.sh --apply` can target them too (including a bare `Dockerfile`-only environment with no `run.sh` at all). This mechanics lives in `lib/deploy-lib.sh`'s `deploy_environment()`, shared by both `deploy.sh` and `check-updates.sh --apply` rather than duplicated between them. What they still can't do without a real `run.sh`: any host-level setup (network config, sysctls, DNS resilience, etc.).

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
    ├── .env.example        # drives the TUI config form — skip only if there's
    │                       # truly nothing to configure (see pi-barebones)
    ├── run.sh              # archetype 1: custom script (highest priority)
    ├── docker-compose.yml  # archetype 2: multi-container stack
    ├── Dockerfile          # archetype 3: single container (lowest priority)
    ├── info.sh             # required — see below
    ├── install-desktop.sh  # recommended if there's a web UI — see below
    └── README.md           # Services & Ports, Data Directories, Desktop
                             # Integration, Useful Commands, security notes
```

`info.sh` and `install-desktop.sh` aren't one of the three deploy archetypes — every environment needs its own regardless of which archetype it uses. They're covered separately below since they're easy to miss (nothing on the `deploy.sh` discovery path requires them, but other scripts silently depend on them).

### `.env.example` Format

Only skip this file if the environment genuinely has nothing to configure — no ports, no secrets, no container names to declare (`pi-barebones` is the one environment that does without it). Every variable needs a `#` comment immediately above it — that comment becomes the form label shown to the user:

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

### `info.sh` (Required)

Every one of the seven current environments has one — it's not optional in practice. `run.sh` calls it at the end of every deploy for the post-deploy summary; `deploy.sh`'s `INFO` and `WIPE` policies delegate to it entirely (they don't touch containers directly at all); `backup.sh` invokes it with a `manifest` action to discover which data directories and named volumes to archive; and it's what generates `post-deploy-info.html`, the page the desktop "Info" icon opens. Skip it and INFO, WIPE, backup, and the info desktop entry all silently do nothing for that environment.

All the actual logic lives in `lib/info-lib.sh` — your `info.sh` just sets some variables and arrays, then sources it:

```bash
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ACTION="${1:-list}"

[ -f "$SCRIPT_DIR/.env" ] && { set -a; source "$SCRIPT_DIR/.env"; set +a; }

DATA_DIRS=("$SCRIPT_DIR/my-app-data")
DATA_DESCRIPTIONS=("My app's config and database")
INSTALL_DIRS=(); INSTALL_DESCRIPTIONS=()
NAMED_VOLUMES=(); NAMED_VOLUME_DESCRIPTIONS=()
WEB_UI_NAMES=("My App")
WEB_UI_URLS=("http://${HOST_IP}:${WEB_PORT:-8080}")
USEFUL_COMMANDS="   docker logs -f my-app"

source "$REPO_DIR/lib/info-lib.sh"
run_info
```

`ACTION` is always one of `list` (terminal + regenerates `post-deploy-info.html`), `delete` (the `WIPE` policy, with a confirmation prompt), `manifest` (machine-readable, used by `backup.sh` — you never call this yourself), or `list-dirs` (machine-readable `DATA_DIRS` paths only, one per line — used by `deploy.sh`'s generic `docker-compose.yml`/`Dockerfile` fallback path to pre-create data directories before Docker touches them; also not something you call yourself). Declare every array even if empty (`INSTALL_DIRS=(); INSTALL_DESCRIPTIONS=()`) — `lib/info-lib.sh`'s own header comment documents the full set, including the optional ones (`WIPE_PARENT_DIRS`, `DATA_DIRS_LABEL`, `DELETE_CONFIRM_MSG`, etc.).

### `install-desktop.sh` (Recommended if there's a web UI)

Skip this only if the environment has no browser-launchable target at all (`pi-barebones` has none; `internet-pi`'s ports come from an externally-managed Ansible playbook rather than this repo's own `.env`, which is why it doesn't have one either — worth reconsidering if that ever changes). `install-desktop-entries.sh` at the repo root discovers these automatically via `environments/*/install-desktop.sh` — nothing else needs registering it.

All the actual logic — `--uninstall`, the deployed check, submenu registration, looping over entries, the info-page hookup — lives in `lib/desktop-lib.sh`'s `run_desktop_install()`. Your `install-desktop.sh` just declares data (a few scalars plus parallel arrays, one row per entry) and calls it once as the last line:

```bash
#!/usr/bin/env bash
set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="${APPS_DIR:-${HOME}/.local/share/applications}"
REPO_DIR="${REPO_DIR:-$(cd "$ENV_DIR/../.." && pwd)}"
source "$REPO_DIR/lib/desktop-lib.sh"

MENU_ID="my-environment"
MENU_NAME="My Environment"
MENU_ICON="network-server"
DEPLOYED_CHECK_KIND="container"       # or "marker" or "systemd" — see below
DEPLOYED_CHECK_VALUE="my-app"         # container name / marker file path / systemd unit

ENTRY_IDS=(pi-bootstrap-my-app)
ENTRY_NAMES=("My App")
ENTRY_COMMENTS=("What it does")
ENTRY_ICONS=(network-server)
ENTRY_KINDS=(link)                    # or "exec" — see below
ENTRY_TARGETS=("http://localhost:$(env_val "WEB_PORT" "8080")")

INFO_ID="pi-bootstrap-my-environment-info"
INFO_NAME="My Environment Info"

run_desktop_install "$@"
```

`DEPLOYED_CHECK_KIND` covers the three mechanisms actually in use across the current environments — `container` (`docker ps -a --filter name=^/<value>$`, for anything that stays running), `marker` (a `.deployed` file `run.sh` touches right before launch, for `--rm` containers where a cached image alone doesn't prove it was ever used), or `systemd` (a registered unit, for host-level installs like `nanoclaw`).

`ENTRY_KINDS[i]` is `link` for a plain URL open (→ `install_link_icon`, which writes both the application-menu entry and the Desktop icon — see below) or `exec` for anything that isn't a plain URL (X11 passthrough, `docker exec`, a terminal launcher — `ENTRY_TARGETS[i]` is then the full `Exec=` command string, and an optional `ENTRY_TERMINAL[i]` of `true`/`false` controls the `Terminal=` field, default `false`). `env_val KEY DEFAULT` (also in `lib/desktop-lib.sh`) reads a value from `$ENV_DIR/.env` with a fallback — the shared way to build port-based URLs/commands that reflect the user's actual configuration.

Every environment gets its **own submenu** (`register_submenu`, called automatically by `run_desktop_install`) rather than scattering entries into existing categories like Internet or System Tools — `Categories=` is derived from `MENU_ID` automatically too, so never set it yourself. `install_link_icon` writes both the application-menu entry (`Type=Application`, browser-fallback `Exec=`) and the Desktop icon (`Type=Link`) — these are deliberately two different desktop-entry flavors, not the same file copied twice, because `Type=Link` is silently filtered out of the menu on some desktop environments.

### Registering with `backup.sh`

Unlike `info.sh`/`install-desktop.sh` (discovered automatically per-environment), "is this environment actually deployed, or just configured-but-never-run" is a manually-maintained `case` statement inside the **root** `backup.sh`'s `is_deployed()` function — add your environment there so `backup.sh` doesn't skip its data or, conversely, doesn't try to back up an empty shell that was only ever set up in the TUI wizard:

```bash
my-environment)
    $DOCKER ps -a --filter "name=^/my-app$" -q 2>/dev/null | grep -q .
    ;;
```

Environments without a case here fall through to the default (`*) true ;;`) — always treated as deployed, which is harmless but less precise than an explicit check.
