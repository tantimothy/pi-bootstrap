#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ACTION="${1:-list}"

[ -f "$SCRIPT_DIR/.env" ] && { set -a; source "$SCRIPT_DIR/.env"; set +a; }

INSTALL_PATH="${INTERNET_PI_INSTALL_PATH:-/home/pi/internet-pi}"
PIHOLE_ENABLE="${PIHOLE_ENABLE:-true}"
MONITORING_ENABLE="${MONITORING_ENABLE:-true}"

# Resolve the host's LAN IP so these URLs are actually usable from another
# device — "localhost" only means something on the Pi's own terminal.
HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
[ -z "$HOST_IP" ] && HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$HOST_IP" ] && HOST_IP="localhost"

WEB_UIS=""
[ "$PIHOLE_ENABLE" = "true" ]     && WEB_UIS="${WEB_UIS}   http://${HOST_IP}/admin                                                          # Pi-hole Admin
"
[ "$MONITORING_ENABLE" = "true" ] && WEB_UIS="${WEB_UIS}   http://${HOST_IP}:3030                                                           # Grafana dashboards
"

DATA_DIRS=("$HOME/pi-hole" "$HOME/internet-monitoring/grafana" "$HOME/internet-monitoring/prometheus")
WIPE_PARENT_DIRS=("$HOME/internet-monitoring")
DATA_DESCRIPTIONS=(
    "Pi-hole config, gravity database, custom blocklists, local DNS records"
    "Grafana dashboard definitions, data source config, user settings"
    "Prometheus time-series metrics — speedtest history, ping latency, uptime"
)
INSTALL_DIRS=("$INSTALL_PATH")
INSTALL_DESCRIPTIONS=("internet-pi repo clone + generated config.yml and inventory.ini")
NAMED_VOLUMES=(); NAMED_VOLUME_DESCRIPTIONS=()
DATA_DIRS_LABEL="📁 Persistent Data Directories (back these up):"
INSTALL_DIRS_LABEL="📂 Install Directories (can be re-cloned):"
DELETE_INSTALL_DIRS=true
DELETE_CONFIRM_MSG="All Pi-hole settings and Grafana dashboards will be lost."
USEFUL_COMMANDS="🌐 Web UIs:
${WEB_UIS}
   cd ${INSTALL_PATH} && ansible-playbook main.yml -i inventory.ini              # Re-run playbook
   cd ${INSTALL_PATH} && git pull && ansible-playbook main.yml -i inventory.ini  # Update + re-run
   docker logs -f pihole                                                          # Pi-hole live logs
   docker logs -f grafana                                                         # Grafana live logs
   cd ~/internet-monitoring && docker compose logs -f                             # All monitoring logs
   docker exec -it pihole pihole setpassword                                      # Change Pi-hole password
   docker exec -it pihole pihole -g                                               # Update gravity/blocklists"

source "$REPO_DIR/lib/info-lib.sh"
run_info
