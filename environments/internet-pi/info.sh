#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${1:-list}"

if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a; source "$SCRIPT_DIR/.env"; set +a
fi

INSTALL_PATH="${INTERNET_PI_INSTALL_PATH:-/home/pi/internet-pi}"

DATA_DIRS=(
    "$HOME/pi-hole"
    "$HOME/internet-monitoring/grafana"
    "$HOME/internet-monitoring/prometheus"
)
DATA_DESCRIPTIONS=(
    "Pi-hole config, gravity database, custom blocklists, local DNS records"
    "Grafana dashboard definitions, data source config, user settings"
    "Prometheus time-series metrics — speedtest history, ping latency, uptime"
)
INSTALL_DIRS=(
    "$INSTALL_PATH"
)
INSTALL_DESCRIPTIONS=(
    "internet-pi repo clone + generated config.yml and inventory.ini"
)
USEFUL_COMMANDS=(
    "cd $INSTALL_PATH && ansible-playbook main.yml -i inventory.ini   # Re-run playbook"
    "cd $INSTALL_PATH && git pull && ansible-playbook main.yml -i inventory.ini  # Update + re-run"
    "docker logs -f pihole                                             # Pi-hole live logs"
    "docker logs -f grafana                                            # Grafana live logs"
    "cd ~/internet-monitoring && docker compose logs -f               # All monitoring logs"
    "docker exec -it pihole pihole setpassword                        # Change Pi-hole password"
    "docker exec -it pihole pihole -g                                 # Update gravity/blocklists"
)

# -----------------------------------------------------------------------
if [ "$ACTION" = "list" ]; then
    echo ""
    echo "📁 Persistent Data Directories (back these up):"
    for i in "${!DATA_DIRS[@]}"; do
        dir="${DATA_DIRS[$i]}"
        if [ -d "$dir" ]; then
            size=$(du -sh "$dir" 2>/dev/null | cut -f1)
            echo "   $dir  ($size)"
        else
            echo "   $dir  (not yet created)"
        fi
        echo "     → ${DATA_DESCRIPTIONS[$i]}"
    done
    echo ""
    echo "📂 Install Directories (can be re-cloned):"
    for i in "${!INSTALL_DIRS[@]}"; do
        dir="${INSTALL_DIRS[$i]}"
        if [ -d "$dir" ]; then
            size=$(du -sh "$dir" 2>/dev/null | cut -f1)
            echo "   $dir  ($size)"
        else
            echo "   $dir  (not yet created)"
        fi
        echo "     → ${INSTALL_DESCRIPTIONS[$i]}"
    done
    echo ""
    echo "💡 Useful Commands:"
    for cmd in "${USEFUL_COMMANDS[@]}"; do
        echo "   $cmd"
    done
    echo ""

elif [ "$ACTION" = "delete" ]; then
    ALL_DIRS=("${DATA_DIRS[@]}" "${INSTALL_DIRS[@]}")
    ALL_DESCS=("${DATA_DESCRIPTIONS[@]}" "${INSTALL_DESCRIPTIONS[@]}")
    echo ""
    echo "⚠️  The following directories will be PERMANENTLY DELETED:"
    echo ""
    DIRS_EXIST=false
    for i in "${!ALL_DIRS[@]}"; do
        dir="${ALL_DIRS[$i]}"
        if [ -d "$dir" ]; then
            size=$(du -sh "$dir" 2>/dev/null | cut -f1)
            echo "   🗑️  $dir  ($size)"
            echo "       → ${ALL_DESCS[$i]}"
            DIRS_EXIST=true
        else
            echo "   ⬜  $dir  (does not exist)"
        fi
    done
    echo ""
    if [ "$DIRS_EXIST" = "false" ]; then
        echo "ℹ️  No directories exist. Nothing to delete."
        exit 0
    fi
    if command -v dialog &>/dev/null; then
        dialog --clear --title " ⚠️  Delete Persistent Data " \
            --yesno "\nThis permanently deletes all listed directories.\nAll Pi-hole settings and Grafana dashboards will be lost.\n\nAre you absolutely sure?" \
            10 64
        CONFIRM=$?; clear
    else
        read -rp "Type 'yes' to confirm permanent deletion: " CONFIRM_TEXT
        [ "$CONFIRM_TEXT" = "yes" ] && CONFIRM=0 || CONFIRM=1
    fi
    if [ "$CONFIRM" -eq 0 ]; then
        for dir in "${ALL_DIRS[@]}"; do
            [ -d "$dir" ] && rm -rf "$dir" && echo "🗑️  Deleted: $dir"
        done
        echo "✅ Done."
    else
        echo "❌ Deletion cancelled."
    fi
fi
