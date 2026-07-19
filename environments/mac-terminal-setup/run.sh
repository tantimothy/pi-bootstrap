#!/bin/bash
#
# Deploys this Mac's terminal setup (colored git-aware prompt, tmux
# auto-attach, fastfetch on login, and optional whimsical extras) to the
# current user's home directory. Idempotent — safe to re-run any time.
#
# Every existing file this script would overwrite is backed up first (see
# _deploy_file/_deploy_dir below) into a timestamped directory under
# $HOME/.pi-bootstrap-backups/.

# --- CONFIGURATION ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BASHRC="$HOME/.bashrc"
ENV_FILE="$SCRIPT_DIR/.env"
BACKUP_DIR="$HOME/.pi-bootstrap-backups/mac-terminal-setup-$(date +%Y%m%d-%H%M%S)"
BACKUP_MADE=false

if [[ "$(uname)" != "Darwin" ]]; then
    echo "❌ mac-terminal-setup is macOS-only (found $(uname)). Nothing to do." >&2
    exit 1
fi

echo "🔄 Starting Mac terminal setup..."

# --- HELPERS ---

# Backs up $2 into BACKUP_DIR (preserving its path relative to $HOME) if it
# already exists and differs from $1, then copies $1 over it.
_deploy_file() {
    local src="$1" dest="$2"
    if [ -e "$dest" ] && ! cmp -s "$src" "$dest" 2>/dev/null; then
        local rel="${dest#"$HOME"/}"
        mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
        cp -a "$dest" "$BACKUP_DIR/$rel"
        BACKUP_MADE=true
        echo "   📦 Backed up existing $dest"
    fi
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
}

# Same as _deploy_file but for a whole directory (used for bin/calendars,
# which has nested locale subdirectories cmp -s can't handle directly).
_deploy_dir() {
    local src="$1" dest="$2"
    if [ -d "$dest" ] && ! diff -rq "$src" "$dest" >/dev/null 2>&1; then
        local rel="${dest#"$HOME"/}"
        mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
        cp -R "$dest" "$BACKUP_DIR/$rel"
        BACKUP_MADE=true
        echo "   📦 Backed up existing $dest"
    fi
    mkdir -p "$(dirname "$dest")"
    rm -rf "$dest"
    cp -R "$src" "$dest"
}

# Reads a packages.txt-style file (one formula per line, # for comments)
# into the global PACKAGES array.
_read_packages() {
    local file="$1"
    PACKAGES=()
    [ -f "$file" ] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=$(echo "$line" | tr -d '\r' | xargs)
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        PACKAGES+=("$line")
    done < "$file"
}

# --- STEP 1: HOMEBREW ---
if ! command -v brew >/dev/null 2>&1; then
    echo ""
    echo "🍺 Homebrew not found."
    read -rp "   Install it now? [y/N]: " INSTALL_BREW
    if [[ "$INSTALL_BREW" =~ ^[Yy] ]]; then
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    else
        echo "⚠️  Skipping — package installation below will be skipped too."
    fi
fi

# --- STEP 2: WHIMSY ON/OFF (asked once, remembered in .env) ---
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi
if [ -z "${WHIMSY_ENABLED:-}" ]; then
    echo ""
    read -rp "🎭 Include whimsical login extras (fortune, cowsay, BOFH excuses, calendar, weather)? [y/N]: " WHIMSY_ANSWER
    if [[ "$WHIMSY_ANSWER" =~ ^[Yy] ]]; then
        WHIMSY_ENABLED=true
    else
        WHIMSY_ENABLED=false
    fi
    echo "WHIMSY_ENABLED=$WHIMSY_ENABLED" > "$ENV_FILE"
    echo "   (Change your mind later: edit $ENV_FILE and re-run ./run.sh, or use the"
    echo "    \"Toggle whimsical login extras\" action in ./deploy.sh's menu.)"
fi

# --- STEP 3: INSTALL PACKAGES ---
if command -v brew >/dev/null 2>&1; then
    _read_packages "$SCRIPT_DIR/packages.txt"
    if [ ${#PACKAGES[@]} -gt 0 ]; then
        echo ""
        echo "📦 Installing core packages: ${PACKAGES[*]}..."
        brew install "${PACKAGES[@]}"
    fi

    if [ "$WHIMSY_ENABLED" = "true" ]; then
        _read_packages "$SCRIPT_DIR/packages-whimsy.txt"
        if [ ${#PACKAGES[@]} -gt 0 ]; then
            echo ""
            echo "📦 Installing whimsy packages: ${PACKAGES[*]}..."
            brew install "${PACKAGES[@]}"
        fi

        # The Shakespearean/Piratical insult scripts need this CPAN module —
        # not brew-installable, so it goes through cpan instead.
        if ! perl -MAcme::Scurvy::Whoreson::BilgeRat -e1 >/dev/null 2>&1; then
            echo ""
            echo "🐪 Installing Perl module Acme::Scurvy::Whoreson::BilgeRat (insult generators)..."
            cpan -T Acme::Scurvy::Whoreson::BilgeRat || \
                echo "⚠️  Couldn't install it automatically — run 'cpan Acme::Scurvy::Whoreson::BilgeRat' by hand later."
        fi
    fi
else
    echo "⚠️  Homebrew not available — skipping package installation."
fi

# --- STEP 4: MACPORTS (detection only — no automated installer exists) ---
if [ ! -d /opt/local/bin ]; then
    echo ""
    echo "ℹ️  MacPorts not detected at /opt/local. The MacPorts PATH lines in"
    echo "   .bash_profile are harmless no-ops without it. Install manually from"
    echo "   https://www.macports.org/install.php if you want it."
fi

# --- STEP 5: DEPLOY .tmux.conf AND .bash_profile ---
echo ""
echo "📋 Deploying .tmux.conf and .bash_profile..."
_deploy_file "$SCRIPT_DIR/.tmux.conf" "$HOME/.tmux.conf"
_deploy_file "$SCRIPT_DIR/.bash_profile" "$HOME/.bash_profile"

# --- STEP 6: DEPLOY WHIMSY ASSETS (~/bin) ---
if [ "$WHIMSY_ENABLED" = "true" ]; then
    echo ""
    echo "📋 Deploying whimsy scripts to ~/bin..."
    _deploy_file "$SCRIPT_DIR/bin/bofhexcuse" "$HOME/bin/bofhexcuse"
    chmod +x "$HOME/bin/bofhexcuse"
    _deploy_file "$SCRIPT_DIR/bin/insulthost.pl" "$HOME/bin/insulthost.pl"
    _deploy_file "$SCRIPT_DIR/bin/piratehost.pl" "$HOME/bin/piratehost.pl"
    _deploy_file "$SCRIPT_DIR/bin/bofhserver/excuses.txt" "$HOME/bin/bofhserver/excuses.txt"
    _deploy_dir "$SCRIPT_DIR/bin/calendars" "$HOME/bin/calendars"
fi

# --- STEP 7: IDEMPOTENTLY INJECT .bashrc BLOCKS ---
echo ""
echo "✏️  Updating $BASHRC with terminal-setup blocks..."

if [ -f "$BASHRC" ]; then
    mkdir -p "$BACKUP_DIR"
    cp -a "$BASHRC" "$BACKUP_DIR/.bashrc"
    BACKUP_MADE=true
    echo "   📦 Backed up existing $BASHRC"
fi
touch "$BASHRC"

PROMPT_START="# >>> MAC TERMINAL PROMPT START >>>"
PROMPT_END="# <<< MAC TERMINAL PROMPT END <<<"
TMUX_START="# >>> MAC TERMINAL TMUX START >>>"
TMUX_END="# <<< MAC TERMINAL TMUX END <<<"
FASTFETCH_START="# >>> MAC TERMINAL FASTFETCH START >>>"
FASTFETCH_END="# <<< MAC TERMINAL FASTFETCH END <<<"
WHIMSY_START="# >>> MAC TERMINAL WHIMSY START >>>"
WHIMSY_END="# <<< MAC TERMINAL WHIMSY END <<<"

# Strips a marker-delimited block if present. BSD sed (macOS's bundled
# /usr/bin/sed) requires an explicit (empty) backup-suffix argument to -i —
# unlike GNU sed, `sed -i` with no argument is a hard error on macOS.
_strip_block() {
    local start="$1" end="$2"
    grep -qF "$start" "$BASHRC" && sed -i '' "/$start/,/$end/d" "$BASHRC"
}

# Appends a marker-delimited block built from a content file.
_append_block() {
    local start="$1" end="$2" content_file="$3"
    {
        echo ""
        echo "$start"
        cat "$content_file"
        echo "$end"
    } >> "$BASHRC"
}

_strip_block "$PROMPT_START" "$PROMPT_END"
_strip_block "$TMUX_START" "$TMUX_END"
_strip_block "$FASTFETCH_START" "$FASTFETCH_END"
_strip_block "$WHIMSY_START" "$WHIMSY_END"

_append_block "$PROMPT_START" "$PROMPT_END" "$SCRIPT_DIR/.bashrc.prompt"
_append_block "$TMUX_START" "$TMUX_END" "$SCRIPT_DIR/.bashrc.tmux"
_append_block "$FASTFETCH_START" "$FASTFETCH_END" "$SCRIPT_DIR/.bashrc.fastfetch"
if [ "$WHIMSY_ENABLED" = "true" ]; then
    _append_block "$WHIMSY_START" "$WHIMSY_END" "$SCRIPT_DIR/.bashrc.whimsy"
fi

echo "✅ Shell setup complete."

# Best-effort — a no-op today (this environment has no desktop-entries.yaml),
# kept for consistency with every other environment in case one is added later.
bash "$REPO_DIR/lib/run-install-desktop.sh" "$SCRIPT_DIR" >/dev/null 2>&1 || true

# Delegates to info.sh so the "just deployed" summary and the on-demand
# INFO menu are always the exact same content — one file, not two.
bash "$REPO_DIR/lib/run-info.sh" "$SCRIPT_DIR" list

echo ""
if [ "$BACKUP_MADE" = "true" ]; then
    echo "🗄️  Existing files were backed up to: $BACKUP_DIR"
fi
echo "✅ All done. Open a new terminal tab (or run: source ~/.bash_profile) to activate the shell changes."
