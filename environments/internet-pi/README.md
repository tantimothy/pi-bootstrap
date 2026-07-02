# Internet Pi

Ansible-based Raspberry Pi setup for internet monitoring and network-wide ad blocking. Created by Jeff Geerling.

Source: [github.com/geerlingguy/internet-pi](https://github.com/geerlingguy/internet-pi)

---

## What It Deploys

| Service | Container | Port | Purpose |
|---------|-----------|------|---------|
| Pi-hole | `pihole` | 80, 53 | Network-wide DNS ad blocking |
| Grafana | `grafana` | 3030 | Dashboard — speedtest history, ping latency, uptime |
| Prometheus | `prometheus` | 9090 | Metrics storage |
| Speedtest | `speedtest` | — | Runs internet speed tests on a schedule |
| Ping/Blackbox | `ping` | — | Probes configured URLs for availability |
| Node Exporter | `nodeexp` | 9100 | Pi system metrics (CPU, RAM, disk) |

---

## Deployment

This environment uses **Ansible** (not Docker Compose directly). `run.sh` handles the full lifecycle:

1. Installs Ansible via pip3 if not present
2. Clones `geerlingguy/internet-pi` to `INTERNET_PI_INSTALL_PATH`
3. Installs Ansible Galaxy collections (`community.docker`, `community.general`, `ansible.posix`)
4. Generates `config.yml` and `inventory.ini` from your `.env` values
5. Runs `ansible-playbook main.yml` targeting the Pi locally

**First run takes 5–10 minutes** — Docker images are large.

**FAST policy** checks if `pihole`, `grafana`, and `prometheus` containers are all running. If yes, exits immediately. If any are missing, re-runs the playbook (Ansible is idempotent — safe to re-run).

**CLEAN policy** stops all internet-pi containers, wipes the install directory, then does a fresh install.

---

## Configuration (`.env`)

| Variable | Purpose | Default |
|----------|---------|---------|
| `INTERNET_PI_INSTALL_PATH` | Where to clone the repo | `/home/pi/internet-pi` |
| `PIHOLE_ENABLE` | Deploy Pi-hole | `true` |
| `PIHOLE_TIMEZONE` | Pi-hole timezone | `Asia/Singapore` |
| `PIHOLE_PASSWORD` | Pi-hole admin dashboard password | *(required)* |
| `MONITORING_ENABLE` | Deploy Grafana + Prometheus + speedtest | `true` |
| `MONITORING_GRAFANA_ADMIN_PASSWORD` | Grafana admin password | *(required)* |
| `MONITORING_SPEEDTEST_INTERVAL` | How often to run a speed test | `60m` |

For advanced options (custom ping hosts, domain names, Shelly Plug, AirGradient, Starlink), edit `config.yml` inside the install directory directly after first deploy. Note that re-deploying from the TUI will overwrite `config.yml` with values from `.env`.

---

## ⚠️ Conflict with pihole-wireguard

Internet Pi's Pi-hole and the `pihole-wireguard` environment both bind **port 53** (DNS) and **port 80** on the host. Do not run both simultaneously.

- **pihole-wireguard** — Pi-hole + WireGuard VPN; DNS filtering applies to VPN clients
- **internet-pi** — Pi-hole + internet monitoring dashboard; no VPN

Choose one. If you want both Pi-hole and WireGuard, use `pihole-wireguard`.

---

## 💾 Data Directories

| Directory | Contents | Survives CLEAN? |
|-----------|---------|----------------|
| `~/pi-hole/` | Pi-hole config, gravity database, custom blocklists, local DNS records | ✅ Yes |
| `~/internet-monitoring/grafana/` | Grafana dashboard definitions, data source config, user settings | ✅ Yes |
| `~/internet-monitoring/prometheus/` | Prometheus time-series metrics — speedtest history, ping latency | ✅ Yes |
| `~/internet-pi/` | Repo clone + generated config.yml and inventory.ini | ❌ Wiped by CLEAN |

The data directories above are NOT touched by CLEAN — only the install directory is removed and re-cloned.

**Back up before WIPE:**
```bash
cp -r ~/pi-hole                      ~/backup/
cp -r ~/internet-monitoring/grafana  ~/backup/
cp -r ~/internet-monitoring/prometheus ~/backup/
```

---

## 🎛️ Deployment Policies

| Policy | Action |
|--------|--------|
| `FAST` | Start containers if not running; skip if already active |
| `STOP` | Pause all containers (resumable with FAST) |
| `TEARDOWN` | Stop + remove all 6 containers; data directories untouched |
| `CLEAN` | Stop containers, wipe install dir, re-clone, re-run playbook |
| `INFO` | List data directories with sizes and useful commands |
| `WIPE` | Delete `~/pi-hole/` and `~/internet-monitoring/` data dirs |

---

## 💡 Useful Commands

```bash
# Re-run the Ansible playbook (e.g. after editing .env or config.yml)
cd ~/internet-pi && ansible-playbook main.yml -i inventory.ini

# Update internet-pi to latest release
cd ~/internet-pi && git pull && ansible-playbook main.yml -i inventory.ini

# Change Pi-hole admin password
docker exec -it pihole pihole setpassword

# Update Pi-hole gravity (blocklists)
docker exec -it pihole pihole -g

# Follow all monitoring logs
cd ~/internet-monitoring && docker compose logs -f

# View Pi-hole or Grafana logs individually
docker logs -f pihole
docker logs -f grafana
```
