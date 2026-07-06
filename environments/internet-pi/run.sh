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
    echo "❌ Error: .env file missing." >&2
    echo "   Copy .env.example to .env and fill in the values, then re-run." >&2
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

# pip3 installs ansible-playbook/ansible-galaxy to ~/.local/bin which is not
# always in PATH inside non-interactive scripts — add it explicitly.
export PATH="$HOME/.local/bin:$PATH"

# Detect host LAN IP so post-deploy URLs are immediately clickable/copyable
HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
[ -z "$HOST_IP" ] && HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$HOST_IP" ] && HOST_IP="localhost"

# ---------------------------------------------------------------------------------------
# 2. STOP / TEARDOWN — handle before anything else so no deploy logic runs
# ---------------------------------------------------------------------------------------
ALL_CONTAINERS=(pihole grafana prometheus ping speedtest nodeexp)

if [ "$POLICY" = "STOP" ]; then
    echo "🛑 [STOP] Pausing Internet Pi containers (preserved for FAST resume)..."
    for name in "${ALL_CONTAINERS[@]}"; do
        $DOCKER stop "$name" 2>/dev/null || true
    done
    echo "✅ Containers paused."
    exit 0
fi

if [ "$POLICY" = "TEARDOWN" ]; then
    echo "🗑️  [TEARDOWN] Stopping and removing Internet Pi containers..."
    for name in "${ALL_CONTAINERS[@]}"; do
        $DOCKER stop "$name" 2>/dev/null || true
        $DOCKER rm   "$name" 2>/dev/null || true
    done
    echo "✅ Containers removed."
    exit 0
fi

# ---------------------------------------------------------------------------------------
# 3. FAST policy: report current state, but always reconcile via Ansible below
# ---------------------------------------------------------------------------------------
# Deliberately does NOT exit early even when everything's already up — Ansible
# is idempotent (it only touches what's actually drifted), so falling through
# to re-run the playbook is what lets a config.yml-affecting .env change (or
# an internet-pi upstream update) take effect on a plain FAST run, instead of
# requiring CLEAN.
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
        echo "✅ [FAST POLICY] Internet Pi containers are active — reconciling via Ansible (idempotent, no forced re-pull)..."
    else
        echo "🛠️  [FAST POLICY] One or more containers missing or stopped — deploying..."
    fi
fi

# ---------------------------------------------------------------------------------------
# 3. CLEAN policy: wipe install directory for a fresh clone
# ---------------------------------------------------------------------------------------
# Containers are deliberately NOT stopped here — if PIHOLE_ENABLE=true, Pi-hole
# may be this host's own DNS resolver, and the steps below (git clone/pull,
# ansible-galaxy collection install) need working DNS. Tearing it down first
# would leave the host unable to resolve github.com/galaxy.ansible.com at all.
# The actual container teardown is deferred to just before the Ansible
# playbook run (step 9), which is what recreates them anyway.
if [ "$POLICY" = "CLEAN" ] && [ -d "$INSTALL_PATH" ]; then
    echo "🧹 [CLEAN POLICY] Removing install directory for a fresh clone: $INSTALL_PATH"
    rm -rf "$INSTALL_PATH"
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
# CLEAN's container teardown happens here — right before the playbook
# recreates everything — rather than at step 3, so Pi-hole (if it's this
# host's own DNS resolver) stays up through every network-dependent step
# above (git clone/pull, ansible-galaxy install).
if [ "$POLICY" = "CLEAN" ]; then
    echo "🧹 [CLEAN POLICY] Stopping Internet Pi containers..."
    for name in pihole grafana prometheus ping speedtest nodeexp; do
        $DOCKER stop "$name" 2>/dev/null || true
        $DOCKER rm   "$name" 2>/dev/null || true
    done
fi

echo "🚀 Running Ansible playbook (this may take a few minutes on first run)..."
cd "$INSTALL_PATH"

# The playbook uses 'become: true' (sudo). Check if passwordless sudo is available;
# if not, rebind stdin to the terminal and pass -K so Ansible can prompt for the
# sudo password interactively.
ANSIBLE_EXTRA_FLAGS=""
if ! sudo -n true 2>/dev/null; then
    echo "⚠️  sudo requires a password on this system."
    echo "   Ansible will prompt for it now (this is your sudo/system password)."
    exec 0< /dev/tty
    ANSIBLE_EXTRA_FLAGS="-K"
fi

ansible-playbook main.yml -i inventory.ini $ANSIBLE_EXTRA_FLAGS

# ---------------------------------------------------------------------------------------
# 10. Post-deploy output
#     Delegates to info.sh so the "just deployed" summary and the on-demand
#     INFO menu are always the exact same content — one file, not two.
# ---------------------------------------------------------------------------------------
echo "=========================================================="
echo "🏁 Internet Pi Deployment Complete!"
echo "=========================================================="
bash "$SCRIPT_DIR/info.sh" list
