#!/bin/bash

# --- CONFIGURATION ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_FILE="$SCRIPT_DIR/packages.txt"
TMUX_SOURCE="$SCRIPT_DIR/.tmux.conf"
BASHRC="$HOME/.bashrc"

# Unique block markers for idempotency inside .bashrc.
# Split into two independently-positioned blocks (rather than one combined
# block) so tmux always runs first and fastfetch always runs last, even
# with other environments (e.g. pihole-wireguard's PADD launcher) injecting
# their own block in between.
TMUX_MARKER_START="# >>> PI TMUX SETUP START >>>"
TMUX_MARKER_END="# <<< PI TMUX SETUP END <<<"
FASTFETCH_MARKER_START="# >>> PI FASTFETCH SETUP START >>>"
FASTFETCH_MARKER_END="# <<< PI FASTFETCH SETUP END <<<"
# Old combined block from before the split — cleaned up on upgrade
LEGACY_MARKER_START="# >>> PI INITIAL SETUP START >>>"
LEGACY_MARKER_END="# <<< PI INITIAL SETUP END <<<"

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

touch "$BASHRC"

# Migrate away from the old single combined block, if present
if grep -qF "$LEGACY_MARKER_START" "$BASHRC"; then
    echo "🧹 Migrating old combined .bashrc block to the new split format."
    sed -i "/$LEGACY_MARKER_START/,/$LEGACY_MARKER_END/d" "$BASHRC"
fi

# tmux block: always re-pinned to the very top of .bashrc, so it runs
# before anything else (including blocks injected by other environments)
if grep -qF "$TMUX_MARKER_START" "$BASHRC"; then
    sed -i "/$TMUX_MARKER_START/,/$TMUX_MARKER_END/d" "$BASHRC"
fi
TMUX_BLOCK=$(cat <<BLOCK
$TMUX_MARKER_START
$(cat "$SCRIPT_DIR/.bashrc.tmux")
$TMUX_MARKER_END
BLOCK
)
{ echo "$TMUX_BLOCK"; echo ""; cat "$BASHRC"; } > "${BASHRC}.tmp" && mv "${BASHRC}.tmp" "$BASHRC"

# fastfetch block: always re-pinned to the very bottom of .bashrc, so it
# runs last regardless of what other blocks are injected in between
if grep -qF "$FASTFETCH_MARKER_START" "$BASHRC"; then
    sed -i "/$FASTFETCH_MARKER_START/,/$FASTFETCH_MARKER_END/d" "$BASHRC"
fi
FASTFETCH_BLOCK=$(cat <<BLOCK
$FASTFETCH_MARKER_START
$(cat "$SCRIPT_DIR/.bashrc.fastfetch")
$FASTFETCH_MARKER_END
BLOCK
)
{ echo ""; echo "$FASTFETCH_BLOCK"; } >> "$BASHRC"

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

# 4h. Reload systemd, enable on boot, then start or skip
sudo systemctl daemon-reload
sudo systemctl enable "vncserver@${VNC_DISPLAY}.service"

if systemctl is-active --quiet "vncserver@${VNC_DISPLAY}.service"; then
    echo "ℹ️  VNC server already running — skipping restart to preserve active sessions."
    echo "   To apply config changes manually: sudo systemctl restart vncserver@${VNC_DISPLAY}.service"
else
    # Only remove stale X locks when the service is not running
    sudo rm -rf "/tmp/.X11-unix/X${VNC_DISPLAY}" "/tmp/.X${VNC_DISPLAY}-lock"
    sudo systemctl start "vncserver@${VNC_DISPLAY}.service"
fi

# Delegates to info.sh so the "just deployed" summary and the on-demand
# INFO menu are always the exact same content — one file, not two.
bash "$SCRIPT_DIR/info.sh" list

echo ""
echo "✅ All done. Reconnect your SSH session (or run: source ~/.bashrc) to activate the shell changes."