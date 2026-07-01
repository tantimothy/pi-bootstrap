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

POLICY="${REBUILD_POLICY:-FAST}"

# STOP: pause containers (keep them, FAST can resume)
if [ "$POLICY" = "STOP" ]; then
    echo "🛑 [STOP] Pausing pihole-wireguard stack (containers preserved)..."
    $DOCKER_COMPOSE --env-file "$ENV_FILE" stop || true
    echo "✅ Stack paused. Run with FAST to resume."
    exit 0
fi

# TEARDOWN: stop + remove containers, no reinstall
if [ "$POLICY" = "TEARDOWN" ]; then
    echo "🗑️  [TEARDOWN] Stopping and removing pihole-wireguard stack..."
    $DOCKER_COMPOSE --env-file "$ENV_FILE" down --remove-orphans || true
    echo "✅ Stack torn down."
    exit 0
fi

# Resolve deterministic local scopes
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

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
    echo "❌ Error: Mandatory target environment configuration file (.env) missing." >&2
    echo "   Ensure your parent TUI wizard has parsed your configurations." >&2
    exit 1
fi

# Fallback boundaries to safeguard the deployment if unassigned
: "${PIHOLE_WEB_PORT:=8080}"
: "${WG_UI_PORT:=51821}"

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
# 4. Advanced Policy Engine Routing State Machine
# ---------------------------------------------------------------------------------------
CONTAINER_NAMES=("pihole" "wg-easy")
ALL_RUNNING=true
ANY_EXISTS=false
ANY_STOPPED=false

for name in "${CONTAINER_NAMES[@]}"; do
    RUNNING_STATE=$("$DOCKER" inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo "MISSING")
    
    if [ "$RUNNING_STATE" = "true" ]; then
        ANY_EXISTS=true
    elif [ "$RUNNING_STATE" = "false" ]; then
        ANY_EXISTS=true
        ANY_STOPPED=true
        ALL_RUNNING=false
    else
        ALL_RUNNING=false
    fi
done

# Evaluate image availability to detect completely blank/pruned states
IMAGE_EVAL_PIHOLE=$("$DOCKER" images -q pihole/pihole:latest 2>/dev/null || true)
IMAGE_EVAL_WGEASY=$("$DOCKER" images -q ghcr.io/wg-easy/wg-easy:latest 2>/dev/null || true)

# Operational Policy Routing Engine
if [ "$POLICY" = "FAST" ]; then
    # Strategy Shortcut 1A: Container is actively running
    if [ "$ALL_RUNNING" = "true" ]; then
        echo "✅ [FAST POLICY] Stack containers are active and serving traffic."
        echo "🚀 Maximizing platform uptime. Bypassing execution pipeline."
        echo "=========================================================="
        exit 0
    fi

    # Strategy Shortcut 1B: Container is stopped, image exists
    if [ "$ANY_STOPPED" = "true" ] && [ -n "$IMAGE_EVAL_PIHOLE" ] && [ -n "$IMAGE_EVAL_WGEASY" ]; then
        echo "🔄 [FAST POLICY] Containers exist but are stopped."
        echo "⚡ Executing non-destructive fast-start recovery to preserve local data configurations..."
        $DOCKER_COMPOSE --env-file "$ENV_FILE" start
        echo "✅ System lifecycle restored smoothly."
        echo "=========================================================="
        exit 0
    fi
fi

# Rebuild Execution Strategies
if [ "$POLICY" = "CLEAN" ]; then
    echo "🧹 [CLEAN POLICY] Force eviction and zero-cache pipeline requested."
    echo "🛑 Dismantling operational environments..."
    $DOCKER_COMPOSE --env-file "$ENV_FILE" down --volumes --remove-orphans || true
    
    echo "🗑️  Evicting local image layers (fresh pull will follow)..."
    "$DOCKER" rmi pihole/pihole:latest ghcr.io/wg-easy/wg-easy:latest 2>/dev/null || true

elif [ "$POLICY" = "FAST" ]; then
    echo "🛠️  [FAST POLICY] Footprint missing. Images will be pulled below."
else
    echo "❌ Error: Unrecognized runtime policy context profile: '${POLICY}'" >&2
    exit 1
fi

# ---------------------------------------------------------------------------------------
# 5. Pipeline Layer Pulling & Detached Launch Execution
# ---------------------------------------------------------------------------------------
echo "📥 Orchestrating container deployment manifest layers..."

if [ "$POLICY" = "CLEAN" ]; then
    $DOCKER_COMPOSE --env-file "$ENV_FILE" pull --quiet
else
    $DOCKER_COMPOSE --env-file "$ENV_FILE" pull
fi

echo "🦅 Launching system infrastructure nodes into background space..."
$DOCKER_COMPOSE --env-file "$ENV_FILE" up -d --remove-orphans

# ---------------------------------------------------------------------------------------
# 6. Pipeline Sanity Validation & Telemetry Output
# ---------------------------------------------------------------------------------------
echo "=========================================================="
echo "🏁 Infrastructure Execution Pipeline Completed Successfully!"
echo "=========================================================="
echo "🌍 Pi-hole Web Admin Panel:  http://${HOST_IP}:${PIHOLE_WEB_PORT}/admin"
echo "🔐 WireGuard Web Dashboard: http://${HOST_IP}:${WG_UI_PORT}"
echo "=========================================================="
echo ""
echo "📌 Post-Install Notes (normally shown by the installer, hidden behind the container build):"
echo ""
echo "  🔑 Pi-hole: change/reset the admin web UI password"
echo "     docker exec -it pihole pihole setpassword"
echo ""
echo "  🌐 Pi-hole: config lives at ./etc-pihole/pihole.toml on the host."
echo "     Edits via env vars only seed it on first creation — use the web UI"
echo "     (Settings > All Settings) or 'pihole-FTL --config <key> <value>' afterward."
echo ""
echo "  ➕ WireGuard: add a client / device"
echo "     Open the Web Dashboard above, click 'New Client', then scan the QR code"
echo "     with the WireGuard mobile app, or download the .conf for desktop clients."
echo ""
echo "  📡 WireGuard: remote access requires router port forwarding"
echo "     Forward external UDP port ${WG_PORT:-51820} to this Pi's local static IP"
echo "     on your home router/gateway, or remote peers will never reach the tunnel."
echo ""
echo "  👀 WireGuard: check connected peers / tunnel status"
echo "     docker exec -it wg-easy wg show"
echo ""
echo "  💾 WireGuard: persistent state (server keys, peer configs) lives at"
echo "     ./etc-wireguard on the host — back this up; losing it invalidates all"
echo "     existing client configs and requires re-adding every device."
echo ""
echo "  🔑 WireGuard: change the dashboard login password"
echo "     1. docker run --rm -it ghcr.io/wg-easy/wg-easy wgpw 'your_new_password'"
echo "     2. Copy the printed hash into PASSWORD_HASH= in .env (single-quote it,"
echo "        e.g. PASSWORD_HASH='\$2y\$12\$...' — unquoted \$ characters get"
echo "        mangled when this script sources .env)"
echo "     3. docker compose up -d --force-recreate wg-easy"
echo ""
echo "  ⚙️  FTLCONF_webserver_api_password (Pi-hole) only seeds pihole.toml on FIRST"
echo "     container creation, then is ignored — use 'pihole setpassword' to"
echo "     change it later, not the .env value."
echo "  ⚙️  WG_HOST (WireGuard) is read fresh on every container start, so editing"
echo "     it in .env + 'docker compose up -d --force-recreate wg-easy' does take"
echo "     effect — but any client .conf/QR code you already downloaded is a"
echo "     static snapshot of the OLD host and won't update; redownload it from"
echo "     the dashboard for each existing peer after changing WG_HOST."
echo "=========================================================="