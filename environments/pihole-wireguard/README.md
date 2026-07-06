# Raspberry Pi Infrastructure: Pi-hole + WireGuard (wg-easy)

This repository contains the infrastructure-as-code deployment for running a unified network security stack on a Raspberry Pi using Docker Compose. It provisions **Pi-hole v6** for network-wide ad blocking and local DNS management, alongside **WireGuard (via wg-easy)** for secure remote access with an intuitive web dashboard.

The deployment lifecycle is integrated with an automated TUI dashboard wizard that parses environment files dynamically, coupled with an advanced framework execution orchestrator (`run.sh`).

## 🪐 Architecture & Networking

- **Chained DNS Pipeline:** Pi-hole runs on the host network so it can serve DHCP to LAN devices and receive broadcast packets. `wg-easy` writes `WG_DNS` (default `10.8.0.1` — the Pi's WireGuard tunnel IP) into every peer config, so VPN clients use Pi-hole for DNS automatically.
- **Monitoring Pipeline:** `pihole-exporter` scrapes Pi-hole's v6 API and `wireguard-exporter` reads WireGuard kernel stats — both feed Prometheus, which Grafana queries for dashboards.

### Services & Ports

| Service | Container | Port | Purpose |
|---------|-----------|------|---------|
| [Pi-hole v6](https://pi-hole.net) | `pihole` | 53 (DNS), 67/udp (DHCP), 80 (web) | Network-wide DNS ad blocking, local DNS management, and optional DHCP server |
| [WireGuard](https://www.wireguard.com) / [wg-easy](https://github.com/wg-easy/wg-easy) | `wg-easy` | 51820/udp (VPN), 51821 (web) | Encrypted VPN with a web UI for peer management |
| [Grafana](https://grafana.com) | `grafana` | 3030 | Time-series dashboards for Pi-hole and WireGuard metrics |
| [Prometheus](https://prometheus.io) | `prometheus` | *(internal)* | Metrics scraping and storage backend |
| [pihole-exporter](https://github.com/eko/pihole-exporter) | `pihole-exporter` | *(internal)* | Translates Pi-hole v6 API responses into Prometheus metrics |
| [prometheus-wireguard-exporter](https://github.com/MindFlavor/prometheus_wireguard_exporter) | `wireguard-exporter` | *(internal, host net)* | Reads `wg show` kernel output and exposes peer stats for Prometheus |
| [Uptime Kuma](https://github.com/louislam/uptime-kuma) | `uptime-kuma` | 3001 | Self-hosted uptime monitor with status pages and alerting for all services in this stack |
| [darkstat](https://unix4lyfe.org/darkstat/) | `darkstat` | 667 (web) | Per-host bandwidth usage, protocol breakdown, and top talkers — built from Debian apt for ARM |
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
- **Host Firewall (Optional):** If running UFW on your Pi, ensure ports 53 (DNS), 67 (DHCP), 80 (Pi-hole web), and 51820 (WireGuard) are allowed on your LAN interface. The monitoring containers (Grafana, Prometheus, Uptime Kuma) communicate via the internal Docker bridge and do not need firewall rules.

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

1. Generate a new bcrypt hash:
   ```bash
   docker run --rm -it ghcr.io/wg-easy/wg-easy wgpw 'your_new_password'
   ```
2. Put the hash in `.env`, single-quoted (its `$` characters get mangled by `run.sh`'s `source .env` if left unquoted):
   ```
   PASSWORD_HASH='$2y$12$...'
   ```
3. Recreate the container so it picks up the new value:
   ```bash
   docker compose up -d --force-recreate wg-easy
   ```

### PADD on login (optional)

Every `run.sh` invocation idempotently wires up a `.bashrc` block that runs `~/padd.sh` ([PADD](https://github.com/pi-hole/PADD), Pi-hole's terminal stats dashboard) on login, if that file exists — this repo doesn't download or manage PADD itself, only the login launcher. If you're also running the `pi-barebones` environment on the same Pi, the login order is always **tmux → PADD → fastfetch**, regardless of which environment you deploy first or how many times either re-runs: `pi-barebones`'s tmux block always re-pins itself immediately before this PADD block (or any pre-existing default `.bashrc` content stays above it, never below), its fastfetch block always re-pins to the very bottom, and this PADD block always inserts itself immediately before the fastfetch block.

The API password is written to `/etc/pihole/cli_pw` (owned by your user, `chmod 600`) rather than passed as a `--secret` command-line argument — PADD auto-reads that file if present, which avoids the password being visible via `ps aux` to any other user on the system for as long as PADD is running, not just recorded in shell history.

---

## 💾 Data Directories

### Local Directories (in `environments/pihole-wireguard/`)

| Directory | Contents |
|-----------|---------|
| `./etc-pihole/` | Pi-hole config, gravity database, custom blocklists, local DNS records |
| `./etc-wireguard/` | WireGuard server keys + all peer configs — **back this up; losing it invalidates every client VPN** |
| `./darkstat-db/` | darkstat traffic database — per-host bandwidth history |

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
| `CLEAN` | Pull fresh images, snapshot old containers as a rollback fallback, then stop + remove + redeploy |
| `INFO` | List data directories with sizes and useful commands |
| `WIPE` | Delete persisted data directories (irreversible — back up first) |

**`CLEAN` details:** images are pulled *before* the old containers are stopped — Pi-hole is this stack's own DNS resolver, so pulling only after teardown would leave the host unable to resolve registry hostnames on a self-hosted-DNS Pi. Before removal, each old container is snapshotted via `docker commit` into a `<name>:clean-fallback` image (a plain rename isn't enough, since Compose matches containers by label and would just recreate/destroy a renamed one on the next `up`). The tag is fixed, not timestamped — only the single most recent fallback is ever kept per container, since `docker commit` just moves the tag to the new image and the previous one is cleaned up right after, so the rollback command below never changes. Named volumes are left untouched.

### Rolling back a bad `CLEAN` deploy

Every container gets a fallback snapshot, but **in practice Pi-hole is the only one you'd realistically need to roll back** — it's the single point of failure this whole mechanism exists to protect (the stack's own DNS resolver), and the rest (Grafana, Prometheus, the exporters, etc.) can just be redeployed or debugged normally without urgency. If a fresh Pi-hole image turns out broken:

```bash
# 1. Find the fallback image
docker images | grep pihole | grep clean-fallback

# 2. Stop and remove the broken container
docker stop pihole
docker rm pihole

# 3. Run the fallback image with the same flags pihole normally uses
#    (from docker-compose.yml: host networking, NET_ADMIN, etc-pihole bind mount)
docker run -d --name pihole --network host --cap-add NET_ADMIN \
  --restart unless-stopped \
  -v "$(pwd)/etc-pihole:/etc/pihole" \
  pihole:clean-fallback
```

`./etc-pihole` is a bind mount, not baked into the image, so all of Pi-hole's actual state (gravity database, custom blocklists, settings) is unaffected either way — this only rolls back the *software*, not the data.

This container is no longer Compose-managed (no Compose labels), so before your next `./run.sh` run, `docker stop pihole && docker rm pihole` first — otherwise Compose will fail with a "name already in use" error trying to recreate it.

For any other service, the same pattern applies — swap in that service's own volume/network/cap flags from `docker-compose.yml`.

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

Each entry tries `xdg-open` first, then falls back through `x-www-browser`, `sensible-browser`, `chromium-browser`, `chromium`, `firefox-esr`, and `firefox` in case no default browser handler is configured on your system — covering both the older Debian wrapper names and the current Raspberry Pi OS (Bookworm+) package names.

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
docker logs -f darkstat
docker logs -f pihole
docker logs -f grafana
docker logs -f prometheus
docker logs -f pihole-exporter
docker logs -f wireguard-exporter

# Stack status
docker compose ps

# Uptime Kuma logs
docker logs -f uptime-kuma
```

---

## 📊 Grafana Monitoring

Access Grafana at `http://<pi-ip>:3030` (default port) with username `admin` and the password from `GRAFANA_ADMIN_PASSWORD` in your `.env`.

Pre-provisioned dashboards appear in the **Pi Network** folder — they are *not* on Grafana's default/home Dashboards view, so browse into it explicitly: sidebar → **Dashboards** → **Pi Network**.

| Dashboard | Grafana ID | Shows |
|-----------|-----------|-------|
| Pi-hole | 10176 | DNS queries/sec, blocked %, top clients, top blocked domains |
| WireGuard | *(none — hand-authored, committed to this repo)* | Per-peer sent/received rate, time since last handshake, cumulative totals |
| WireGuard (community) | 17251 | Per-peer received/sent bytes gauge, throughput over time, handshake state timeline |
| Node Exporter Full | 1860 | CPU, RAM, disk, filesystem, network I/O, system load |
| Blackbox Exporter | 7587 | HTTP response times, probe success/fail, ping latency, DNS check |
| Speedtest | 13665 | Download/upload speed and ping history over time |

Both WireGuard dashboards use the same metric names/labels as this stack's `wireguard-exporter` (`wireguard_sent_bytes_total`/`wireguard_received_bytes_total`/`wireguard_latest_handshake_seconds`, labeled by `allowed_ips`) — community dashboard **12177** does not, despite its generic name, and isn't downloaded for that reason (see the WireGuard exporter troubleshooting note below).

If dashboards are missing (no internet at deploy time), import them manually:
1. Grafana sidebar → **Dashboards** → **Import**
2. Enter the dashboard ID from the table above (the hand-authored WireGuard one has no ID — re-run `./run.sh` instead, or copy `monitoring/grafana/dashboards/wireguard.json` from this repo)
3. Select **Prometheus** as the datasource and click **Import**

If a dashboard is present but its panels show "Datasource not found" instead of data, `run.sh` downloaded it before it existed locally and the datasource-variable rewrite (`${DS_...}` → your Prometheus datasource) didn't cover every variable name a given community dashboard uses. Fix by re-running the rewrite against the existing file and restarting Grafana:
```bash
cd environments/pihole-wireguard/monitoring/grafana/dashboards/
sed -i -E 's/\$\{DS_[A-Za-z0-9_-]+\}/prometheus/g' <dashboard>.json
docker restart grafana
```

---

## 🟢 Uptime Kuma

Access Uptime Kuma at `http://<pi-ip>:3001`. On first visit it prompts you to create an admin account — do this immediately before exposing the port to your network.

Monitors are configured via the UI. Suggested monitors for this stack — **don't use `localhost`**: Uptime Kuma runs in its own container on the `pihole_wg_network` bridge, not on the host network, so `localhost` only ever refers to the Uptime Kuma container itself, never Pi-hole/WireGuard/darkstat/the Pi host. Use `host.docker.internal` for anything running on the host network, and the container name directly for anything on the same bridge network as Uptime Kuma:

| What to monitor | Type | URL / Target |
|-----------------|------|--------------|
| Pi-hole web UI | HTTP(s) | `http://host.docker.internal/admin` |
| WireGuard web UI | HTTP(s) | `http://host.docker.internal:51821` |
| Grafana | HTTP(s) | `http://grafana:3000` (same bridge network — use the container name and internal port, not the host-mapped one) |
| DNS resolution (via Pi-hole) | DNS | resolve `google.com`, Resolver Server `<pi-lan-ip>` (see note below) |
| darkstat | HTTP(s) | `http://host.docker.internal:667` |
| External internet | HTTP(s) | `https://1.1.1.1` or any external site |
| Pi host ping | Ping | `host.docker.internal` |

**DNS resolution monitor:** unlike the other monitor types, Uptime Kuma's Resolver Server field needs a raw IP address, not a hostname — it can't resolve `host.docker.internal` itself for this one (querying a DNS server is a lower-level operation than the DNS lookups behind normal hostname resolution). Use the Pi's actual LAN IP address instead. If you're not sure `host.docker.internal` and the LAN IP resolve to different things from Uptime Kuma's perspective, confirm with `docker exec uptime-kuma getent hosts host.docker.internal`.

Uptime Kuma supports notifications via Telegram, Discord, Slack, email, ntfy, and many others — set one up under **Settings → Notifications** so you get alerted when something goes down.

---

### Notes on Pi-hole exporter authentication

`pihole-exporter` authenticates with Pi-hole v6's API using the same password as `FTLCONF_webserver_api_password`. If you later change the Pi-hole password via `pihole setpassword`, update `FTLCONF_webserver_api_password` in `.env` to match and recreate the exporter:
```bash
docker compose up -d --force-recreate pihole-exporter
```

### WireGuard exporter

`wireguard-exporter` runs on the host network alongside `wg-easy` so it can read `wg0` interface stats directly from the kernel. On first deploy it may take 1–2 minutes to start producing metrics — this is normal while WireGuard initialises. If you see "no data" in the WireGuard Grafana dashboard, wait for at least one peer to complete a handshake.

If `docker compose ps` shows `wireguard-exporter` stuck restarting, and `docker logs wireguard-exporter` repeats `error: The argument '--prepend_sudo <prepend_sudo>' requires a value but none was supplied` — that's the container's own crash loop, not a shell/`sudo` issue on the host. The `mindflavor/prometheus-wireguard-exporter` image's default `CMD` is just `["-a"]` (a flag with no value); `docker-compose.yml` overrides `command: ["-a", "true"]` to fix this, so make sure you're on a version of this repo that includes that override.

If the WireGuard Grafana dashboard shows "No data" on every panel despite `wireguard-exporter` scraping successfully (check Prometheus → Status → Targets, job `wireguard` should show `up`), you're likely on an older deploy that downloaded community dashboard ID 12177 — it queries `wireguard_peer_*_bytes_total`/`wireguard_peer_info`, which is a *different* exporter's metric naming scheme, not this one's (`wireguard_sent_bytes_total`/`wireguard_received_bytes_total`/`wireguard_latest_handshake_seconds`). Delete `monitoring/grafana/dashboards/wireguard.json` and `monitoring/grafana/dashboards/wireguard-community.json` and redeploy (`REBUILD_POLICY=FAST ./run.sh`) to pick up the hand-authored dashboard plus community dashboard 17251, both of which match the real metric names.

### Speedtest exporter

If `docker compose ps` (or Prometheus's own container-health view) shows `speedtest-exporter` as `unhealthy` even though `docker logs speedtest-exporter` shows real speed test results (`Server=... Download=...Mbps Upload=...Mbps`), it's a false alarm from the image's own built-in healthcheck, not an actual outage — Prometheus's real scrape (over the bridge network's IPv4 address) is unaffected either way. The image's default healthcheck spiders `http://localhost:9798/`, and on some systems `localhost` resolves to `::1` (IPv6) first; the exporter only binds IPv4, so that spider gets `connection refused` forever. `docker-compose.yml`'s `healthcheck:` override pins it to `http://127.0.0.1:9798/` explicitly to fix this — make sure you're on a version of this repo that includes it.

If it's *actually* down (no speed test results in the logs at all, or DNS/connection errors like `Couldn't resolve host name (HostNotFoundException)`), the exporter needs outbound internet access and working DNS — check `docker exec speedtest-exporter getent hosts www.speedtest.net` resolves. After moving this stack to a new Pi/IP, existing containers can end up with a stale host-DNS-forwarding address baked into their `/etc/resolv.conf` (Docker computes this once, at container-creation time, and never updates it) — `docker compose up -d --force-recreate` regenerates it against the current network config.

### darkstat

`darkstat` shows hostnames for LAN devices by resolving IPs through reverse DNS, using whatever DNS server the host itself is configured with (it runs with `network_mode: host`, same as Pi-hole). If devices show up as bare IP addresses instead of names, check Pi-hole's **Settings → DNS → Conditional Forwarding** — it needs to be enabled and pointed at your router for Pi-hole to answer reverse lookups for locally-leased IPs. Without it, Pi-hole (or whatever your resolver is) has no local PTR records to return, and darkstat falls back to showing the raw IP.

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

PiVPN stores the server private key in `/etc/wireguard/wg0.conf`.

> **Important:** wg-easy regenerates `wg0.conf` from its own `wg0.json` on every startup. Editing `wg0.conf` directly has no effect — your changes will be silently overwritten at the next restart. The correct target is always `wg0.json`.

**Step 1 — on the old Pi, capture what you need:**

```bash
# Server private key (keep this secret — treat it like a password)
sudo grep PrivateKey /etc/wireguard/wg0.conf

# All peer entries (PublicKey, PresharedKey, AllowedIPs per peer)
sudo grep -A4 '^\[Peer\]' /etc/wireguard/wg0.conf
```

**Step 2 — deploy this environment fresh** (wg-easy generates a temporary new key):

```bash
./run.sh   # or use the TUI
```

**Step 3 — stop wg-easy:**

```bash
docker compose stop wg-easy
```

**Step 4 — derive the old server's public key:**

```bash
echo "<your-old-pivpn-private-key>" | docker run --rm -i ghcr.io/wg-easy/wg-easy wg pubkey
```

This gives you the public key that your existing client configs already know about.

**Step 5 — edit `etc-wireguard/wg0.json`:**

wg-easy's JSON stores the server keys and all client metadata. Replace the auto-generated server keys and add a client entry for each PiVPN peer:

```json
{
  "server": {
    "privateKey": "<your-old-pivpn-private-key>",
    "publicKey": "<output from step 4>",
    "address": "10.8.0.1"
  },
  "clients": {
    "<uuid-for-peer-1>": {
      "id": "<uuid-for-peer-1>",
      "name": "laptop",
      "address": "10.6.0.2",
      "publicKey": "<peer PublicKey from wg0.conf>",
      "preSharedKey": "<peer PresharedKey from wg0.conf, or omit if none>",
      "createdAt": "2024-01-01T00:00:00.000Z",
      "updatedAt": "2024-01-01T00:00:00.000Z",
      "enabled": true
    }
  }
}
```

Use `uuidgen` to generate IDs. Add one entry per peer.

> **Subnet mismatch (PiVPN default `10.6.x` or `10.84.43.x` vs wg-easy's `10.8.x`):** This is fine. WireGuard adds a per-peer kernel route for each peer's `AllowedIPs` independently of the server's interface subnet. The old client IP addresses work as-is — you do not need to renumber your peers or update any client config.

**Step 6 — restart wg-easy:**

```bash
docker compose up -d wg-easy
```

wg-easy reads `wg0.json`, regenerates `wg0.conf` with the old private key and peer entries, and brings up the WireGuard interface. Existing clients reconnect without any changes on their end.

Verify with `docker exec wg-easy wg show` — you should see your peers listed.

---

#### From standard WireGuard / wg-quick — Option A

Identical to the PiVPN steps above. Your server config is at `/etc/wireguard/wg0.conf`. Extract `PrivateKey` from `[Interface]` and all `[Peer]` blocks, then follow steps 2–6.

---

#### Any source — Option B (fresh server key, redistribute configs)

If you don't need to preserve existing client configs (or you have very few peers):

1. Deploy this environment normally — wg-easy generates a new server key pair
2. Open the wg-easy dashboard at `http://<pi-ip>:51821`
3. Add each peer via **New Client** — give it a name, download/scan the new QR code
4. Distribute the new `.conf` files or QR codes to each device

No key extraction or file editing needed. Existing client `.conf` files become invalid and must be replaced with the new ones.

---

#### wg0.json structure reference

wg-easy's authoritative state is `etc-wireguard/wg0.json` — it writes `wg0.conf` from this file on every startup. Full structure:

```json
{
  "server": {
    "privateKey": "<server private key>",
    "publicKey": "<server public key>",
    "address": "10.8.0.1"
  },
  "clients": {
    "<uuid>": {
      "id": "<uuid>",
      "name": "My Phone",
      "address": "10.8.0.2",
      "publicKey": "<peer public key>",
      "preSharedKey": "<preshared key, or omit field if none>",
      "createdAt": "2024-01-01T00:00:00.000Z",
      "updatedAt": "2024-01-01T00:00:00.000Z",
      "enabled": true
    }
  }
}
```

Always stop the `wg-easy` container before editing this file, then restart it — otherwise wg-easy may overwrite your changes mid-edit.