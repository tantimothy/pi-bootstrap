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

# deploy_environment() (lib/deploy-lib.sh) deliberately doesn't wrap run.sh
# in its own `script`-based session logging — see that function's own
# comment. This environment has no interactive attach at all (host-only,
# no container), so the whole rest of this script is safe to self-log
# unconditionally.
source "$REPO_DIR/lib/deploy-lib.sh"
_selflog_start "$SCRIPT_DIR" "${REBUILD_POLICY:-FAST}"

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

    # The splash catalogue (shared by the random login pick and the
    # whimsy-menu TUI) and the TUI itself. locale-lib.sh rides along beside
    # them because whimsy-menu sources it before dialog draws anything —
    # deployed rather than duplicated so there's still exactly one copy of
    # that logic in the repo (see lib/locale-lib.sh's own comment for the
    # real macOS garbling it prevents).
    _deploy_file "$SCRIPT_DIR/bin/whimsy-splash" "$HOME/bin/whimsy-splash"
    chmod +x "$HOME/bin/whimsy-splash"
    _deploy_file "$SCRIPT_DIR/bin/whimsy-menu" "$HOME/bin/whimsy-menu"
    chmod +x "$HOME/bin/whimsy-menu"
    _deploy_file "$REPO_DIR/lib/locale-lib.sh" "$HOME/bin/locale-lib.sh"

    # --- HOLLYWOOD (github.com/dustinkirkland/hollywood) ---
    #
    # The one splash with no Homebrew formula: upstream ships it as a
    # Debian package (`apt install hollywood`), and homebrew-core has never
    # carried it. So it's fetched here — once, at install/redeploy time,
    # exactly like the TalkingMoose phrases below and for the same reasons.
    #
    # Layout matters: hollywood resolves its widgets as
    # `$(dirname $0)/../lib/hollywood`, so the script has to sit in a bin/
    # with a sibling lib/ — hence ~/bin/hollywood.d/ rather than dropping it
    # straight into ~/bin (where WIDGET_DIR would resolve to ~/lib/hollywood
    # and every pane would come up empty). A symlink wouldn't work either,
    # for the same $0-relative reason; bin/whimsy-splash therefore calls the
    # full path.
    #
    # Only the widgets that can actually run on macOS are fetched. Of
    # upstream's twenty, seven want ccze (unmaintained, no Homebrew
    # formula), and most of the rest want a Linux-only tool (atop, bmon,
    # apg), GNU find's -readable, or paths macOS doesn't have (/proc,
    # /sys, /var/log/*.log). A widget whose dependency check fails exits
    # immediately and its pane dies, so fetching them anyway would just
    # thin out the screen — better to hand hollywood a widget directory
    # where everything in it works. The three mac-* widgets deployed below
    # (from this repo, not upstream) cover the ground the skipped ones
    # would have: system logs, hex dumps, network throughput.
    echo ""
    echo "🎬 Fetching hollywood to ~/bin/hollywood.d..."
    HOLLYWOOD_DIR="$HOME/bin/hollywood.d"
    HOLLYWOOD_WIDGET_DIR="$HOLLYWOOD_DIR/lib/hollywood"
    HOLLYWOOD_RAW="https://raw.githubusercontent.com/dustinkirkland/hollywood/master"
    HOLLYWOOD_WIDGETS=(cmatrix figlet htop pv)
    mkdir -p "$HOLLYWOOD_DIR/bin" "$HOLLYWOOD_WIDGET_DIR"

    HOLLYWOOD_MISSING=false
    [ -f "$HOLLYWOOD_DIR/bin/hollywood" ] || HOLLYWOOD_MISSING=true
    for name in "${HOLLYWOOD_WIDGETS[@]}"; do
        [ -f "$HOLLYWOOD_WIDGET_DIR/$name" ] || { HOLLYWOOD_MISSING=true; break; }
    done
    if [ "$HOLLYWOOD_MISSING" = "false" ]; then
        echo "   ✅ Already cached (script + ${#HOLLYWOOD_WIDGETS[@]} widgets)."
    else
        # $1 = URL suffix under the repo root, $2 = destination path.
        _fetch_hollywood_file() {
            if curl --max-time 10 -fsSL "$HOLLYWOOD_RAW/$1" -o "$2.tmp"; then
                mv "$2.tmp" "$2"
                chmod +x "$2"
                return 0
            fi
            rm -f "$2.tmp"
            echo "   ⚠️  Couldn't fetch $1 — skipping." >&2
            return 1
        }
        _fetch_hollywood_file "bin/hollywood" "$HOLLYWOOD_DIR/bin/hollywood" || true
        HOLLYWOOD_OK=0
        for name in "${HOLLYWOOD_WIDGETS[@]}"; do
            _fetch_hollywood_file "lib/hollywood/$name" "$HOLLYWOOD_WIDGET_DIR/$name" \
                && HOLLYWOOD_OK=$((HOLLYWOOD_OK + 1))
        done
        if [ -x "$HOLLYWOOD_DIR/bin/hollywood" ]; then
            echo "   ✅ Fetched hollywood + $HOLLYWOOD_OK/${#HOLLYWOOD_WIDGETS[@]} upstream widgets."
        else
            # Not fatal, and deliberately not retried: whimsy-splash checks
            # for the binary before offering hollywood, so a machine that
            # couldn't reach GitHub simply never picks it (and whimsy-menu
            # lists it as not installed) until the next run.sh.
            echo "   ⚠️  hollywood itself wasn't fetched — it'll be skipped in the splash rotation."
        fi
    fi

    # This repo's own macOS widgets, always redeployed (they're ours, so
    # they track the repo rather than a cache).
    for widget in "$SCRIPT_DIR"/bin/hollywood-widgets/*; do
        [ -f "$widget" ] || continue
        _deploy_file "$widget" "$HOLLYWOOD_WIDGET_DIR/$(basename "$widget")"
        chmod +x "$HOLLYWOOD_WIDGET_DIR/$(basename "$widget")"
    done

    # Uli Kusterer's TalkingMoose (github.com/uliwitness/talkingmoose)
    # phrase files, fetched here — once, at install/redeploy time — rather
    # than by .bashrc.whimsy on every new interactive shell. That runs on
    # every login and every new terminal tab/pane, all day; hitting
    # raw.githubusercontent.com that often is both slow (added shell
    # startup latency) and needlessly hammers someone else's repo. Not
    # vendored into this repo's own git history either (unlike
    # bin/calendars above) — there's no reason to carry upstream's content
    # in our own history when a periodic re-fetch keeps it just as fresh.
    #
    # Only the files confirmed (as of this writing) to actually contain a
    # PAUSE activity section are listed — TalkingMoose splits each
    # *.phraseFile into several activities (PAUSE, HELLO, GOODBYE, LAUNCH
    # APPLICATION, etc.), and PAUSE — the idle-desk-toy one-liners — is
    # the only one .bashrc.whimsy uses. App Launch:Quit.phraseFile, Easter
    # Eggs.phraseFile, Moosepionage.phraseFile, MorePhrases.phraseFile,
    # Settings Stuff.phraseFile, and Time Announcements.phraseFile don't
    # have one and are deliberately skipped, so every file that lands in
    # MOOSE_DIR is guaranteed usable.
    echo ""
    echo "🎭 Fetching TalkingMoose phrases to ~/bin/moose-phrases..."
    MOOSE_DIR="$HOME/bin/moose-phrases"
    mkdir -p "$MOOSE_DIR"
    MOOSE_FILES=(
        "Advice.phraseFile" "Cats.phraseFile" "Children.phraseFile"
        "Coffee!.phraseFile" "Dictionary Definitions.phraseFile" "Dogs.phraseFile"
        "EvenMorePhrases.phraseFile" "Food.phraseFile" "Geekdom.phraseFile"
        "Healthy Life.phraseFile" "Here's to Doug.phraseFile" "Insults.phraseFile"
        "Last Words and Trouble.phraseFile" "Lazyness.phraseFile" "More Moose!.phraseFile"
        "Office and Jobs.phraseFile" "Phrases.phraseFile" "Pratchett.phraseFile"
        "Proverbs.phraseFile" "Punch Lines.phraseFile" "Quotations I.phraseFile"
        "Quotations II.phraseFile" "Songs.phraseFile" "Stargate.phraseFile"
        "StillMorePhrases.phraseFile" "War of the OSs.phraseFile" "Witticisms I.phraseFile"
        "Witticisms II.phraseFile" "Witticisms III.phraseFile" "Witticisms IV.phraseFile"
        "Witticisms V.phraseFile" "Witticisms VI.phraseFile"
    )
    # Skip the network entirely once every expected file is already
    # cached — re-running ./run.sh shouldn't re-fetch all 32 files from
    # GitHub every single time.
    MOOSE_MISSING=false
    for name in "${MOOSE_FILES[@]}"; do
        [ -f "$MOOSE_DIR/$name" ] || { MOOSE_MISSING=true; break; }
    done
    if [ "$MOOSE_MISSING" = "false" ]; then
        echo "   ✅ Already cached ($(( ${#MOOSE_FILES[@]} )) files)."
    else
        MOOSE_OK=0
        for name in "${MOOSE_FILES[@]}"; do
            # Percent-encode just the characters this exact, static file
            # list actually contains — not a general-purpose urlencode.
            enc="${name// /%20}"; enc="${enc//!/%21}"; enc="${enc//\'/%27}"
            if curl --max-time 5 -fsSL \
                "https://raw.githubusercontent.com/uliwitness/talkingmoose/main/TalkingMoose/Phrases/${enc}" \
                -o "$MOOSE_DIR/$name.tmp"; then
                mv "$MOOSE_DIR/$name.tmp" "$MOOSE_DIR/$name"
                MOOSE_OK=$((MOOSE_OK + 1))
            else
                rm -f "$MOOSE_DIR/$name.tmp"
                echo "   ⚠️  Couldn't fetch \"$name\" — skipping." >&2
            fi
        done
        echo "   ✅ Fetched $MOOSE_OK/${#MOOSE_FILES[@]} phrase files."
    fi
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
_selflog_stop  # INFO summary itself is unlogged, same as the outer INFO policy
bash "$REPO_DIR/lib/run-info.sh" "$SCRIPT_DIR" list

echo ""
if [ "$BACKUP_MADE" = "true" ]; then
    echo "🗄️  Existing files were backed up to: $BACKUP_DIR"
fi
echo "✅ All done. Open a new terminal tab (or run: source ~/.bash_profile) to activate the shell changes."
