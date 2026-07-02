# Raspberry Pi Infrastructure: Pi-hole + WireGuard (wg-easy)

This repository contains the infrastructure-as-code deployment for running a unified network security stack on a Raspberry Pi using Docker Compose. It provisions **Pi-hole v6** for network-wide ad blocking and local DNS management, alongside **WireGuard (via wg-easy)** for secure remote access with an intuitive web dashboard.

The deployment lifecycle is integrated with an automated TUI dashboard wizard that parses environment files dynamically, coupled with an advanced framework execution orchestrator (`run.sh`).

## 🪐 Architecture & Networking

- **Chained DNS Pipeline:** `wg-easy` is hardcoded to route all client DNS traffic directly through the Pi-hole container container-to-container (`172.20.0.2`), ensuring remote devices automatically get ad-blocking and local split-tunnel domain resolution.
- **Port Layout:**
  - `53/tcp & udp`: Local DNS Resolution
  - `8080/tcp`: Pi-hole v6 Web Dashboard
  - `51820/udp`: WireGuard VPN Listening Port
  - `51821/tcp`: WireGuard Web UI Dashboard

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
- **Pi-hole Web UI:** `http://<YOUR_PI_IP>:{PIHOLE_WEB_PORT:-8080}/admin`
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

Persistent data is stored on the host and survives container removal:

| Directory | Contents |
|-----------|---------|
| `./etc-pihole/` | Pi-hole config, gravity database, custom blocklists, local DNS records |
| `./etc-wireguard/` | WireGuard server keys + all peer configs — **back this up; losing it invalidates every client VPN** |

**Back up before any destructive operation:**
```bash
cp -r environments/pihole-wireguard/etc-pihole  ~/backup/
cp -r environments/pihole-wireguard/etc-wireguard ~/backup/
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

# Follow live logs for both containers
docker compose logs -f

# Stack status
docker compose ps
```