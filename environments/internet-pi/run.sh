#!/usr/bin/env bash

# =======================================================================================
# INTERNET PI ENVIRONMENT ORCHESTRATOR (run.sh)
# Deploys Pi-hole + Prometheus + Grafana + speedtest/ping monitoring via Ansible.
# Source: https://github.com/geerlingguy/internet-pi
# =======================================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
POLICY="${REBUILD_POLICY:-FAST}"

echo "=========================================================="
echo "🌐 Internet Pi Deployment Pipeline"
echo "⚙️  Active Policy: ${POLICY}"
echo "=========================================================="

# ---------------------------------------------------------------------------------------
# 1. Source configuration
# ---------------------------------------------------------------------------------------
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "❌ Error: .env file missing. Run the TUI wizard to configure first." >&2
    exit 1
fi

INSTALL_PATH="${INTERNET_PI_INSTALL_PATH:-/home/pi/internet-pi}"
PIHOLE_ENABLE="${PIHOLE_ENABLE:-true}"
PIHOLE_TIMEZONE="${PIHOLE_TIMEZONE:-Asia/Singapore}"
PIHOLE_PASSWORD="${PIHOLE_PASSWORD:-change-this-password}"
MONITORING_ENABLE="${MONITORING_ENABLE:-true}"
MONITORING_GRAFANA_ADMIN_PASSWORD="${MONITORING_GRAFANA_ADMIN_PASSWORD:-admin}"
MONITORING_SPEEDTEST_INTERVAL="${MONITORING_SPEEDTEST_INTERVAL:-60m}"

DOCKER="${DOCKER_CMD:-docker}"
if ! $DOCKER ps &>/dev/null; then DOCKER="sudo $DOCKER"; fi

# Detect host LAN IP so post-deploy URLs are immediately clickable/copyable
HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
[ -z "$HOST_IP" ] && HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$HOST_IP" ] && HOST_IP="localhost"

# ---------------------------------------------------------------------------------------
# 2. FAST policy: if all expected containers are running, exit early
# ---------------------------------------------------------------------------------------
if [ "$POLICY" = "FAST" ]; then
    EXPECTED=()
    [ "$PIHOLE_ENABLE" = "true" ]     && EXPECTED+=(pihole)
    [ "$MONITORING_ENABLE" = "true" ] && EXPECTED+=(grafana prometheus)

    ALL_UP=true
    for name in "${EXPECTED[@]}"; do
        STATE=$($DOCKER inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo "MISSING")
        if [ "$STATE" != "true" ]; then ALL_UP=false; break; fi
    done

    if [ "$ALL_UP" = "true" ] && [ "${#EXPECTED[@]}" -gt 0 ]; then
        echo "✅ [FAST POLICY] Internet Pi containers are active."
        [ "$PIHOLE_ENABLE" = "true" ]     && echo "🌍 Pi-hole Admin:     http://${HOST_IP}/admin"
        [ "$MONITORING_ENABLE" = "true" ] && echo "📊 Grafana Dashboard: http://${HOST_IP}:3030/"
        echo "=========================================================="
        exit 0
    fi
fi

# ---------------------------------------------------------------------------------------
# 3. CLEAN policy: stop containers and wipe install directory for a fresh deploy
# ---------------------------------------------------------------------------------------
if [ "$POLICY" = "CLEAN" ]; then
    echo "🧹 [CLEAN POLICY] Stopping Internet Pi containers..."
    for name in pihole grafana prometheus ping speedtest nodeexp; do
        $DOCKER stop "$name" 2>/dev/null || true
        $DOCKER rm   "$name" 2>/dev/null || true
    done

    if [ -d "$INSTALL_PATH" ]; then
        echo "🗑️  Removing install directory: $INSTALL_PATH"
        rm -rf "$INSTALL_PATH"
    fi
    echo "✅ Clean complete. Proceeding with fresh install."
fi

# ---------------------------------------------------------------------------------------
# 4. Ensure Ansible is installed
# ---------------------------------------------------------------------------------------
if ! command -v ansible-playbook &>/dev/null; then
    echo "📦 Ansible not found. Installing..."
    if command -v pip3 &>/dev/null; then
        # --break-system-packages is required on Raspberry Pi OS Bookworm (PEP 668)
        pip3 install ansible --break-system-packages 2>/dev/null || pip3 install ansible
    elif command -v apt-get &>/dev/null; then
        sudo apt-get update && sudo apt-get install -y ansible
    else
        echo "❌ Cannot install Ansible: pip3 and apt-get not available." >&2
        exit 1
    fi
    echo "✅ Ansible installed."
fi

# ---------------------------------------------------------------------------------------
# 5. Clone or update the internet-pi repo
# ---------------------------------------------------------------------------------------
if [ ! -d "$INSTALL_PATH" ]; then
    echo "📥 Cloning geerlingguy/internet-pi to $INSTALL_PATH ..."
    git clone https://github.com/geerlingguy/internet-pi.git "$INSTALL_PATH"
    echo "✅ Clone complete."
else
    echo "📦 Pulling latest internet-pi updates..."
    git -C "$INSTALL_PATH" pull --ff-only || echo "⚠️  Git pull skipped (local changes or detached HEAD)."
fi

# ---------------------------------------------------------------------------------------
# 6. Install Ansible Galaxy collections
# ---------------------------------------------------------------------------------------
echo "🔧 Installing Ansible Galaxy collections..."
ansible-galaxy collection install -r "$INSTALL_PATH/requirements.yml" --upgrade

# ---------------------------------------------------------------------------------------
# 7. Generate config.yml from .env values
# ---------------------------------------------------------------------------------------
echo "⚙️  Writing config.yml..."
cat > "$INSTALL_PATH/config.yml" << EOF
# Generated by pi-bootstrap. Edit this file directly for advanced options
# (ping hosts, domain names, Shelly/AirGradient/Starlink integration, etc.)
# Re-deploying from pi-bootstrap will overwrite this file.
config_dir: '~'

pihole_enable: ${PIHOLE_ENABLE}
pihole_hostname: pihole
pihole_timezone: ${PIHOLE_TIMEZONE}
pihole_password: "${PIHOLE_PASSWORD}"

monitoring_enable: ${MONITORING_ENABLE}
monitoring_grafana_admin_password: "${MONITORING_GRAFANA_ADMIN_PASSWORD}"
monitoring_speedtest_interval: ${MONITORING_SPEEDTEST_INTERVAL}
monitoring_ping_interval: 5s
monitoring_ping_hosts:
  - http://www.google.com/;google.com
  - https://github.com/;github.com
  - https://www.apple.com/;apple.com

shelly_plug_enable: false
airgradient_enable: false
starlink_enable: false
EOF

# ---------------------------------------------------------------------------------------
# 8. Generate inventory.ini for local deployment on this Pi
# ---------------------------------------------------------------------------------------
CURRENT_USER="$(whoami)"
cat > "$INSTALL_PATH/inventory.ini" << EOF
[internet_pi]
127.0.0.1 ansible_connection=local ansible_user=${CURRENT_USER}
EOF

# ---------------------------------------------------------------------------------------
# 9. Run the Ansible playbook
# ---------------------------------------------------------------------------------------
echo "🚀 Running Ansible playbook (this may take a few minutes on first run)..."
cd "$INSTALL_PATH"
ansible-playbook main.yml -i inventory.ini

# ---------------------------------------------------------------------------------------
# 10. Post-deploy output
# ---------------------------------------------------------------------------------------
echo "=========================================================="
echo "🏁 Internet Pi Deployment Complete!"
echo "=========================================================="
[ "$PIHOLE_ENABLE" = "true" ]     && echo "🌍 Pi-hole Admin:     http://${HOST_IP}/admin"
[ "$MONITORING_ENABLE" = "true" ] && echo "📊 Grafana Dashboard: http://${HOST_IP}:3030/"
echo ""
echo "  🔑 Pi-hole admin password:   PIHOLE_PASSWORD from your .env"
echo "  📊 Grafana login:            admin / MONITORING_GRAFANA_ADMIN_PASSWORD from .env"
echo "  ⚡ Speedtest runs every ${MONITORING_SPEEDTEST_INTERVAL} — results visible in Grafana"
echo "  📁 Config and data:          $INSTALL_PATH"
echo ""
echo "  ↩️  To re-run with updated config (e.g. after editing .env):"
echo "     Select this environment again in the deploy menu (FAST will re-run the playbook)"
echo "  🔄 Or run manually:"
echo "     cd $INSTALL_PATH && ansible-playbook main.yml -i inventory.ini"
echo "=========================================================="
