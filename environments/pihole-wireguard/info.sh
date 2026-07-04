#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ACTION="${1:-list}"

[ -f "$SCRIPT_DIR/.env" ] && { set -a; source "$SCRIPT_DIR/.env"; set +a; }

: "${GRAFANA_PORT:=3030}"
: "${PIHOLE_WEB_PORT:=80}"

DATA_DIRS=("$SCRIPT_DIR/etc-pihole" "$SCRIPT_DIR/etc-wireguard")
DATA_DESCRIPTIONS=(
    "Pi-hole config, gravity database, custom blocklists, local DNS records"
    "WireGuard server keys + all peer configs — losing this invalidates every client VPN"
)
INSTALL_DIRS=(); INSTALL_DESCRIPTIONS=()
NAMED_VOLUMES=("prometheus_data" "grafana_data" "uptime_kuma_data")
NAMED_VOLUME_DESCRIPTIONS=(
    "Prometheus time-series metrics (peer transfer stats, Pi-hole query history)"
    "Grafana database — saved dashboards, alert rules, user preferences"
    "Uptime Kuma database — all monitors, notification channels, incident history"
)
DATA_DIRS_LABEL="📁 Persistent Data Directories (local):"
DELETE_CONFIRM_MSG=$'This permanently deletes all listed directories and Docker volumes.\nWireGuard peer configs will be unrecoverable.'
USEFUL_COMMANDS="   docker exec -it pihole pihole setpassword                        # Change Pi-hole admin password
   docker exec -it wg-easy wg show                                  # Show connected WireGuard peers and transfer stats
   docker run --rm -it ghcr.io/wg-easy/wg-easy wgpw 'pass'        # Generate new bcrypt hash for PASSWORD_HASH
   docker logs -f pihole                                            # Pi-hole live logs
   docker logs -f wg-easy                                           # WireGuard live logs
   docker logs -f grafana                                           # Grafana live logs
   docker compose -f ${SCRIPT_DIR}/docker-compose.yml ps           # Full stack status
   tmux attach                                                      # Attach to tmux (PADD is in the 'padd' window)
   ~/padd.sh                                                        # Run PADD manually
   docker logs -f uptime-kuma                                       # Uptime Kuma live logs

📊 Backup named volumes:
   docker run --rm -v prometheus_data:/data -v \$(pwd):/backup alpine tar czf /backup/prometheus_data.tar.gz /data
   docker run --rm -v grafana_data:/data -v \$(pwd):/backup alpine tar czf /backup/grafana_data.tar.gz /data"

source "$REPO_DIR/lib/info-lib.sh"
run_info
