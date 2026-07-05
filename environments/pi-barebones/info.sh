#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ACTION="${1:-list}"

VNC_DISPLAY=1
VNC_PORT="590${VNC_DISPLAY}"

# Resolve the host's LAN IP so the VNC address is actually usable from
# another device — "localhost" only means something on the Pi's own terminal.
HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
[ -z "$HOST_IP" ] && HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$HOST_IP" ] && HOST_IP="localhost"

DATA_DIRS=(); DATA_DESCRIPTIONS=()
INSTALL_DIRS=(); INSTALL_DESCRIPTIONS=()
NAMED_VOLUMES=(); NAMED_VOLUME_DESCRIPTIONS=()
NO_DATA_MSG="(none — pi-barebones only installs packages and configures .bashrc)"
NO_DELETE_MSG=$'pi-barebones has no persistent data directories to delete.\n   To undo package installations, remove them manually with:\n   sudo apt-get remove <package>'
USEFUL_COMMANDS="🖥️  TigerVNC: connect from a VNC client to ${HOST_IP}:${VNC_PORT} (display :${VNC_DISPLAY})
   Password is the one you set during setup (vncpasswd/tigervncpasswd).

   cat ${SCRIPT_DIR}/packages.txt                                   # View managed package list
   sudo apt list --installed 2>/dev/null | grep -v '^Listing'      # All installed packages
   sudo apt-get upgrade -y                                         # Upgrade all packages
   cat ~/.bashrc                                                   # View current .bashrc
   source ~/.bashrc                                                # Reload bash config
   tmux ls                                                         # List active tmux sessions
   tmux attach                                                     # Attach to most recent tmux session
   sudo systemctl restart vncserver@${VNC_DISPLAY}.service          # Restart VNC server (apply config changes)"

source "$REPO_DIR/lib/info-lib.sh"
run_info
