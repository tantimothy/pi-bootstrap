# Internet Pi

Ansible-based Raspberry Pi setup for internet monitoring and network-wide ad blocking. Created by Jeff Geerling.

Source: [github.com/geerlingguy/internet-pi](https://github.com/geerlingguy/internet-pi)

---

## 🔧 Tools & Projects

| Tool | Link | Description |
|------|------|-------------|
| internet-pi | [github.com/geerlingguy/internet-pi](https://github.com/geerlingguy/internet-pi) | Jeff Geerling's Ansible playbook for Raspberry Pi internet monitoring — the upstream project this environment deploys |
| Pi-hole | [pi-hole.net](https://pi-hole.net) | Network-wide DNS-based ad and tracker blocker |
| Grafana | [grafana.com](https://grafana.com) | Time-series dashboard — pre-built views for speedtest history, ping latency, and system health |
| Prometheus | [prometheus.io](https://prometheus.io) | Metrics scraping and time-series storage backend |
| Speedtest Exporter | [github.com/MiguelNdeCarvalho/speedtest-exporter](https://github.com/MiguelNdeCarvalho/speedtest-exporter) | Runs Speedtest CLI on a schedule and exposes results as Prometheus metrics |
| Blackbox Exporter | [github.com/prometheus/blackbox_exporter](https://github.com/prometheus/blackbox_exporter) | Probes HTTP/HTTPS endpoints and ICMP ping targets — used for uptime and latency monitoring |
| Node Exporter | [github.com/prometheus/node_exporter](https://github.com/prometheus/node_exporter) | Exposes Pi host system metrics (CPU, RAM, disk, network I/O) to Prometheus |
| Ansible | [ansible.com](https://www.ansible.com) | Agentless automation tool — internet-pi uses it to configure the Pi and manage Docker containers declaratively |

---

## What It Deploys

| Service | Container | Port | Purpose |
|---------|-----------|------|---------|
| [Pi-hole](https://pi-hole.net) | `pihole` | 80, 53 | Network-wide DNS ad blocking |
| [Grafana](https://grafana.com) | `grafana` | 3030 | Dashboard — speedtest history, ping latency, uptime |
| [Prometheus](https://prometheus.io) | `prometheus` | 9090 | Metrics storage |
| [Speedtest Exporter](https://github.com/MiguelNdeCarvalho/speedtest-exporter) | `speedtest` | — | Runs internet speed tests on a schedule |
| [Blackbox Exporter](https://github.com/prometheus/blackbox_exporter) | `ping` | — | Probes configured URLs for availability |
| [Node Exporter](https://github.com/prometheus/node_exporter) | `nodeexp` | 9100 | Pi system metrics (CPU, RAM, disk) |

---

## Deployment

This environment uses **Ansible** (not Docker Compose directly). `run.sh` handles the full lifecycle:

1. Installs Ansible via pip3 if not present
2. Clones `geerlingguy/internet-pi` to `INTERNET_PI_INSTALL_PATH`
3. Installs Ansible Galaxy collections (`community.docker`, `community.general`, `ansible.posix`)
4. Generates `config.yml` and `inventory.ini` from your `.env` values
5. Runs `ansible-playbook main.yml` targeting the Pi locally

**First run takes 5–10 minutes** — Docker images are large.

**FAST policy** checks if `pihole`, `grafana`, and `prometheus` containers are all running, but always re-runs the Ansible playbook regardless — Ansible is idempotent (it only touches what's actually drifted from `config.yml`), so this is what lets a `.env` change take effect on a plain FAST run without needing the heavier CLEAN policy.

**CLEAN policy** wipes the install directory for a fresh clone, then runs Ansible galaxy/config/inventory steps, and only stops+removes the existing containers right before the Ansible playbook run (which recreates them). Containers are deliberately kept running through the git clone/pull and `ansible-galaxy` steps in between — if `PIHOLE_ENABLE=true`, Pi-hole may be this host's own DNS resolver, and those steps need working DNS to reach github.com/galaxy.ansible.com.

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
| `FAST` | Start containers if not running; otherwise re-run the (idempotent) Ansible playbook to pick up config changes |
| `STOP` | Pause all containers (resumable with FAST) |
| `TEARDOWN` | Stop + remove all 6 containers; data directories untouched |
| `CLEAN` | Wipe install dir, re-clone, re-run playbook — old containers stay up until right before the playbook recreates them |
| `INFO` | List data directories with sizes and useful commands (scrollable via `less` in an interactive terminal) |
| `WIPE` | Delete `~/pi-hole/`, `~/internet-monitoring/grafana/`, `~/internet-monitoring/prometheus/`, and `~/internet-monitoring/` |

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
