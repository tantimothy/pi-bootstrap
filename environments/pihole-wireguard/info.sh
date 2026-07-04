#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${1:-list}"

if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a; source "$SCRIPT_DIR/.env"; set +a
fi

: "${GRAFANA_PORT:=3030}"
: "${PIHOLE_WEB_PORT:=8080}"
export SCRIPT_DIR PIHOLE_WEB_PORT

DATA_DIRS=(
    "$SCRIPT_DIR/etc-pihole"
    "$SCRIPT_DIR/etc-wireguard"
)
DATA_DESCRIPTIONS=(
    "Pi-hole config, gravity database, custom blocklists, local DNS records"
    "WireGuard server keys + all peer configs — losing this invalidates every client VPN"
)
NAMED_VOLUMES=("prometheus_data" "grafana_data" "uptime_kuma_data")
NAMED_VOLUME_DESCRIPTIONS=(
    "Prometheus time-series metrics (peer transfer stats, Pi-hole query history)"
    "Grafana database — saved dashboards, alert rules, user preferences"
    "Uptime Kuma database — all monitors, notification channels, incident history"
)

# -----------------------------------------------------------------------
if [ "$ACTION" = "list" ]; then
    echo ""
    echo "📁 Persistent Data Directories (local):"
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
    echo "🐳 Named Docker Volumes (managed by Docker):"
    for i in "${!NAMED_VOLUMES[@]}"; do
        vol="${NAMED_VOLUMES[$i]}"
        SIZE=$(docker volume inspect "$vol" --format '{{.Mountpoint}}' 2>/dev/null \
            | xargs -I{} du -sh {} 2>/dev/null | cut -f1 || echo "unknown")
        EXISTS=$(docker volume ls -q --filter name="^${vol}$" 2>/dev/null)
        if [ -n "$EXISTS" ]; then
            echo "   docker volume: $vol  ($SIZE)"
        else
            echo "   docker volume: $vol  (not yet created)"
        fi
        echo "     → ${NAMED_VOLUME_DESCRIPTIONS[$i]}"
    done
    echo ""
    echo "💡 Useful Commands:"
    envsubst '${SCRIPT_DIR} ${PIHOLE_WEB_PORT}' < "$SCRIPT_DIR/useful-commands.txt"
    echo ""
    echo "📊 Backup named volumes:"
    echo "   docker run --rm -v prometheus_data:/data -v \$(pwd):/backup alpine tar czf /backup/prometheus_data.tar.gz /data"
    echo "   docker run --rm -v grafana_data:/data -v \$(pwd):/backup alpine tar czf /backup/grafana_data.tar.gz /data"
    echo ""

elif [ "$ACTION" = "delete" ]; then
    echo ""
    echo "⚠️  The following directories will be PERMANENTLY DELETED:"
    echo ""
    DIRS_EXIST=false
    for i in "${!DATA_DIRS[@]}"; do
        dir="${DATA_DIRS[$i]}"
        if [ -d "$dir" ]; then
            size=$(du -sh "$dir" 2>/dev/null | cut -f1)
            echo "   🗑️  $dir  ($size)"
            echo "       → ${DATA_DESCRIPTIONS[$i]}"
            DIRS_EXIST=true
        else
            echo "   ⬜  $dir  (does not exist)"
        fi
    done
    echo ""
    echo "   Named Docker volumes will also be removed:"
    for vol in "${NAMED_VOLUMES[@]}"; do
        EXISTS=$(docker volume ls -q --filter name="^${vol}$" 2>/dev/null)
        if [ -n "$EXISTS" ]; then
            echo "   🗑️  docker volume: $vol"
            DIRS_EXIST=true
        else
            echo "   ⬜  docker volume: $vol  (does not exist)"
        fi
    done
    echo ""
    if [ "$DIRS_EXIST" = "false" ]; then
        echo "ℹ️  No data directories or volumes exist. Nothing to delete."
        exit 0
    fi
    if command -v dialog &>/dev/null; then
        dialog --clear --title " ⚠️  Delete Persistent Data " \
            --yesno "\nThis permanently deletes all listed directories and Docker volumes.\nWireGuard peer configs will be unrecoverable.\n\nAre you absolutely sure?" \
            11 62
        CONFIRM=$?; clear
    else
        read -rp "Type 'yes' to confirm permanent deletion: " CONFIRM_TEXT
        [ "$CONFIRM_TEXT" = "yes" ] && CONFIRM=0 || CONFIRM=1
    fi
    if [ "$CONFIRM" -eq 0 ]; then
        for dir in "${DATA_DIRS[@]}"; do
            [ -d "$dir" ] && rm -rf "$dir" && echo "🗑️  Deleted: $dir"
        done
        for vol in "${NAMED_VOLUMES[@]}"; do
            EXISTS=$(docker volume ls -q --filter name="^${vol}$" 2>/dev/null)
            [ -n "$EXISTS" ] && docker volume rm "$vol" && echo "🗑️  Deleted volume: $vol"
        done
        echo "✅ Done."
    else
        echo "❌ Deletion cancelled."
    fi
fi
