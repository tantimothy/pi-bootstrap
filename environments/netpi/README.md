Markdown
# Raspberry Pi Infrastructure: Pi-hole + WireGuard (wg-easy)

This repository contains the infrastructure-as-code deployment for running a unified network security stack on a Raspberry Pi using Docker Compose. It provisions **Pi-hole v6** for network-wide ad blocking and local DNS management, alongside **WireGuard (via wg-easy)** for secure remote access with an intuitive web dashboard.

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

1. **Free Up Port 53 (DNS Conflict):**
   If your Pi OS runs a local stub resolver (systemd-resolved) that binds to port 53, disable it to allow Pi-hole to bind to the host interface:
   ```bash
   # Check if port 53 is occupied
   sudo lsof -i :53
   
   # Disable the stub listener if occupied
   sudo sed -i 's/#DNSStubListener=yes/DNSStubListener=no/g' /etc/systemd/resolved.conf
   sudo systemctl restart systemd-resolved
   ```

## 🚀 Deployment Guide

1. **Clone the Repository**
   ```bash
   git clone <your-repo-url>
   cd <your-repo-name>
   ```

2. **Generate Your VPN UI Web Password**
   `wg-easy` requires a securely hashed password for its management dashboard. Run this single-use container to generate a hash of your chosen plaintext password:
   ```bash
   docker run --rm -it ghcr.io/wg-easy/wg-easy wgpw 'your_secure_password_here'
   ```
   Copy the resulting bcrypt string (e.g., `$2b$12$...`).

3. **Update Environment Variables**
   Open `docker-compose.yml` and configure the following placeholders:
   ```yaml
   # Inside the pihole service configuration:
   FTLCONF_webserver_api_password: 'YourSecurePiholeAdminPassword'
   
   # Inside the wg-easy service configuration:
   WG_HOST: 'YOUR_PUBLIC_IP_OR_DDNS_DOMAIN'
   PASSWORD_HASH: 'PASTE_YOUR_GENERATED_HASH_HERE'
   ```

4. **Fire Up the Stack**
   Bring the containers up in detached mode. Docker will automatically provision the local data volumes (`./etc-pihole` and `./etc-wireguard`) relative to your working directory:
   ```bash
   docker compose up -d
   ```

5. **Post-Deployment Verification**
   Ensure both containers are running cleanly: `docker compose ps`
   Access your local dashboards:
   Pi-hole Web UI: `http://<YOUR_PI_IP>:8080/admin`
   WireGuard Web UI: `http://<YOUR_PI_IP>:51821`

## 🔒 Edge & Router Configuration
   To allow external mobile devices to connect back to your WireGuard instance safely:
   Port Forwarding: Log into your home network gateway router and forward external UDP port 51820 to your Raspberry Pi's local static IP address.
   Host Firewall (Optional): If running UFW on your Pi, ensure forwarding paths from Docker's virtual bridge (`172.20.0.0/16`) are permitted to interact with your local physical network interfaces.

## 💾 Backups & Maintenance
All persistent states are safely isolated in local project directories:
`./etc-pihole/` (Adlists, DNS records, configuration flags)
`./etc-wireguard/` (Cryptographic server keys, client lists, peer state)

**To update the stack to the latest container releases:**

```bash
docker compose pull
docker compose up -d --remove-orphans
```
