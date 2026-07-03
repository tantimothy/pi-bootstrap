#!/bin/bash

# --- CONFIGURATION ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_FILE="$SCRIPT_DIR/packages.txt"
TMUX_SOURCE="$SCRIPT_DIR/.tmux.conf"
BASHRC="$HOME/.bashrc"

# Unique block markers for idempotency inside .bashrc
MARKER_START="# >>> PI INITIAL SETUP START >>>"
MARKER_END="# <<< PI INITIAL SETUP END <<<"

echo "🔄 Starting Raspberry Pi first-time initialization..."

# --- STEP 1: DEPLOY TMUX CONFIGURATION ---
if [ -f "$TMUX_SOURCE" ]; then
    echo "📋 Copying .tmux.conf to $HOME..."
    cp "$TMUX_SOURCE" "$HOME/.tmux.conf"
else
    echo "⚠️ Warning: No .tmux.conf found in $SCRIPT_DIR. Skipping copy."
fi

# --- STEP 2: INSTALL SYSTEM PACKAGES ---
if [ -f "$PACKAGE_FILE" ]; then
    echo "📦 Reading package list from $PACKAGE_FILE..."
    
    # Read packages while ignoring empty lines and comments
    PACKAGES=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Strip trailing carriage returns if file was saved on Windows
        line=$(echo "$line" | tr -d '\r' | xargs)
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        PACKAGES+=("$line")
    done < "$PACKAGE_FILE"

    if [ ${#PACKAGES[@]} -gt 0 ]; then
        echo "📡 Updating package repository index..."
        sudo apt-get update -y
        
        echo "🛠️ Installing packages: ${PACKAGES[*]}..."
        sudo apt-get install -y "${PACKAGES[@]}"
    else
        echo "ℹ️ No packages found to install inside $PACKAGE_FILE."
    fi
else
    echo "❌ Error: $PACKAGE_FILE not found! Cannot manage package installations."
    exit 1
fi

# --- STEP 3: IDEMPOTENTLY INJECT LINES TO .BASHRC ---
echo "✏️ Updating $BASHRC with initialization blocks..."

# Ensure .bashrc exists
touch "$BASHRC"

# Clean out any older versions of our setup block if the script was run previously
# This logic deletes everything strictly between the START and END markers inclusive.
if grep -qF "$MARKER_START" "$BASHRC"; then
    echo "🧹 Cleaned old configurations from .bashrc to enforce idempotency."
    sed -i "/$MARKER_START/,/$MARKER_END/d" "$BASHRC"
fi

# Append the fresh block exactly once
cat << 'EOF' >> "$BASHRC"
# >>> PI INITIAL SETUP START >>>

# Ensure we dynamically attach or spawn a reusable tmux session
tmux new-session -A

# Execute PADD dashboard utility if it exists in home directory
cd ~
if [ -f ./padd.sh ]; then
    ./padd.sh
fi

# Fallback wrapper to trigger system telemetry fastfetch safely
cd ~
if [ -f /usr/bin/fastfetch ]; then 
    fastfetch
fi

# <<< PI INITIAL SETUP END <<<
EOF

echo "✅ Shell setup complete."

# --- STEP 4: TIGERVNC SERVER ---
echo ""
echo "🖥️  Setting up TigerVNC..."

# Detect the target user — prefer the user who invoked sudo, fall back to $USER
VNC_USER="${SUDO_USER:-$USER}"
VNC_HOME=$(eval echo "~$VNC_USER")
VNC_DISPLAY=1
VNC_GEOMETRY="1920x1080"
VNC_DEPTH=24

# 4a. Install packages (idempotent)
sudo apt-get install -y tigervnc-standalone-server tigervnc-common

# 4b. Resolve the password utility binary.
#     Debian 13 (Trixie) splits it into tigervnc-tools as 'tigervncpasswd';
#     Raspberry Pi OS / Debian 11-12 ship it as 'vncpasswd'.
VNCPASSWD_BIN=""
if command -v vncpasswd &>/dev/null; then
    VNCPASSWD_BIN="vncpasswd"
elif command -v tigervncpasswd &>/dev/null; then
    VNCPASSWD_BIN="tigervncpasswd"
else
    echo "📦 vncpasswd not found — installing tigervnc-tools..."
    sudo apt-get install -y tigervnc-tools
    if command -v tigervncpasswd &>/dev/null; then
        VNCPASSWD_BIN="tigervncpasswd"
    elif command -v vncpasswd &>/dev/null; then
        VNCPASSWD_BIN="vncpasswd"
    else
        echo "❌ Could not locate a VNC password utility. Skipping password step." >&2
    fi
fi

# Create a normalising symlink so 'vncpasswd' always works going forward
if [ "$VNCPASSWD_BIN" = "tigervncpasswd" ] && ! command -v vncpasswd &>/dev/null; then
    sudo ln -sf "$(command -v tigervncpasswd)" /usr/local/bin/vncpasswd
    echo "🔗 Symlinked tigervncpasswd → /usr/local/bin/vncpasswd"
fi

# 4c. Set VNC password — only prompt if no password file exists yet
PASSWD_FILE="$VNC_HOME/.config/tigervnc/passwd"
LEGACY_PASSWD="$VNC_HOME/.vnc/passwd"
if [ -n "$VNCPASSWD_BIN" ] && [ ! -f "$PASSWD_FILE" ] && [ ! -f "$LEGACY_PASSWD" ]; then
    echo ""
    echo "🔐 Set a VNC access password (6–8 characters). Select 'n' when asked for a view-only password."
    sudo -u "$VNC_USER" "$VNCPASSWD_BIN"
fi

# 4d. Copy passwd to the modern TigerVNC location
sudo -u "$VNC_USER" mkdir -p "$VNC_HOME/.config/tigervnc"
if [ -f "$LEGACY_PASSWD" ] && [ ! -f "$PASSWD_FILE" ]; then
    sudo cp "$LEGACY_PASSWD" "$PASSWD_FILE"
    sudo chown "$VNC_USER:$VNC_USER" "$PASSWD_FILE"
fi

# 4e. Write ~/.vnc/config (overwrite to ensure settings are always current)
sudo -u "$VNC_USER" mkdir -p "$VNC_HOME/.vnc"
sudo tee "$VNC_HOME/.vnc/config" > /dev/null << EOF
session=lightdm-xsession
geometry=${VNC_GEOMETRY}
depth=${VNC_DEPTH}
localhost=0
EOF
sudo chown "$VNC_USER:$VNC_USER" "$VNC_HOME/.vnc/config"

# 4f. Map display :1 to this user (idempotent)
sudo mkdir -p /etc/tigervnc
if ! sudo grep -qsF ":${VNC_DISPLAY}=${VNC_USER}" /etc/tigervnc/vncserver.users 2>/dev/null; then
    echo ":${VNC_DISPLAY}=${VNC_USER}" | sudo tee -a /etc/tigervnc/vncserver.users > /dev/null
fi

# 4g. Write systemd service file
sudo tee /etc/systemd/system/vncserver@.service > /dev/null << EOF
[Unit]
Description=Remote desktop service (VNC)
After=syslog.target network.target

[Service]
Type=forking
User=${VNC_USER}
Group=${VNC_USER}
WorkingDirectory=${VNC_HOME}
PIDFile=${VNC_HOME}/.vnc/%H:%i.pid
ExecStartPre=-/usr/bin/tigervncserver -kill :%i
ExecStop=/usr/bin/tigervncserver -kill :%i
ExecStart=/usr/bin/tigervncserver :%i

[Install]
WantedBy=multi-user.target
EOF

# 4h. Clear stale locks, reload systemd, enable and start
sudo rm -rf "/tmp/.X11-unix/X${VNC_DISPLAY}" "/tmp/.X${VNC_DISPLAY}-lock"
sudo systemctl daemon-reload
sudo systemctl enable "vncserver@${VNC_DISPLAY}.service"
sudo systemctl restart "vncserver@${VNC_DISPLAY}.service"

HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
[ -z "$HOST_IP" ] && HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

echo ""
echo "✅ TigerVNC running on display :${VNC_DISPLAY} (port 590${VNC_DISPLAY})."
echo "   Connect from a VNC client:  ${HOST_IP}:590${VNC_DISPLAY}"
echo "   Password:                   the one you set in Step 4b above"
echo ""
echo "✅ All done. Reconnect your SSH session (or run: source ~/.bashrc) to activate the shell changes."