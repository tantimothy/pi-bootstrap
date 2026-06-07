# Raspberry Pi Infrastructure: Pi-hole + WireGuard (wg-easy)

This repository contains the infrastructure-as-code deployment for running a unified network security stack on a Raspberry Pi using Docker Compose. It provisions **Pi-hole v6** for network-wide ad blocking and local DNS management, alongside **WireGuard (via wg-easy)** for secure remote access with an intuitive web dashboard.

The deployment lifecycle is integrated with an automated TUI dashboard wizard that parses environment files dynamically, coupled with an enterprise-grade execution wrapper (`run.sh`).

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
2. A gatekeeper deployment orchestrator (`run.sh`) validates the runtime state before invoking Docker.

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
Ensure your directory contains the workspace `.env.example` file conforming exactly to the parsing engine specification (single `#` comment lines immediately preceding assignments):

```env
# Timezone configuration for metrics and logging.
TZ=Asia/Singapore

# Administrative web portal access password for the Pi-hole dashboard.
FTLCONF_webserver_api_password=

# Local host port mapped to the Pi-hole container web server.
PIHOLE_WEB_PORT=8080

# Static internal container IP allocated to Pi-hole within the Docker bridge.
PIHOLE_INTERNAL_IP=172.20.0.2

# The public WAN static IP address or DDNS hostname for remote clients.
WG_HOST=

# The host network listening port for incoming encrypted VPN tunnels.
WG_PORT=51820

# The local host web management port for the wg-easy dashboard UI.
WG_UI_PORT=51821

# Cryptographically hashed bcrypt password for the wg-easy portal.
PASSWORD_HASH=

# Allowed IP subnets to route through the tunnel (e.g., 0.0.0.0/0).
WG_ALLOWED_IPS=0.0.0.0/0

# Static internal container IP allocated to wg-easy within the Docker bridge.
WG_INTERNAL_IP=172.20.0.3

# The isolated private subnet block managed by Docker Compose.
DOCKER_SUBNET=172.20.0.0/16
```

Run your TUI utility now. It will parse the layout, request inputs, and save them out as an active `.env` workspace file.

### 4. Execute the Safe Deployment Pipeline
Instead of running standard docker commands directly, invoke the automated orchestrator script. It evaluates your parameters, guards against blank variables, ensures network ports are available, and isolates dependencies securely:

```bash
chmod +x run.sh
./run.sh
```

The underlying `run.sh` script implements strict fail-fast guarantees:
```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "❌ Error: Active '.env' file not found." >&2
    exit 1
fi

export $(grep -v '^#' "$ENV_FILE" | xargs)

MISSING_VARS=()
[ -z "${FTLCONF_webserver_api_password:-}" ] && MISSING_VARS+=("FTLCONF_webserver_api_password")
[ -z "${WG_HOST:-}" ]                         && MISSING_VARS+=("WG_HOST")
[ -z "${PASSWORD_HASH:-}" ]                  && MISSING_VARS+=("PASSWORD_HASH")

if [ ${#MISSING_VARS[@]} -ne 0 ]; then
    echo "❌ Error: Missing mandatory entries in '.env'" >&2
    exit 1
fi

cd "$SCRIPT_DIR"
docker compose --env-file "$ENV_FILE" pull
docker compose --env-file "$ENV_FILE" up -d --remove-orphans
```

### 5. Post-Deployment Verification
Ensure both containers are running cleanly: `docker compose ps`
Access your local dashboards via the values populated by your configuration engine:
- **Pi-hole Web UI:** `http://<YOUR_PI_IP>:${PIHOLE_WEB_PORT:-8080}/admin`
- **WireGuard Web UI:** `http://<YOUR_PI_IP>:${WG_UI_PORT:-51821}`

---

## 🔒 Edge & Router Configuration
To allow external mobile devices to connect back to your WireGuard instance safely:
- **Port Forwarding:** Log into your home network gateway router and forward external **UDP port 51820** directly to the local static IP address of your Raspberry Pi.
- **Host Firewall (Optional):** If running UFW on your Pi, ensure forwarding paths from Docker's virtual bridge (`172.20.0.0/16`) are permitted to interact with your local physical network interfaces.

---

## 💾 Backups & Maintenance
All persistent states are safely isolated in project root directories for explicit tracking:
- `./etc-pihole/` (Adlists, DNS records, configuration flags)
- `./etc-wireguard/` (Cryptographic server keys, client lists, peer state)

**To update the stack to the latest stable container layers gracefully:**
```bash
./run.sh
```
The automated `run.sh` workflow handles hot updates naturally by re-pulling dependencies during execution cycles without dropping configuration states.