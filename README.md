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
| `FAST` *(default)* | Skip rebuild if running; `docker start` if stopped; rebuild only what's missing | Reuse local layer cache |
| `CLEAN` | Stop and remove all containers in `CONTAINER_NAME` | Evict image cache, force `--no-cache` build |
| `STOP` | Pause containers (resumable with FAST) | — |
| `TEARDOWN` | Stop + remove containers; data untouched | — |
| `INFO` | Show data directories, sizes, and useful commands | — |
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
