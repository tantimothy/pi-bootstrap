# Raspberry Pi Infrastructure: Pi-hole + WireGuard (wg-easy)

This repository contains the infrastructure-as-code deployment for running a unified network security stack on a Raspberry Pi using Docker Compose. It provisions **Pi-hole v6** for network-wide ad blocking and local DNS management, alongside **WireGuard (via wg-easy)** for secure remote access with an intuitive web dashboard.

The deployment lifecycle is integrated with an automated TUI dashboard wizard that parses environment files dynamically, coupled with an advanced framework execution orchestrator (`run.sh`).

## 🪐 Architecture & Networking

- **Chained DNS Pipeline:** `wg-easy` is hardcoded to route all client DNS traffic directly through the Pi-hole container container-to-container (`172.20.0.2`), ensuring remote devices automatically get ad-blocking and local split-tunnel domain resolution.
- **Monitoring Pipeline:** `pihole-exporter` scrapes Pi-hole's v6 API and `wireguard-exporter` reads WireGuard kernel stats — both feed Prometheus, which Grafana queries for dashboards.

### Services & Ports

| Service | Container | Port | Purpose |
|---------|-----------|------|---------|
| [Pi-hole v6](https://pi-hole.net) | `pihole` | 53 (DNS), 80 (web) | Network-wide DNS ad blocking and local DNS management |
| [WireGuard](https://www.wireguard.com) / [wg-easy](https://github.com/wg-easy/wg-easy) | `wg-easy` | 51820/udp (VPN), 51821 (web) | Encrypted VPN with a web UI for peer management |
| [Grafana](https://grafana.com) | `grafana` | 3030 | Time-series dashboards for Pi-hole and WireGuard metrics |
| [Prometheus](https://prometheus.io) | `prometheus` | *(internal)* | Metrics scraping and storage backend |
| [pihole-exporter](https://github.com/eko/pihole-exporter) | `pihole-exporter` | *(internal)* | Translates Pi-hole v6 API responses into Prometheus metrics |
| [prometheus-wireguard-exporter](https://github.com/MindFlavor/prometheus_wireguard_exporter) | `wireguard-exporter` | *(internal, host net)* | Reads `wg show` kernel output and exposes peer stats for Prometheus |
| [PADD](https://github.com/pi-hole/PADD) | host terminal | tmux window | Pi-hole live stats dashboard — queries/sec, blocked %, top domains, in a dedicated terminal |
| [Uptime Kuma](https://github.com/louislam/uptime-kuma) | `uptime-kuma` | 3001 | Self-hosted uptime monitor with status pages and alerting for all services in this stack |
| [Node Exporter](https://github.com/prometheus/node_exporter) | `node-exporter` | *(host net, internal)* | Pi host system metrics — CPU, RAM, disk, network I/O exposed to Prometheus |
| [Speedtest Exporter](https://github.com/MiguelNdeCarvalho/speedtest-exporter) | `speedtest-exporter` | *(internal)* | Runs a full internet speed test when Prometheus scrapes it (every 30 min by default) |
| [Blackbox Exporter](https://github.com/prometheus/blackbox_exporter) | `blackbox-exporter` | *(internal)* | HTTP health checks, ICMP ping latency, and DNS resolution probes for all local services |

---

## 🛠️ Prerequisites

1. **Docker & Compose Plugin Installed:**
   ```bash
   sudo apt-get update
   sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
   ```

2. **Free Up Port 53 (DNS Conflict):**
   If your Pi OS runs a local stub resolver (`systemd-resolved`) that binds to port 53, disable it to allow Pi-hole to bind to the host interface:
   ```bash
   # Check if port 53 is occupied
   sudo lsof -i :53
   
   # Disable the stub listener if occupied
   sudo sed -i 's/#DNSStubListener=yes/DNSStubListener=no/g' /etc/systemd/resolved.conf
   sudo systemctl restart systemd-resolved
   ```

---

## 🚀 Deployment & Automation Guide

This repository utilizes a dual-stage configuration safety engine:
1. An automated **TUI Configuration Dashboard Wizard** parses `.env.example` using Linux `dialog` to collect required entries.
2. A gatekeeper deployment orchestrator (`run.sh`) validates the runtime state and intercepts policies before invoking Docker.

### 1. Clone the Repository
```bash
git clone <your-repo-url>
cd <your-repo-name>
```

### 2. Generate Your VPN UI Web Password Hash
`wg-easy` requires a securely hashed password for its management dashboard. Run this single-use container to generate a hash of your chosen plaintext password:
```bash
docker run --rm -it ghcr.io/wg-easy/wg-easy wgpw 'your_secure_password_here'
```
Copy the resulting bcrypt string (e.g., `$2b$12$...`) for input into the TUI engine.

### 3. Environment Blueprint Validation
The subdirectory contains the workspace `.env.example` file conforming exactly to the parsing engine specification (single `#` comment lines immediately preceding assignments). 

Run your TUI utility now. It will parse the layout, request inputs, and save them out as an active `.env` workspace file.

### 4. Execute the Safe Deployment Pipeline
Instead of running standard docker commands directly, the automated `run.sh` workflow is triggered by the parent interface layer. It evaluates your parameters, guards against blank variables, checks runtime state constraints, and isolates dependencies cleanly:

```bash
chmod +x run.sh
./run.sh
```

### 5. Post-deployment Verification
Ensure both containers are running cleanly: `docker compose ps`
Access your local dashboards via the values populated by your configuration engine:
- **Pi-hole Web UI:** `http://<YOUR_PI_IP>:{PIHOLE_WEB_PORT:-80}/admin`
- **WireGuard Web UI:** `http://<YOUR_PI_IP>:{WG_UI_PORT:-51821}`

---

## 🔒 Edge & Router Configuration
To allow external mobile devices to connect back to your WireGuard instance safely:
- **Port Forwarding:** Log into your home network gateway router and forward external **UDP port 51820** directly to the local static IP address of your Raspberry Pi.
- **Host Firewall (Optional):** If running UFW on your Pi, ensure forwarding paths from Docker's virtual bridge (`172.20.0.0/16`) are permitted to interact with your local physical network interfaces.

---

## 🔑 Passwords & Mandatory Secrets

### `FTLCONF_webserver_api_password` (Pi-hole admin password)
Seeds the Pi-hole web UI admin password into `./etc-pihole/pihole.toml` — but **only on first container creation**. Once `pihole.toml` exists, changing this value in `.env` has no further effect; recreating the container will not pick up a new value. To change the password afterward:
```bash
docker exec -it pihole pihole setpassword
```

### `WG_HOST` (WireGuard public endpoint)
Must be a publicly reachable IP address or DDNS hostname — this is what `wg-easy` writes into every client config so remote devices know where to connect. Unlike `FTLCONF_webserver_api_password`, this one *is* read fresh on every container start:
```bash
# edit WG_HOST in .env, then:
docker compose up -d --force-recreate wg-easy
```
Note that any client `.conf`/QR code you already downloaded is a static snapshot of the old host — it won't update automatically. Redownload it from the dashboard for each existing peer after changing `WG_HOST`.

#### Finding the equivalent value on a different Pi running PiVPN instead
If another one of your Pis runs WireGuard via **PiVPN** rather than this `wg-easy` stack, there's no `.env`/`WG_HOST` variable to read — PiVPN has its own config layout. To find the public host/endpoint it's using:
```bash
# Option 1: read it straight off an already-generated client config
grep Endpoint ~/configs/*.conf

# Option 2: read PiVPN's own install-time settings file
cat /etc/pivpn/wireguard/setupVars.conf   # look for pivpnHOST=
# (older PiVPN versions: /etc/pivpn/setupVars.conf)
```
PiVPN has no simple re-edit-and-restart flow for changing this value like `wg-easy` does — changing it typically means re-running PiVPN's setup or hand-editing `setupVars.conf` and regenerating client configs (`pivpn -qr` / `pivpn -add`).

### Changing the WireGuard dashboard login password
Unlike Pi-hole, there's no in-container command for this — `wg-easy`'s password is set via `PASSWORD_HASH` at startup:
```bash
# 1. Generate a new bcrypt hash
docker run --rm -it ghcr.io/wg-easy/wg-easy wgpw 'your_new_password'

# 2. Put the hash in .env, single-quoted (its $ characters get mangled by
#    run.sh's `source .env` if left unquoted):
#    PASSWORD_HASH='$2y$12$...'

# 3. Recreate the container so it picks up the new value
docker compose up -d --force-recreate wg-easy
```

---

## 💾 Data Directories

### Local Directories (in `environments/pihole-wireguard/`)

| Directory | Contents |
|-----------|---------|
| `./etc-pihole/` | Pi-hole config, gravity database, custom blocklists, local DNS records |
| `./etc-wireguard/` | WireGuard server keys + all peer configs — **back this up; losing it invalidates every client VPN** |

### Named Docker Volumes

| Volume | Contents |
|--------|---------|
| `prometheus_data` | Prometheus time-series metrics — Pi-hole query counts, WireGuard peer transfer history |
| `grafana_data` | Grafana database — dashboard definitions, alert rules, user preferences |
| `uptime_kuma_data` | Uptime Kuma database — all monitors, notification channels, incident history |

**Back up before any destructive operation:**
```bash
# Local directories
cp -r environments/pihole-wireguard/etc-pihole  ~/backup/
cp -r environments/pihole-wireguard/etc-wireguard ~/backup/

# Named volumes
docker run --rm -v prometheus_data:/data -v $(pwd):/backup alpine tar czf /backup/prometheus_data.tar.gz /data
docker run --rm -v grafana_data:/data -v $(pwd):/backup alpine tar czf /backup/grafana_data.tar.gz /data
```

---

## 🎛️ Deployment Policies

Select a policy when deploying from the menu, or set `REBUILD_POLICY` when running `./run.sh` directly:

| Policy | Action |
|--------|--------|
| `FAST` | Start stack if not running; skip if already active |
| `STOP` | Pause containers (resumable with FAST) |
| `TEARDOWN` | Stop + remove containers; data directories untouched |
| `CLEAN` | Stop + remove + pull fresh images and redeploy |
| `INFO` | List data directories with sizes and useful commands |
| `WIPE` | Delete persisted data directories (irreversible — back up first) |

---

## 🖥️ Desktop Integration

On a Pi with a desktop environment, run once from the repo root:

```bash
./install-desktop-entries.sh
# or just this environment on its own:
./environments/pihole-wireguard/install-desktop.sh

# To remove entries (also in the deploy.sh menu as "Uninstall Desktop Entries"):
./install-desktop-entries.sh --uninstall
```

| Desktop entry | Opens |
|:---|:---|
| **Pi-hole Admin** | `http://localhost:<PIHOLE_WEB_PORT>/admin` in default browser |
| **Grafana** | `http://localhost:<GRAFANA_PORT>` in default browser |
| **Uptime Kuma** | `http://localhost:<UPTIME_KUMA_PORT>` in default browser |
| **WireGuard Dashboard** | `http://localhost:<WG_UI_PORT>` in default browser |

Each entry tries `xdg-open` first, then falls back through `x-www-browser`, `sensible-browser`, and `chromium-browser` in case no default browser handler is configured on your system.

Port values are read from your `.env` at install time. Re-run the script if you change ports.

The script checks whether the stack is deployed before registering entries — it prints a warning and exits cleanly if the `pihole` container doesn't exist yet, and removes any previously-installed entries if the stack has since been torn down. Deploy first, then re-run to install the entries.

---

## 💡 Useful Commands

```bash
# Change Pi-hole admin password
docker exec -it pihole pihole setpassword

# Show connected WireGuard peers and transfer stats
docker exec -it wg-easy wg show

# Generate a new bcrypt hash for PASSWORD_HASH in .env
docker run --rm -it ghcr.io/wg-easy/wg-easy wgpw 'your_new_password'

# Recreate wg-easy container to pick up new PASSWORD_HASH or WG_HOST
docker compose up -d --force-recreate wg-easy

# Follow live logs
docker compose logs -f

# Follow logs for individual services
docker logs -f pihole
docker logs -f grafana
docker logs -f prometheus
docker logs -f pihole-exporter
docker logs -f wireguard-exporter

# Stack status (all 6 containers)
docker compose ps

# Attach to tmux (PADD auto-launches in the 'padd' window on login)
tmux attach

# Run PADD manually
~/padd.sh

# Uptime Kuma logs
docker logs -f uptime-kuma
```

---

## 📊 Grafana Monitoring

Access Grafana at `http://<pi-ip>:3030` (default port) with username `admin` and the password from `GRAFANA_ADMIN_PASSWORD` in your `.env`.

Pre-provisioned dashboards appear in the **Pi Network** folder:

| Dashboard | Grafana ID | Shows |
|-----------|-----------|-------|
| Pi-hole | 10176 | DNS queries/sec, blocked %, top clients, top blocked domains |
| WireGuard | 12177 | Per-peer received/sent bytes, last handshake timestamp |
| Node Exporter Full | 1860 | CPU, RAM, disk, filesystem, network I/O, system load |
| Blackbox Exporter | 7587 | HTTP response times, probe success/fail, ping latency, DNS check |
| Speedtest | 13665 | Download/upload speed and ping history over time |

If dashboards are missing (no internet at deploy time), import them manually:
1. Grafana sidebar → **Dashboards** → **Import**
2. Enter the dashboard ID from the table above
3. Select **Prometheus** as the datasource and click **Import**

---

## 🟢 Uptime Kuma

Access Uptime Kuma at `http://<pi-ip>:3001`. On first visit it prompts you to create an admin account — do this immediately before exposing the port to your network.

Monitors are configured via the UI. Suggested monitors for this stack:

| What to monitor | Type | URL / Target |
|-----------------|------|--------------|
| Pi-hole web UI | HTTP(s) | `http://localhost/admin` |
| WireGuard web UI | HTTP(s) | `http://localhost:51821` |
| Grafana | HTTP(s) | `http://localhost:3030` |
| DNS resolution (via Pi-hole) | DNS | resolve `google.com` on `127.0.0.1` |
| External internet | HTTP(s) | `https://1.1.1.1` or any external site |
| Pi host ping | Ping | `localhost` |

Uptime Kuma supports notifications via Telegram, Discord, Slack, email, ntfy, and many others — set one up under **Settings → Notifications** so you get alerted when something goes down.

---

### Notes on Pi-hole exporter authentication

`pihole-exporter` authenticates with Pi-hole v6's API using the same password as `FTLCONF_webserver_api_password`. If you later change the Pi-hole password via `pihole setpassword`, update `FTLCONF_webserver_api_password` in `.env` to match and recreate the exporter:
```bash
docker compose up -d --force-recreate pihole-exporter
```

### WireGuard exporter

`wireguard-exporter` runs on the host network alongside `wg-easy` so it can read `wg0` interface stats directly from the kernel. On first deploy it may take 1–2 minutes to start producing metrics — this is normal while WireGuard initialises. If you see "no data" in the WireGuard Grafana dashboard, wait for at least one peer to complete a handshake.

---

## 🔄 Migrating from an Existing Install

Use this section to transfer your existing Pi-hole blocklists, DNS records, WireGuard server keys, and peer configs into this environment. Migrating correctly means your existing VPN client devices continue connecting without any changes on their end.

---

### Pi-hole

#### From a standalone Pi-hole (installed via apt)

All Pi-hole data lives in `/etc/pihole/` on the host:

```bash
# On the OLD Pi — copy the directory
sudo cp -r /etc/pihole/ ~/pihole-backup/
```

Key files inside that directory:

| File | Contains |
|------|---------|
| `gravity.db` | All your blocklists (adlists + processed domains) — the most important file |
| `custom.list` | Local DNS A/CNAME records you added manually |
| `pihole.toml` | Pi-hole v6 settings (timezone, DHCP config, upstream DNS, etc.) |
| `setupVars.conf` | Pi-hole v5 settings — if migrating v5→v6, skip this; v6 ignores it |
| `dhcp.leases` | DHCP lease assignments — only needed if Pi-hole is your DHCP server |

Copy the backup to this environment before first deploy:

```bash
cp -r ~/pihole-backup/ environments/pihole-wireguard/etc-pihole/
```

Then deploy normally. Pi-hole will start with your existing gravity database, custom DNS records, and settings intact. Gravity (blocklist) re-processing still runs on the first startup — this is normal.

> **v5 → v6 note:** `gravity.db` is compatible between versions. `pihole.toml` only exists in v6 — if your backup only has `setupVars.conf`, Pi-hole v6 will ignore it and start fresh. Re-enter your settings via the v6 web UI, then your gravity.db data is still fully restored.

#### From Pi-hole running in Docker (another compose stack)

Find the directory that was bind-mounted to `/etc/pihole` inside the container — it will be a local directory containing `gravity.db`, `pihole.toml`, etc.

```bash
# Identify the bind mount path
docker inspect pihole | grep -A2 '"Destination": "/etc/pihole"'

# Copy it
cp -r /path/to/that/directory/ environments/pihole-wireguard/etc-pihole/
```

---

### WireGuard

#### The key principle

The server's **private key** determines the public key baked into every client's `.conf` file. If you preserve the same private key in the new install, **all existing client devices connect without any changes**. If you generate a new key (fresh install), every client needs a new config redistributed to it.

Choose your migration path:

- **[Option A]** Preserve existing clients — transfer the private key (more steps, zero client disruption)
- **[Option B]** Fresh start — let wg-easy generate a new key, re-add all peers via the UI, redistribute new configs

---

#### From wg-easy (another Docker stack) — Option A

wg-easy stores everything in its bind-mounted volume — just copy the whole directory:

```bash
cp -r /path/to/old/etc-wireguard/ environments/pihole-wireguard/etc-wireguard/
```

That directory contains `wg0.conf` (server key + peer entries) and `wg0.json` (wg-easy's peer metadata: names, IDs, creation dates). Both are transferred, so peer names appear correctly in the wg-easy web UI.

Deploy as normal — all peers reconnect automatically.

---

#### From PiVPN — Option A (preserve existing clients)

PiVPN stores the server private key in `/etc/wireguard/wg0.conf`. You need to extract it and the peer entries, then splice them into wg-easy's format.

**Step 1 — on the old Pi, capture what you need:**

```bash
# Server private key (keep this secret)
sudo grep PrivateKey /etc/wireguard/wg0.conf

# All peer entries
sudo grep -A4 '^\[Peer\]' /etc/wireguard/wg0.conf

# PiVPN sometimes stores keys separately — check here too
ls /etc/wireguard/keys/
```

**Step 2 — deploy this environment fresh** (generates a temporary new key):

```bash
./run.sh   # or use the TUI
```

**Step 3 — stop the containers:**

```bash
docker compose stop
```

**Step 4 — splice in the old server private key:**

Edit `environments/pihole-wireguard/etc-wireguard/wg0.conf`. Find the `[Interface]` block and replace the `PrivateKey` value with the one from PiVPN:

```
[Interface]
PrivateKey = <PASTE YOUR OLD PIVPN PRIVATE KEY HERE>
Address = 10.8.0.1/24
...
```

Do not change anything else in `[Interface]` — leave wg-easy's Address, ListenPort, PostUp/PreDown as-is.

**Step 5 — add your existing peers:**

Append your PiVPN `[Peer]` blocks to the same `wg0.conf`. They look like:

```
[Peer]
# phone
PublicKey = <peer-public-key>
PresharedKey = <preshared-key>   # if PiVPN generated one
AllowedIPs = 10.8.0.2/32
```

> **IP address note:** PiVPN and wg-easy may use different subnet ranges (PiVPN defaults to `10.6.0.0/24`, wg-easy to `10.8.0.1/24`). If your peers have addresses in `10.6.0.x`, keep those AllowedIPs and make sure the `Address` in `[Interface]` covers that subnet — or renumber the peers (requires updating client configs).

**Step 6 — restart:**

```bash
docker compose up -d
```

Existing clients reconnect because the server public key (derived from the preserved private key) matches what's in their config. The wg-easy web UI will show the peers but without names — add names via the UI or edit `etc-wireguard/wg0.json` directly (see structure below).

---

#### From standard WireGuard / wg-quick — Option A

The process is identical to the PiVPN steps above. Your server config is at `/etc/wireguard/wg0.conf`. Extract the `PrivateKey` from `[Interface]` and all `[Peer]` blocks, then follow PiVPN steps 2–6.

---

#### Any source — Option B (fresh server key, redistribute configs)

If you don't need to preserve existing client configs (or you have very few peers):

1. Deploy this environment normally — wg-easy generates a new server key pair
2. Open the wg-easy dashboard at `http://<pi-ip>:51821`
3. Add each peer via **New Client** — give it a name, download/scan the new QR code
4. Distribute the new `.conf` files or QR codes to each device

No key extraction or file editing needed. Existing client `.conf` files become invalid and must be replaced with the new ones.

---

#### wg0.json format reference (for adding peer names after key migration)

If you imported peers via `wg0.conf` but the wg-easy UI shows them without names, create or edit `etc-wireguard/wg0.json` while containers are stopped:

```json
{
  "clients": {
    "some-uuid-here": {
      "id": "some-uuid-here",
      "name": "My Phone",
      "address": "10.8.0.2",
      "publicKey": "<peer-public-key-from-wg0.conf>",
      "createdAt": "2024-01-01T00:00:00.000Z",
      "updatedAt": "2024-01-01T00:00:00.000Z",
      "enabled": true,
      "expiredAt": null,
      "allowedIPs": ["0.0.0.0/0", "::/0"],
      "persistentKeepalive": 0
    }
  }
}
```

Add one entry per peer. Use any unique string for `id` (a UUID or short slug). The `publicKey` must match the `PublicKey` in the corresponding `[Peer]` block in `wg0.conf`. Restart containers after editing.