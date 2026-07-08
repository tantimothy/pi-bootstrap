#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ACTION="${1:-list}"

[ -f "$SCRIPT_DIR/.env" ] && { set -a; source "$SCRIPT_DIR/.env"; set +a; }

: "${NTOPNG_PORT:=3002}"

# Resolve the host's LAN IP so these URLs are actually usable from another
# device — "localhost" only means something on the Pi's own terminal.
HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
[ -z "$HOST_IP" ] && HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$HOST_IP" ] && HOST_IP="localhost"

DATA_DIRS=("$SCRIPT_DIR/ntopng-data" "$SCRIPT_DIR/ntopng-redis-data")
DATA_DESCRIPTIONS=(
    "ntopng's own local state (host/interface config, license if any)"
    "ntopng's Redis-backed historical/timeseries data — per-flow trends over days/weeks"
)
INSTALL_DIRS=(); INSTALL_DESCRIPTIONS=()
NAMED_VOLUMES=(); NAMED_VOLUME_DESCRIPTIONS=()
DELETE_CONFIRM_MSG="All ntopng traffic history and historical/timeseries data will be lost."
WEB_UI_NAMES=(
    "ntopng deep traffic analysis (default login: admin/admin)"
)
WEB_UI_URLS=(
    "http://${HOST_IP}:${NTOPNG_PORT}"
)
USEFUL_COMMANDS="   docker logs -f ntopng                                            # ntopng live logs
   docker logs -f ntopng-redis                                      # ntopng-redis logs
   docker compose -f ${SCRIPT_DIR}/docker-compose.yml ps           # Stack status

📌 Notes:
   🔒 ntopng ships with default admin/admin credentials — you'll be prompted
      to change the password on first login. There's no env var to pre-seed
      a different one, so this step can't be skipped or automated.
   🔌 ntopng and ntopng-redis both run with network_mode: host (needed for
      raw packet capture on the real interface) — ntopng reaches Redis over
      127.0.0.1:6379 rather than the ntopng-redis container name, since
      Docker's bridge-network service discovery doesn't apply between them.
   🛠️  ntopng is built locally from ./Dockerfile rather than pulled — the
      official ntop/ntopng image only ever publishes linux/amd64, which
      crash-loops with \"exec format error\" on a Pi's ARM CPU. Building
      locally targets whatever CPU runs ./run.sh automatically."

source "$REPO_DIR/lib/info-lib.sh"
run_info
