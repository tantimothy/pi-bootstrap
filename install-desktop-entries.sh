#!/usr/bin/env bash
# install-desktop-entries.sh
# Registers pi-bootstrap environments as XDG desktop entries.
# Run once after initial deploy; re-run any time to update port numbers.
#
# Usage:
#   ./install-desktop-entries.sh            # install
#   ./install-desktop-entries.sh --uninstall # remove all pi-bootstrap entries

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="${HOME}/.local/share/applications"

# ── Uninstall ──────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--uninstall" ]; then
    removed=$(rm -fv "$APPS_DIR"/pi-bootstrap-*.desktop "$APPS_DIR/pi-bootstrap.desktop" 2>/dev/null | wc -l)
    echo "Removed $removed desktop entries."
    exit 0
fi

mkdir -p "$APPS_DIR"

# Read a value from a .env file, with a fallback default.
env_val() {
    local file="$1" key="$2" default="$3"
    if [ -f "$file" ]; then
        local val
        val=$(grep "^${key}=" "$file" 2>/dev/null | cut -d= -f2 | tr -d "\"'" | head -1)
        echo "${val:-$default}"
    else
        echo "$default"
    fi
}

write_entry() {
    local name="$1"; shift
    cat > "$APPS_DIR/${name}.desktop"
    echo "  ✓  ${name}"
}

echo "Installing pi-bootstrap desktop entries to $APPS_DIR..."
echo ""

# ── Pi Bootstrap — main dashboard ─────────────────────────────────────────────
write_entry "pi-bootstrap" << EOF
[Desktop Entry]
Name=Pi Bootstrap
Comment=Raspberry Pi Docker environment launcher
Exec=bash -c "cd '$SCRIPT_DIR' && ./deploy.sh"
Icon=utilities-terminal
Type=Application
Categories=System;
Terminal=true
EOF

# ── DragonOS SDR — X11 GUI apps ───────────────────────────────────────────────
# X11 GUI apps (GQRX, GNU Radio) render directly onto the host display.
# The image must be built first: run the dragonos-sdr environment once via deploy.sh.
#
# DISPLAY=:0 is correct for a directly-connected Pi desktop session.
# If you run this over SSH with X forwarding, replace :0 with your $DISPLAY value.

SDR_ENV="$SCRIPT_DIR/environments/dragonos-sdr/.env"
SDR_IMAGE=$(env_val "$SDR_ENV" "DOCKER_IMAGE_TAG" "dragonos-pi")
SDR_CONTAINER=$(env_val "$SDR_ENV" "CONTAINER_NAME" "sdr-dragonos-core")
X11_FLAGS="--rm -e DISPLAY=:0 -v /tmp/.X11-unix:/tmp/.X11-unix --device /dev/bus/usb"

write_entry "pi-bootstrap-gqrx" << EOF
[Desktop Entry]
Name=GQRX
Comment=Software Defined Radio receiver — spectrum waterfall, FM/AM/SSB/CW
Exec=bash -c "xhost +local: >/dev/null 2>&1; docker run $X11_FLAGS $SDR_IMAGE gqrx"
Icon=gqrx
Type=Application
Categories=HamRadio;Science;
Terminal=false
EOF

write_entry "pi-bootstrap-gnuradio" << EOF
[Desktop Entry]
Name=GNU Radio Companion
Comment=Visual signal processing flowgraph editor
Exec=bash -c "xhost +local: >/dev/null 2>&1; docker run $X11_FLAGS $SDR_IMAGE gnuradio-companion"
Icon=gnuradio-grc
Type=Application
Categories=HamRadio;Science;
Terminal=false
EOF

# TUI tool menu — attaches to a running container or launches a fresh one
write_entry "pi-bootstrap-sdr-menu" << EOF
[Desktop Entry]
Name=SDR Tools Menu
Comment=Interactive SDR launcher — rtl_fm, dump1090, hackrf, APRS, ACARS and more
Exec=bash -c "docker exec -it $SDR_CONTAINER /usr/local/bin/sdr-menu.sh 2>/dev/null || docker run -it --rm --device /dev/bus/usb $SDR_IMAGE"
Icon=utilities-terminal
Type=Application
Categories=HamRadio;Science;
Terminal=true
EOF

# ── Pi-hole + WireGuard — web UIs via xdg-open ────────────────────────────────
# Reads live port values from .env so URLs stay correct after reconfiguration.

PW_ENV="$SCRIPT_DIR/environments/pihole-wireguard/.env"
PIHOLE_PORT=$(env_val "$PW_ENV" "PIHOLE_WEB_PORT"  "8080")
GRAFANA_PORT=$(env_val "$PW_ENV" "GRAFANA_PORT"    "3030")
UPTIME_PORT=$(env_val "$PW_ENV"  "UPTIME_KUMA_PORT" "3001")
WG_PORT=$(env_val "$PW_ENV"      "WG_UI_PORT"      "51821")

write_entry "pi-bootstrap-pihole" << EOF
[Desktop Entry]
Name=Pi-hole Admin
Comment=DNS ad-blocker — blocklist management, query log, client stats
Exec=xdg-open http://localhost:$PIHOLE_PORT/admin
Icon=network-server
Type=Application
Categories=Network;System;
Terminal=false
EOF

write_entry "pi-bootstrap-grafana" << EOF
[Desktop Entry]
Name=Grafana (Pi Network)
Comment=Monitoring dashboards — Pi-hole, WireGuard peers, node metrics, speedtest
Exec=xdg-open http://localhost:$GRAFANA_PORT
Icon=utilities-system-monitor
Type=Application
Categories=Network;System;
Terminal=false
EOF

write_entry "pi-bootstrap-uptime-kuma" << EOF
[Desktop Entry]
Name=Uptime Kuma
Comment=Service uptime and health monitoring
Exec=xdg-open http://localhost:$UPTIME_PORT
Icon=network-server
Type=Application
Categories=Network;System;
Terminal=false
EOF

write_entry "pi-bootstrap-wireguard" << EOF
[Desktop Entry]
Name=WireGuard VPN Dashboard
Comment=WireGuard peer management — add/remove clients, view connection status
Exec=xdg-open http://localhost:$WG_PORT
Icon=network-vpn
Type=Application
Categories=Network;
Terminal=false
EOF

# ── Kali Pentest ──────────────────────────────────────────────────────────────
write_entry "pi-bootstrap-kali" << EOF
[Desktop Entry]
Name=Kali Pentest Terminal
Comment=Kali Linux environment — wireless attacks, Metasploit, wardriving, MITM
Exec=bash -c "cd '$SCRIPT_DIR/environments/kali-pentest' && REBUILD_POLICY=FAST ./run.sh"
Icon=utilities-terminal
Type=Application
Categories=Security;Network;
Terminal=true
EOF

# ── NanoClaw AI ───────────────────────────────────────────────────────────────
write_entry "pi-bootstrap-nanoclaw" << EOF
[Desktop Entry]
Name=NanoClaw AI
Comment=Local AI tools — Ollama model inference, Whisper speech-to-text
Exec=bash -c "cd '$SCRIPT_DIR/environments/nanoclaw' && REBUILD_POLICY=FAST ./run.sh"
Icon=utilities-terminal
Type=Application
Categories=Science;
Terminal=true
EOF

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "✅  $(ls "$APPS_DIR"/pi-bootstrap*.desktop | wc -l) entries installed."
echo ""
echo "Refresh your desktop application menu:"
echo "  Raspberry Pi OS (LXDE):  right-click desktop → Refresh"
echo "  XFCE:                    xfce4-panel --restart"
echo "  GNOME:                   Alt+F2 → r  (or log out/in)"
echo ""
echo "To uninstall all entries:"
echo "  $0 --uninstall"
echo ""
echo "Notes:"
echo "  • GQRX and GNU Radio Companion require the dragonos-sdr image to be"
echo "    built first. Run it once via deploy.sh to build it."
echo "  • Web UI entries (Pi-hole, Grafana, etc.) only work while those"
echo "    containers are running."
echo "  • DISPLAY=:0 is assumed (standard for Pi desktop). Change the entries"
echo "    in $APPS_DIR if your display number differs."
