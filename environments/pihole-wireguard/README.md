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

## 💾 Backups & Maintenance
All persistent states are safely isolated in project root directories for explicit tracking:
- `./etc-pihole/` (Adlists, DNS records, configuration flags)
- `./etc-wireguard/` (Cryptographic server keys, client lists, peer state)

**To update the stack to the latest stable container layers gracefully:**
```bash
./run.sh
```
The automated `run.sh` workflow handles hot updates naturally by re-pulling dependencies during execution cycles without dropping configuration states.