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

echo "✅ Success! System initialization script finished successfully."
echo "💡 Please source your bash profiles or restart your SSH session to observe structural updates: source ~/.bashrc"