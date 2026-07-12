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
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
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
    # Best-effort — immediately removes now-stale desktop entries rather than
    # leaving them until the next manual install-desktop-entries.sh run.
    bash "$REPO_DIR/lib/run-install-desktop.sh" "$SCRIPT_DIR" >/dev/null 2>&1 || true
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

# CONTAINER_NAME is substituted directly into docker-compose.yml's
# container_name fields — a value Docker's naming rules reject (spaces,
# etc.) would otherwise surface as a cryptic "Invalid container name"
# error mid-recreate instead of a clear one here. This also catches the
# old pre-single-value CONTAINER_NAME format (a space-separated list of
# every container in the stack) left over in a .env from before this
# variable was actually read by docker-compose.yml.
if [ -n "${CONTAINER_NAME:-}" ] && ! [[ "$CONTAINER_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
    echo "❌ Error: CONTAINER_NAME='${CONTAINER_NAME}' in .env is not a valid container name." >&2
    echo "   Docker container names may only contain [a-zA-Z0-9_.-], and must start with an alphanumeric." >&2
    echo "   Set it to a single name (e.g. CONTAINER_NAME=pihole) or remove the line to use the default." >&2
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
: "${DOZZLE_PORT:=8888}"

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
# Pre-created here (rather than left for Docker to auto-create as a
# bind-mount target) specifically so it's owned by whoever is running this
# script, not by whatever internal UID the container happens to write as —
# Docker only auto-creates a missing bind-mount source as root, and never
# retroactively re-owns an already-existing directory.
mkdir -p "${SCRIPT_DIR}/netalertx-data"
echo "✅ Local host storage layout initialized cleanly."

# ---------------------------------------------------------------------------------------
# 3a. Host Network Interface Configuration (optional — only if NETWORK_STATIC_IPS
#     is set in .env). Patches ONLY the addressing/gateway/nameservers fields of
#     whichever interfaces are named — everything else already in each
#     interface's existing netplan file (WiFi SSID/password, NetworkManager
#     UUIDs, etc.) is left completely untouched.
#
#     Two independent safety layers, since this touches live network config:
#     (1) nothing is written to /etc/netplan at all until you explicitly
#         confirm the exact changes shown — default is NO if you just press
#         Enter — and (2) even after confirming, it's applied via
#         `netplan try`, which auto-reverts within ~120s unless separately
#         confirmed again, so a config that looks fine but doesn't actually
#         work still can't lock you out of SSH permanently.
#
#     Idempotent: if nothing needs to change, this is a silent no-op — no
#     prompt, nothing to confirm, on every routine redeploy.
# ---------------------------------------------------------------------------------------
if [ -n "${NETWORK_STATIC_IPS:-}" ]; then
    echo "🔧 Checking host network interface configuration..."
    if [ -z "${NETWORK_GATEWAY:-}" ]; then
        echo "⚠️  NETWORK_STATIC_IPS is set but NETWORK_GATEWAY is empty — skipping network interface configuration." >&2
    else
        python3 -c "import yaml" 2>/dev/null || sudo apt-get install -y python3-yaml > /dev/null 2>&1

        NETPLAN_STAGING="$(mktemp -d)"
        sudo python3 - "$NETWORK_GATEWAY" "$NETWORK_STATIC_IPS" "$NETPLAN_STAGING" << 'PYEOF'
import sys, glob, os, yaml

gateway = sys.argv[1]
# "eth0:192.168.1.75 wlan0:" -> {"eth0": "192.168.1.75", "wlan0": ""}
# An empty IP means: put that interface on DHCP instead of static.
pairs = dict(p.split(":", 1) for p in sys.argv[2].split() if ":" in p)
staging = sys.argv[3]

changed = False
for path in sorted(glob.glob("/etc/netplan/*.yaml") + glob.glob("/etc/netplan/*.yml")):
    try:
        with open(path) as f:
            data = yaml.safe_load(f) or {}
    except Exception:
        continue

    network = data.get("network") or {}
    file_modified = False
    for section in ("ethernets", "wifis"):
        for iface, cfg in (network.get(section) or {}).items():
            if iface not in pairs or cfg is None:
                continue
            ip = pairs[iface]
            if ip:
                # Preserve an existing default route's metric if there is
                # one, so re-running this doesn't reshuffle route priority.
                existing_metric = None
                for r in (cfg.get("routes") or []):
                    if r.get("to") in ("0.0.0.0/0", "default"):
                        existing_metric = r.get("metric")
                metric = existing_metric if existing_metric is not None else (100 if section == "ethernets" else 600)
                new_cfg = {
                    "dhcp4": False,
                    "addresses": [f"{ip}/24"],
                    "routes": [{"to": "0.0.0.0/0", "via": gateway, "metric": metric}],
                    "nameservers": {"addresses": ["127.0.0.1", gateway]},
                }
                summary = f"static {ip}/24, gateway {gateway}, DNS [127.0.0.1, {gateway}]"
            else:
                new_cfg = {"dhcp4": True}
                summary = "DHCP"

            if {k: cfg.get(k) for k in new_cfg} != new_cfg:
                cfg.update(new_cfg)
                for stale_key in ("addresses", "routes", "nameservers"):
                    if stale_key not in new_cfg:
                        cfg.pop(stale_key, None)
                file_modified = True
                changed = True
                print(f"   {iface} ({os.path.basename(path)}): {summary}")

    if file_modified:
        staged_path = os.path.join(staging, os.path.basename(path))
        with open(staged_path, "w") as f:
            yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)
        with open(staged_path + ".origpath", "w") as f:
            f.write(path)

with open(os.path.join(staging, ".result"), "w") as f:
    f.write("CHANGED" if changed else "UNCHANGED")
PYEOF

        NETPLAN_RESULT=$(sudo cat "$NETPLAN_STAGING/.result" 2>/dev/null || echo "UNCHANGED")

        if [ "$NETPLAN_RESULT" = "CHANGED" ]; then
            echo ""
            read -rp "Apply the network changes shown above? [y/N] " NETPLAN_CONFIRM
            if [ "$NETPLAN_CONFIRM" = "y" ] || [ "$NETPLAN_CONFIRM" = "Y" ]; then
                for staged in "$NETPLAN_STAGING"/*.yaml "$NETPLAN_STAGING"/*.yml; do
                    [ -e "$staged" ] || continue
                    ORIG_PATH=$(sudo cat "${staged}.origpath" 2>/dev/null)
                    [ -n "$ORIG_PATH" ] && sudo cp "$staged" "$ORIG_PATH"
                done
                echo "🔄 Applying network config via 'netplan try' (auto-reverts in ~120s unless confirmed)..."
                sudo netplan try --timeout 120
            else
                echo "❌ Network configuration changes skipped (default: no)."
            fi
        else
            echo "✅ Network interfaces already match the desired configuration."
        fi
        sudo rm -rf "$NETPLAN_STAGING"
    fi
fi

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
# 3b-2. NetAlertX ARP-flux mitigation. NetAlertX also runs with
#       network_mode: host, and its upstream compose file recommends these
#       two sysctls for accurate ARP scanning — but Docker/runc reject
#       per-container `sysctls:` entries entirely under host networking
#       ("not allowed in host network namespace", since there's no network
#       namespace of its own to scope them to), so they have to be set on
#       the host directly instead. Idempotent — safe to re-run.
# ---------------------------------------------------------------------------------------
sudo tee /etc/sysctl.d/netalertx.conf > /dev/null << 'EOF'
net.ipv4.conf.all.arp_ignore=1
net.ipv4.conf.all.arp_announce=2
EOF
sudo sysctl -w net.ipv4.conf.all.arp_ignore=1 > /dev/null
sudo sysctl -w net.ipv4.conf.all.arp_announce=2 > /dev/null

# ---------------------------------------------------------------------------------------
# 3c. Host DNS Resilience — since this Pi is its own DNS resolver, two
#     separate failure modes need covering: (1) the host's own resolver
#     needs a working fallback for whenever Pi-hole itself is down (crash,
#     TEARDOWN, mid-CLEAN), and (2) Docker's per-container DNS forwarding
#     needs to be stable rather than re-derived (unreliably) on every
#     container creation. Both blocks are idempotent — safe to re-run.
# ---------------------------------------------------------------------------------------
echo "🔧 Configuring host DNS resilience..."

# (1) Debian's resolvconf silently drops any nameserver listed after the
# first loopback address (127.*) when regenerating /etc/resolv.conf — so
# even if netplan lists a fallback nameserver (e.g. your router) after
# 127.0.0.1, it never actually reaches /etc/resolv.conf, and the whole host
# loses DNS the moment Pi-hole goes down. Disabling this restores the
# fallback without changing which nameserver is tried first.
if command -v resolvconf &>/dev/null; then
    if ! grep -qs "TRUNCATE_NAMESERVER_LIST_AFTER_LOOPBACK_ADDRESS=no" /etc/default/resolvconf 2>/dev/null; then
        echo "   Disabling resolvconf's nameserver truncation after loopback addresses..."
        echo 'TRUNCATE_NAMESERVER_LIST_AFTER_LOOPBACK_ADDRESS=no' | sudo tee -a /etc/default/resolvconf > /dev/null
        sudo resolvconf -u 2>/dev/null || true
    fi
fi

# (2) Docker computes a per-container DNS-forwarding target once, at
# container-creation time, by inspecting the host's network state. On a
# host with more than one active interface (e.g. both eth0 and wlan0 up
# simultaneously), that detection is unreliable — it can succeed once and
# then fail entirely on a later recreate ("NO EXTERNAL NAMESERVERS
# DEFINED"), breaking every container's external DNS resolution.
#
# Rather than hardcoding a specific IP (pinning to Pi-hole's own address
# would make every container on the host depend on Pi-hole's uptime for
# DNS — including during this very stack's own routine CLEAN redeploys,
# which tear Pi-hole down briefly), this discovers whatever DNS server the
# network's DHCP server is actually advertising right now, via a one-off,
# non-disruptive DHCP discovery probe (nmap's broadcast-dhcp-discover sends
# a DHCPDISCOVER and reads the OFFER; it never completes a DHCPREQUEST, so
# it doesn't touch this host's own — statically configured — addressing).
# That's normally the router itself, but this way it's whatever the
# network's actual DHCP server says, not a guess baked into this script.
#
# Only acts if /etc/docker/daemon.json doesn't exist yet, so it never
# clobbers an existing custom config — if you already have one without a
# "dns" key, add one yourself and restart Docker. This also means the
# one-time `systemctl restart docker` this triggers (which restarts EVERY
# container on the host, not just this stack) only ever happens on a
# genuinely fresh setup.
if [ ! -f /etc/docker/daemon.json ]; then
    PRIMARY_IFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    DHCP_DNS=""
    if [ -n "$PRIMARY_IFACE" ]; then
        command -v nmap &>/dev/null || sudo apt-get install -y nmap > /dev/null 2>&1
        DHCP_DNS=$(sudo nmap --script broadcast-dhcp-discover -e "$PRIMARY_IFACE" 2>/dev/null \
            | grep "Domain Name Server:" | head -1 | awk -F': ' '{print $2}' | awk -F',' '{print $1}' | tr -d ' \r')
    fi

    if [ -n "$DHCP_DNS" ]; then
        echo "   Setting Docker daemon-level DNS to ${DHCP_DNS} (discovered via DHCP on ${PRIMARY_IFACE})..."
        sudo mkdir -p /etc/docker
        sudo tee /etc/docker/daemon.json > /dev/null << EOF
{
  "dns": ["${DHCP_DNS}"]
}
EOF
        echo "   🔄 Restarting Docker to apply it (restarts every container on this host)..."
        sudo systemctl restart docker
        # Wait for the daemon to actually accept connections again rather
        # than a blind sleep — "restart" returning doesn't guarantee the
        # API is ready yet.
        for _ in $(seq 1 30); do
            "$DOCKER" ps &>/dev/null && break
            sleep 1
        done
    else
        echo "   ⚠️  Could not discover a DHCP-provided DNS server — skipping the Docker daemon DNS pin. If containers hit DNS instability later, configure /etc/docker/daemon.json manually."
    fi
fi

echo "✅ Host DNS resilience configured."

# ---------------------------------------------------------------------------------------
# 3d. Grafana / Prometheus monitoring setup
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
CONTAINER_NAMES=(
    "${CONTAINER_NAME:-pihole}"
    "${CONTAINER_NAME:+${CONTAINER_NAME}-}wg-easy"
    "${CONTAINER_NAME:+${CONTAINER_NAME}-}pihole-exporter"
    "${CONTAINER_NAME:+${CONTAINER_NAME}-}wireguard-exporter"
    "${CONTAINER_NAME:+${CONTAINER_NAME}-}prometheus"
    "${CONTAINER_NAME:+${CONTAINER_NAME}-}grafana"
    "${CONTAINER_NAME:+${CONTAINER_NAME}-}uptime-kuma"
    "${CONTAINER_NAME:+${CONTAINER_NAME}-}node-exporter"
    "${CONTAINER_NAME:+${CONTAINER_NAME}-}speedtest-exporter"
    "${CONTAINER_NAME:+${CONTAINER_NAME}-}blackbox-exporter"
    "${CONTAINER_NAME:+${CONTAINER_NAME}-}darkstat"
    "${CONTAINER_NAME:+${CONTAINER_NAME}-}netalertx"
    "${CONTAINER_NAME:+${CONTAINER_NAME}-}dozzle"
)
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
        echo "🔎 Reconciling against docker-compose.yml (no image pull) in case it changed..."
        # `docker compose up -d` only recreates containers whose config
        # actually changed (e.g. a healthcheck/env/volume edit) and no-ops
        # instantly for the rest — this is what lets a compose-only change
        # take effect on a plain FAST run without needing the heavier CLEAN
        # policy's image pull, or a manual `docker compose up -d`.
        $DOCKER_COMPOSE --env-file "$ENV_FILE" up -d --remove-orphans
        # Best-effort — picks up any .env change (e.g. a changed port) even
        # on this no-op-ish reconcile path.
        bash "$REPO_DIR/lib/run-install-desktop.sh" "$SCRIPT_DIR" >/dev/null 2>&1 || true
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

# Reached by both a real FAST deploy and CLEAN — either path can leave the
# previous image dangling once `up` retags `:latest` onto a newer pull.
# -f only removes untagged/dangling images, never anything still referenced
# by a container (including the CLEAN fallback snapshots committed above,
# which carry their own tag and are never "dangling").
"$DOCKER" image prune -f >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------------------
# 6. Pipeline Sanity Validation & Telemetry Output
#    Delegates to info.sh so the "just deployed" summary and the on-demand
#    INFO menu are always the exact same content — one file, not two.
# ---------------------------------------------------------------------------------------
echo "=========================================================="
echo "🏁 Infrastructure Execution Pipeline Completed Successfully!"
echo "=========================================================="
bash "$REPO_DIR/lib/run-install-desktop.sh" "$SCRIPT_DIR" >/dev/null 2>&1 || true
bash "$REPO_DIR/lib/run-info.sh" "$SCRIPT_DIR" list
