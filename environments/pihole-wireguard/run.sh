#!/usr/bin/env bash

# =======================================================================================
# ADVANCED PIPELINE ORCHESTRATION SH WRAPPER (run.sh)
# Clean, Unescaped Production Template
# =======================================================================================

# Fail fast on command errors, unassigned variables, or broken pipes
set -euo pipefail

# ---------------------------------------------------------------------------------------
# 1. Framework Variable Inheritance & Core Setup
# ---------------------------------------------------------------------------------------
DOCKER="${DOCKER_CMD:-docker}"

# Force detection of the correct compose command
if command -v docker-compose &> /dev/null; then
    # Older standalone binary
    DOCKER_COMPOSE="docker-compose"
elif docker compose version &> /dev/null; then
    # Newer docker plugin
    DOCKER_COMPOSE="docker compose"
else
    echo "❌ ERROR: No compatible docker-compose command found!" >&2
    exit 1
fi

# Apply sudo prefix if needed (re-using the logic from your deploy.sh)
if ! $DOCKER ps &>/dev/null; then
    DOCKER="sudo $DOCKER"
    DOCKER_COMPOSE="sudo $DOCKER_COMPOSE"
fi

# Resolve directory and env file early so STOP/TEARDOWN work standalone
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"

POLICY="${REBUILD_POLICY:-FAST}"

# STOP: pause containers (keep them, FAST can resume)
if [ "$POLICY" = "STOP" ]; then
    echo "🛑 [STOP] Pausing pihole-wireguard stack (containers preserved)..."
    cd "$SCRIPT_DIR"
    $DOCKER_COMPOSE --env-file "$ENV_FILE" stop || true
    echo "✅ Stack paused. Run with FAST to resume."
    exit 0
fi

# TEARDOWN: stop + remove containers, no reinstall
if [ "$POLICY" = "TEARDOWN" ]; then
    echo "🗑️  [TEARDOWN] Stopping and removing pihole-wireguard stack..."
    cd "$SCRIPT_DIR"
    $DOCKER_COMPOSE --env-file "$ENV_FILE" down --remove-orphans || true
    echo "✅ Stack torn down."
    exit 0
fi

echo "=========================================================="
echo "🎬 Subsystem Execution Pipeline Initiated"
echo "⚙️  Active Compilation Strategy Policy: ${POLICY}"
echo "=========================================================="

# ---------------------------------------------------------------------------------------
# 2. Workspace Context & Secret Sourcing
# ---------------------------------------------------------------------------------------
cd "$SCRIPT_DIR"

if [ -f "$ENV_FILE" ]; then
    echo "🔑 Sourcing runtime variables and secrets from configuration ecosystem..."

    # Safely auto-export all variables, respecting spaces and quotes
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "❌ Error: .env file missing." >&2
    echo "   Copy .env.example to .env and fill in the values, then re-run." >&2
    exit 1
fi

# Fallback boundaries to safeguard the deployment if unassigned
: "${PIHOLE_WEB_PORT:=80}"
: "${WG_UI_PORT:=51821}"
: "${GRAFANA_PORT:=3030}"
: "${UPTIME_KUMA_PORT:=3001}"
: "${WG_PORT:=51820}"

# Detect host LAN IP so post-deploy URLs are immediately clickable/copyable
HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
[ -z "$HOST_IP" ] && HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$HOST_IP" ] && HOST_IP="localhost"

# ---------------------------------------------------------------------------------------
# 3. Pre-emptive Volume Generation & Permission Management
# ---------------------------------------------------------------------------------------
echo "📁 Executing pre-emptive volume generation routines..."
mkdir -p "${SCRIPT_DIR}/etc-pihole"
mkdir -p "${SCRIPT_DIR}/etc-wireguard"
echo "✅ Local host storage layout initialized cleanly."

# ---------------------------------------------------------------------------------------
# 3b. Host System Prerequisites (nftables masquerade + IP forwarding)
#     wg-easy runs with network_mode: host so the host kernel handles NAT.
#     This block is idempotent — safe to re-run on every deploy.
# ---------------------------------------------------------------------------------------
echo "🔧 Configuring host network prerequisites for WireGuard..."

# Enable IP forwarding and WireGuard mark routing persistently
sudo tee /etc/sysctl.d/wireguard.conf > /dev/null << 'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.src_valid_mark=1
EOF
sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null
sudo sysctl -w net.ipv4.conf.all.src_valid_mark=1 > /dev/null

# Write the nftables masquerade rule file for VPN traffic.
# No interface pinned — works on eth0, wlan0, or any future interface.
sudo mkdir -p /etc/nftables.d
sudo tee /etc/nftables.d/wireguard.nft > /dev/null << 'NFTEOF'
table ip wg-nat {
    chain POSTROUTING {
        type nat hook postrouting priority 100; policy accept;
        ip saddr 10.8.0.0/24 masquerade
    }
}
NFTEOF

# Load rule now (flush first so re-runs don't duplicate rules)
sudo nft delete table ip wg-nat 2>/dev/null || true
sudo nft -f /etc/nftables.d/wireguard.nft

# Ensure /etc/nftables.conf includes our file so it loads on every boot
if ! grep -qsF 'wireguard.nft' /etc/nftables.conf 2>/dev/null; then
    echo 'include "/etc/nftables.d/wireguard.nft"' | sudo tee -a /etc/nftables.conf > /dev/null
fi

# Enable nftables service to restore rules on reboot
sudo systemctl enable nftables > /dev/null 2>&1 || true

echo "✅ Host network prerequisites configured."

# ---------------------------------------------------------------------------------------
# 3c. Grafana / Prometheus monitoring setup
#     Downloads community dashboards on first deploy (skips if files already exist).
# ---------------------------------------------------------------------------------------
echo "📊 Setting up monitoring directories..."
mkdir -p "${SCRIPT_DIR}/monitoring/grafana/dashboards"

download_dashboard() {
    local id="$1" name="$2"
    local outfile="${SCRIPT_DIR}/monitoring/grafana/dashboards/${name}.json"
    if [ ! -f "$outfile" ]; then
        echo "📥 Downloading Grafana dashboard: ${name} (ID ${id})..."
        if curl -fsSL --max-time 15 "https://grafana.com/api/dashboards/${id}/revisions/latest/download" \
            | sed 's/\${DS_PROMETHEUS}/prometheus/g; s/\${DS_WIREGUARD}/prometheus/g; s/\${DS_PROM}/prometheus/g' \
            > "$outfile"; then
            echo "✅ Dashboard downloaded: ${name}"
        else
            rm -f "$outfile"
            echo "⚠️  Could not download dashboard '${name}' (ID ${id}) — no internet? Skipping."
            echo "   You can import it manually later at http://${HOST_IP}:${GRAFANA_PORT} → Dashboards → Import → ID ${id}"
        fi
    fi
}

# Pi-hole metrics dashboard (works with ekofr/pihole-exporter)
download_dashboard 10176 "pihole"
# WireGuard peer stats dashboard (works with mindflavor/prometheus-wireguard-exporter)
download_dashboard 12177 "wireguard"
# Node Exporter Full (works with prom/node-exporter)
download_dashboard 1860 "node-exporter"
# Blackbox Exporter overview (works with prom/blackbox-exporter)
download_dashboard 7587 "blackbox"
# Speedtest Exporter dashboard (works with miguelndecarvalho/speedtest-exporter)
download_dashboard 13665 "speedtest"

echo "✅ Monitoring setup complete."

# ---------------------------------------------------------------------------------------
# 3d. PADD — Pi-hole live stats dashboard
#     Downloads padd.sh once, then injects a .bashrc block that auto-launches it in
#     a dedicated tmux window on every login. Idempotent: re-deploy replaces the block.
#     Runs here (before FAST early-exit) so it always executes regardless of stack state.
# ---------------------------------------------------------------------------------------
PADD_SCRIPT="$HOME/padd.sh"

# PADD requires jq (JSON parsing) and dnsutils (dig) on the host
if ! command -v jq &>/dev/null || ! command -v dig &>/dev/null; then
    echo "📦 Installing PADD dependencies (jq, dnsutils)..."
    sudo apt-get install -y jq dnsutils 2>/dev/null || true
fi

if [ ! -f "$PADD_SCRIPT" ]; then
    echo "📊 Downloading PADD (Pi-hole terminal dashboard)..."
    if curl -fsSL --max-time 15 \
        "https://raw.githubusercontent.com/pi-hole/PADD/master/padd.sh" \
        -o "$PADD_SCRIPT"; then
        chmod +x "$PADD_SCRIPT"
        echo "✅ PADD downloaded."
    else
        echo "⚠️  Could not download PADD — skipping. Get it from https://github.com/pi-hole/PADD"
    fi
fi

if [ -f "$PADD_SCRIPT" ]; then
    BASHRC="$HOME/.bashrc"
    PADD_MARKER_START="# >>> PIHOLE-WIREGUARD PADD START >>>"
    PADD_MARKER_END="# <<< PIHOLE-WIREGUARD PADD END <<<"
    PADD_PASS="${FTLCONF_webserver_api_password:-}"
    touch "$BASHRC"
    if grep -qF "$PADD_MARKER_START" "$BASHRC"; then
        sed -i "/$PADD_MARKER_START/,/$PADD_MARKER_END/d" "$BASHRC"
    fi
    cat >> "$BASHRC" << EOF
$PADD_MARKER_START
if [ -n "\$TMUX" ] && [ -f ~/padd.sh ]; then
    if ! tmux list-windows -F '#W' 2>/dev/null | grep -q '^padd\$'; then
        tmux new-window -n padd "~/padd.sh --secret '${PADD_PASS}'"
    fi
fi
$PADD_MARKER_END
EOF
    echo "📊 PADD configured — will auto-launch in a tmux window 'padd' on next login."
fi

# ---------------------------------------------------------------------------------------
# 4. Advanced Policy Engine Routing State Machine
# ---------------------------------------------------------------------------------------
CONTAINER_NAMES=("pihole" "wg-easy" "pihole-exporter" "wireguard-exporter" "prometheus" "grafana" "uptime-kuma" "node-exporter" "speedtest-exporter" "blackbox-exporter")
ALL_RUNNING=true

for name in "${CONTAINER_NAMES[@]}"; do
    RUNNING_STATE=$("$DOCKER" inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo "MISSING")
    if [ "$RUNNING_STATE" != "true" ]; then
        ALL_RUNNING=false
        break
    fi
done

# Operational Policy Routing Engine
if [ "$POLICY" = "FAST" ]; then
    if [ "$ALL_RUNNING" = "true" ]; then
        echo "✅ [FAST POLICY] Stack containers are active and serving traffic."
        echo "🚀 Maximizing platform uptime. Bypassing execution pipeline."
        echo "=========================================================="
        exit 0
    fi
    echo "🛠️  [FAST POLICY] One or more containers missing or stopped — deploying..."
elif [ "$POLICY" = "CLEAN" ]; then
    echo "🧹 [CLEAN POLICY] Force eviction and zero-cache pipeline requested."
    echo "🛑 Dismantling operational environments..."
    $DOCKER_COMPOSE --env-file "$ENV_FILE" down --volumes --remove-orphans || true

    echo "🗑️  Evicting local image layers (fresh pull will follow)..."
    "$DOCKER" rmi pihole/pihole:latest ghcr.io/wg-easy/wg-easy:latest \
        ekofr/pihole-exporter:latest mindflavor/prometheus-wireguard-exporter:latest \
        prom/prometheus:latest grafana/grafana:latest \
        louislam/uptime-kuma:latest prom/node-exporter:latest \
        ghcr.io/miguelndecarvalho/speedtest-exporter:latest \
        prom/blackbox-exporter:latest 2>/dev/null || true
else
    echo "❌ Error: Unrecognized runtime policy context profile: '${POLICY}'" >&2
    exit 1
fi

# ---------------------------------------------------------------------------------------
# 5. Pipeline Layer Pulling & Detached Launch Execution
# ---------------------------------------------------------------------------------------
echo "📥 Orchestrating container deployment manifest layers..."
$DOCKER_COMPOSE --env-file "$ENV_FILE" pull

echo "🦅 Launching system infrastructure nodes into background space..."
$DOCKER_COMPOSE --env-file "$ENV_FILE" up -d --remove-orphans

# ---------------------------------------------------------------------------------------
# 6. Pipeline Sanity Validation & Telemetry Output
# ---------------------------------------------------------------------------------------
export HOST_IP PIHOLE_WEB_PORT WG_UI_PORT GRAFANA_PORT UPTIME_KUMA_PORT WG_PORT
envsubst '${HOST_IP} ${PIHOLE_WEB_PORT} ${WG_UI_PORT} ${GRAFANA_PORT} ${UPTIME_KUMA_PORT} ${WG_PORT}' \
    < "$SCRIPT_DIR/post-deploy.txt"
