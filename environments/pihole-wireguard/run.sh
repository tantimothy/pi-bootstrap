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
: "${DARKSTAT_PORT:=667}"
: "${DARKSTAT_INTERFACES:=eth0}"

# Detect host LAN IP so post-deploy URLs are immediately clickable/copyable
HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
[ -z "$HOST_IP" ] && HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$HOST_IP" ] && HOST_IP="localhost"

# ---------------------------------------------------------------------------------------
# 2b. PADD launcher — idempotent .bashrc block (mirrors pi-barebones' own
#     MARKER_START/END pattern). padd.sh itself is user-managed, not
#     downloaded by this script — this only wires up the login launcher.
#     Always inserted *before* pi-barebones' fastfetch block if present (and
#     after its tmux block, which pi-barebones always re-pins to the very
#     top), so the login sequence is tmux → PADD → fastfetch regardless of
#     which environment was deployed first.
#
#     PADD auto-reads /etc/pihole/cli_pw (if readable) before falling back
#     to --secret or an interactive prompt, so the password is written there
#     instead of being passed as a CLI argument — a CLI arg would be visible
#     to any user on the system via `ps aux` for the process's whole
#     lifetime, not just recorded in shell history.
# ---------------------------------------------------------------------------------------
BASHRC="$HOME/.bashrc"
PADD_MARKER_START="# >>> PIHOLE-WIREGUARD PADD START >>>"
PADD_MARKER_END="# <<< PIHOLE-WIREGUARD PADD END <<<"
PI_FASTFETCH_MARKER_START="# >>> PI FASTFETCH SETUP START >>>"

touch "$BASHRC"

if [ -n "${FTLCONF_webserver_api_password:-}" ]; then
    sudo mkdir -p /etc/pihole
    sudo tee /etc/pihole/cli_pw > /dev/null <<< "${FTLCONF_webserver_api_password}"
    sudo chown "$(id -u):$(id -g)" /etc/pihole/cli_pw
    sudo chmod 600 /etc/pihole/cli_pw
fi

# Remove any existing block first so re-runs stay idempotent
if grep -qF "$PADD_MARKER_START" "$BASHRC"; then
    sed -i "/$PADD_MARKER_START/,/$PADD_MARKER_END/d" "$BASHRC"
fi

PADD_BLOCK=$(cat <<BASHRC_BLOCK
$PADD_MARKER_START

[ -x ~/padd.sh ] && ~/padd.sh

$PADD_MARKER_END
BASHRC_BLOCK
)

if grep -qF "$PI_FASTFETCH_MARKER_START" "$BASHRC"; then
    # pi-barebones' fastfetch block already exists — insert ours immediately
    # before it (pi-barebones' tmux block re-pins itself to the top on every
    # run regardless, so this alone is enough to guarantee tmux -> PADD -> fastfetch)
    awk -v block="$PADD_BLOCK" -v marker="$PI_FASTFETCH_MARKER_START" '
        index($0, marker) == 1 && !done { print block; done=1 }
        { print }
    ' "$BASHRC" > "${BASHRC}.tmp" && mv "${BASHRC}.tmp" "$BASHRC"
else
    # No pi-barebones fastfetch block yet — append at the end. If
    # pi-barebones is deployed later, its tmux block re-pins to the top and
    # its fastfetch block appends after this one, preserving order.
    { echo ""; echo "$PADD_BLOCK"; } >> "$BASHRC"
fi

# ---------------------------------------------------------------------------------------
# 3. Pre-emptive Volume Generation & Permission Management
# ---------------------------------------------------------------------------------------
echo "📁 Executing pre-emptive volume generation routines..."
mkdir -p "${SCRIPT_DIR}/etc-pihole"
mkdir -p "${SCRIPT_DIR}/etc-wireguard"
mkdir -p "${SCRIPT_DIR}/darkstat-db"
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
        # Community dashboards template their datasource as a "${DS_<name>}"
        # input variable, and the exact <name> varies per dashboard (e.g.
        # DS_PROMETHEUS, DS_WIREGUARD, DS_SIGNCL-PROMETHEUS). We only ever
        # provision one datasource, so rewrite any such token generically
        # instead of hardcoding specific names — a hardcoded list silently
        # misses whatever a given dashboard happens to call it, leaving an
        # unresolved placeholder and a "datasource not found" panel.
        if curl -fsSL --max-time 15 "https://grafana.com/api/dashboards/${id}/revisions/latest/download" \
            | sed -E 's/\$\{DS_[A-Za-z0-9_-]+\}/prometheus/g' \
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
# WireGuard: community dashboard 12177 is NOT downloaded — it queries
# wireguard_peer_*_bytes_total / wireguard_peer_info, which is a different
# exporter's naming scheme entirely. mindflavor/prometheus-wireguard-exporter
# (what this stack actually runs) emits wireguard_sent_bytes_total /
# wireguard_received_bytes_total / wireguard_latest_handshake_seconds
# instead, so 12177's panels always showed "No data". wireguard.json is a
# hand-authored dashboard matching those real metric names, committed
# directly to the repo (see monitoring/grafana/dashboards/.gitignore).
# Dashboard 17251 is a *different* community dashboard that was verified to
# use the correct metric names/labels for this exporter — downloaded
# alongside the hand-authored one as a second, independent option.
download_dashboard 17251 "wireguard-community"
# Node Exporter Full (works with prom/node-exporter)
download_dashboard 1860 "node-exporter"
# Blackbox Exporter overview (works with prom/blackbox-exporter)
download_dashboard 7587 "blackbox"
# Speedtest Exporter dashboard (works with miguelndecarvalho/speedtest-exporter)
download_dashboard 13665 "speedtest"

echo "✅ Monitoring setup complete."

# ---------------------------------------------------------------------------------------
# 4. Advanced Policy Engine Routing State Machine
# ---------------------------------------------------------------------------------------
CONTAINER_NAMES=("pihole" "wg-easy" "pihole-exporter" "wireguard-exporter" "prometheus" "grafana" "uptime-kuma" "node-exporter" "speedtest-exporter" "blackbox-exporter" "darkstat")
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
    echo "🧹 [CLEAN POLICY] Force fresh-image pipeline with rollback fallback."

    # Pull fresh images BEFORE tearing anything down. Pi-hole is this stack's
    # own DNS resolver — if we stop it first (as the old order did), the host
    # loses DNS and the subsequent pull can't resolve registry hostnames at
    # all, breaking a self-hosted-DNS Pi's ability to ever CLEAN itself.
    # Pulling while the old containers (Pi-hole included) are still up avoids
    # the chicken-and-egg problem entirely, and `docker compose pull` always
    # checks the registry for the latest digest regardless of local cache, so
    # this still gets a truly fresh set of images.
    echo "📥 Pulling fresh image layers while Pi-hole is still up to serve DNS..."
    $DOCKER_COMPOSE --env-file "$ENV_FILE" pull

    # Stop and snapshot the current containers into standalone fallback
    # images before removing them. A plain `docker rename` isn't enough here:
    # Compose matches existing containers by their project/service *labels*,
    # not by current container name, so a renamed-but-still-labeled container
    # would just get found and recreated (destroyed) by the very next
    # `docker compose up`. `docker commit` produces a fully independent image
    # with no Compose labels, so it's immune to that and is a real rollback.
    #
    # The tag is fixed (not timestamped) since only one fallback is ever kept
    # per container — a stable tag means the rollback command never changes.
    FALLBACK_TAG="clean-fallback"
    echo "🛑 Stopping current containers and snapshotting them as a rollback fallback..."
    for name in "${CONTAINER_NAMES[@]}"; do
        if "$DOCKER" inspect "$name" &>/dev/null; then
            "$DOCKER" stop "$name" &>/dev/null || true

            # `docker commit` below moves the "${name}:clean-fallback" tag to
            # the new image, leaving any previous image with that tag dangling
            # (untagged) rather than removing it — capture its ID first so it
            # can be cleaned up after, keeping just the one fallback around.
            OLD_FALLBACK_ID=$("$DOCKER" images -q "${name}:${FALLBACK_TAG}") || true

            "$DOCKER" commit "$name" "${name}:${FALLBACK_TAG}" &>/dev/null || true

            [ -n "$OLD_FALLBACK_ID" ] && "$DOCKER" rmi "$OLD_FALLBACK_ID" &>/dev/null || true
        fi
    done

    # Named volumes are deliberately left alone (no --volumes) since the goal
    # is a recoverable rollback, not a wipe; only the containers themselves
    # (already snapshotted above) are removed so Compose can create fresh
    # ones in their place.
    $DOCKER_COMPOSE --env-file "$ENV_FILE" down --remove-orphans || true

    echo "ℹ️  Old containers snapshotted as <name>:${FALLBACK_TAG} images (previous fallback per container, if any, was replaced)."
    echo "   List them:   docker images | grep clean-fallback"
    echo "   Restore one: docker run --name <name> --restart unless-stopped <original volume/network flags from docker-compose.yml> <name>:${FALLBACK_TAG}"
else
    echo "❌ Error: Unrecognized runtime policy context profile: '${POLICY}'" >&2
    exit 1
fi

# ---------------------------------------------------------------------------------------
# 5. Pipeline Layer Pulling & Detached Launch Execution
# ---------------------------------------------------------------------------------------
echo "📥 Orchestrating container deployment manifest layers..."
if [ "$POLICY" != "CLEAN" ]; then
    # CLEAN already pulled above, before teardown, to avoid the DNS
    # chicken-and-egg problem. Pulling again here would run after Pi-hole
    # is down and fail on a self-hosted-DNS Pi.
    $DOCKER_COMPOSE --env-file "$ENV_FILE" pull
fi

echo "🦅 Launching system infrastructure nodes into background space..."
$DOCKER_COMPOSE --env-file "$ENV_FILE" up -d --remove-orphans

# ---------------------------------------------------------------------------------------
# 6. Pipeline Sanity Validation & Telemetry Output
#    Delegates to info.sh so the "just deployed" summary and the on-demand
#    INFO menu are always the exact same content — one file, not two.
# ---------------------------------------------------------------------------------------
echo "=========================================================="
echo "🏁 Infrastructure Execution Pipeline Completed Successfully!"
echo "=========================================================="
bash "$SCRIPT_DIR/info.sh" list
