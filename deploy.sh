#!/bin/bash

# Force a UTF-8 locale before anything below prints emoji or invokes
# dialog — see lib/locale-lib.sh's own comment for why (a real macOS
# session with no LANG/LC_ALL set hit both garbled INFO output and
# dialog's own "Text has extra characters" complaint). Computed with
# BASH_SOURCE rather than $PROJECT_DIR since that isn't determined until
# much further down, and dialog is invoked before then too.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/locale-lib.sh" || true

FALLBACK_PROJECT_DIR="$HOME/projects/bootstrap"
REPO_URL="https://github.com/tantimothy/pi-bootstrap.git"

# Detect OS once; used throughout for platform-specific paths.
OS_TYPE="linux"
if [[ "$(uname)" == "Darwin" ]]; then
    OS_TYPE="macos"
fi

# 1. DEPENDENCY CHECK: Ensure 'dialog' is installed
if ! command -v dialog &> /dev/null; then
    echo "📦 'dialog' tool not found. Installing it now..."
    if [ "$OS_TYPE" = "macos" ]; then
        if command -v brew &> /dev/null; then
            brew install dialog
        else
            echo "❌ Homebrew not found. Install it from https://brew.sh then re-run."
            exit 1
        fi
    else
        sudo apt-get update && sudo apt-get install -y dialog
    fi
fi

# 2. ENGINE CHECK: Ensure 'docker' is installed
if ! command -v docker &> /dev/null; then
    if [ "$OS_TYPE" = "macos" ]; then
        echo "❌ Docker not found. Install Docker Desktop from https://www.docker.com/products/docker-desktop then re-run."
        exit 1
    else
        echo "🐳 Docker engine not found! Initiating automated setup..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh
        rm get-docker.sh
        sudo usermod -aG docker "$USER"
        echo "✅ Docker successfully installed!"
        echo "⚠️  CRITICAL: Restart SSH after this deployment for user permissions to take effect."
        echo "Press Enter to continue..."
        read -r
    fi
fi

if ! docker compose version &> /dev/null; then
    if [ "$OS_TYPE" = "macos" ]; then
        echo "❌ Docker Compose plugin not found. Ensure Docker Desktop is up to date."
        exit 1
    else
        echo "📦 'docker-compose-plugin' not found. Installing..."
        sudo apt-get update && sudo apt-get install -y docker-compose-plugin
    fi
fi

# 3. YQ CHECK: Ensure go-yq (github.com/mikefarah/yq) is installed. Several
# environments' desktop-entries.yaml/info.yaml, plus config/environments.yaml,
# are read via `yq eval` — an eval-expression syntax the Python jq-wrapper
# some distros package under the same "yq" name (Debian/Ubuntu's apt
# package) does NOT speak, so a version-string check is required, not just
# a bare `command -v`. Installed to /usr/local/bin — ahead of /usr/bin on
# the default $PATH — so it shadows any apt-installed impostor without
# touching or uninstalling it.
if ! command -v yq &>/dev/null || ! yq --version 2>/dev/null | grep -q "mikefarah/yq"; then
    echo "📦 go-yq not found (or a different 'yq' is already on \$PATH). Installing it now..."
    if [ "$OS_TYPE" = "macos" ]; then
        if command -v brew &> /dev/null; then
            brew install yq
        else
            echo "❌ Homebrew not found. Install it from https://brew.sh then re-run."
            exit 1
        fi
    else
        # dpkg's architecture names mostly match yq's release asset names
        # directly (amd64, arm64) — 32-bit ARM is the one mismatch (dpkg:
        # armhf/armel, yq's asset: plain "arm").
        YQ_DPKG_ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
        case "$YQ_DPKG_ARCH" in
            amd64|arm64) YQ_ARCH="$YQ_DPKG_ARCH" ;;
            armhf|armel|armv7l|arm) YQ_ARCH="arm" ;;
            x86_64) YQ_ARCH="amd64" ;;
            aarch64) YQ_ARCH="arm64" ;;
            *)
                echo "❌ Unrecognized architecture '${YQ_DPKG_ARCH}' for yq install." >&2
                echo "   Install go-yq manually: https://github.com/mikefarah/yq#install" >&2
                exit 1
                ;;
        esac
        sudo curl -fsSL -o /usr/local/bin/yq \
            "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${YQ_ARCH}"
        sudo chmod +x /usr/local/bin/yq
    fi
    if ! command -v yq &>/dev/null || ! yq --version 2>/dev/null | grep -q "mikefarah/yq"; then
        echo "❌ yq install failed, or a conflicting 'yq' still takes priority on \$PATH." >&2
        echo "   Expected /usr/local/bin/yq to be found first — check \$PATH ordering." >&2
        exit 1
    fi
    echo "✅ yq (go-yq) successfully installed!"
fi

# 4. BULLETPROOF DOCKER PERMISSION CHECK WRAPPER
DOCKER_CMD="docker"
if ! docker ps &>/dev/null; then
    echo "🔒 Raw docker commands denied. Escalating to 'sudo docker' wrapper..."
    DOCKER_CMD="sudo docker"
fi

# Check if CURL_USER is provided (Expected format from curl -u: "username:token")
if [ ! -z "$CURL_USER" ]; then
    # 1. Prevent Git from hanging indefinitely on terminal prompts if auth fails
    export GIT_TERMINAL_PROMPT=0
    
    # 2. Use Bash Arrays instead of strings to eliminate 'eval' quoting bugs.
    # Tells Git to dynamically rewrite any standard github URL to use your token on-the-fly.
    # This solves the 'git fetch' prompt issue for pre-existing local repos.
    GIT_CMD=(git -c "url.https://${CURL_USER}@github.com/.insteadOf=https://github.com/")
else
    GIT_CMD=(git)
fi

echo "🔍 Checking execution environment..."
# Determine PROJECT_DIR unconditionally so it is always set, even on re-exec.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    PROJECT_DIR=$(git rev-parse --show-toplevel)
else
    PROJECT_DIR="$FALLBACK_PROJECT_DIR"
fi

# Sync from remote, then re-exec so the fresh code is the one that runs.
# Skipped when already re-exec'd to avoid an infinite loop.
if [ "$1" != "--updated" ]; then
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        cd "$PROJECT_DIR" || exit 1
        echo "🏠 Running from within local repository: $PROJECT_DIR"
        echo "📥 Fetching latest upstream tree..."
        "${GIT_CMD[@]}" fetch --all --prune

        echo "🔄 Forcing workspace sync with remote origin repository..."
        "${GIT_CMD[@]}" reset --hard origin/master
    else
        echo "📂 Preparing project directory at $PROJECT_DIR..."

        if [ ! -d "$PROJECT_DIR" ]; then
            echo "📁 Creating missing fallback directories..."
            mkdir -p "$(dirname "$PROJECT_DIR")"

            echo "📦 Repository not found locally. Cloning cleanly..."
            "${GIT_CMD[@]}" clone "$REPO_URL" "$PROJECT_DIR"
            cd "$PROJECT_DIR" || exit 1
        else
            cd "$PROJECT_DIR" || exit 1
            echo "📥 Fetching and applying latest code from GitHub..."
            "${GIT_CMD[@]}" fetch --all --prune
            "${GIT_CMD[@]}" reset --hard origin/master
        fi
    fi

    exec bash "$PROJECT_DIR/deploy.sh" --updated
fi

cd "$PROJECT_DIR" || exit 1

source "$PROJECT_DIR/lib/deploy-lib.sh"
source "$PROJECT_DIR/lib/yaml-lib.sh"
_require_yq || exit 1

# --- DIAGNOSTIC BLOCK ---
if [ ! -d "environments" ]; then
    dialog --title " Error " --msgbox "Missing directory: Could not find an 'environments/' folder at: $PROJECT_DIR" 8 60
    clear
    exit 1
fi

# Fixed display order, grouped by what each environment actually does — see
# config/environments.yaml for the category breakdown (host setup, AI
# assistants, networking/security, management last since it's cross-cutting
# Docker tooling for managing whatever else got deployed). That file is
# also the seed for a future hierarchical/submenu Environments UI, not just
# a flat order. `find` alone returns filesystem/inode order, which is
# arbitrary and varies between clones — flattening the YAML's categories in
# order gives something a user can actually predict. Anything not listed
# there (a newly added environment folder) is appended alphabetically
# afterward, so it's never silently hidden just because the YAML wasn't
# updated.
_read_lines < <(yq eval '.categories[].environments[]' "$PROJECT_DIR/config/environments.yaml")
ENV_ORDER_PRIORITY=("${_LINES[@]}")

# Membership check below is a linear scan against ALL_SUBDIRS itself,
# comparing basenames, rather than an associative-array set — declare -A is
# bash 4+ only, and macOS ships bash 3.2 (GPL licensing, unmaintained by
# Apple since 2007) with no associative array support at all. A handful of
# environment directories makes the O(n^2) scan free in practice.
ALL_SUBDIRS=()
for _name in "${ENV_ORDER_PRIORITY[@]}"; do
    if [ -d "environments/$_name" ]; then
        ALL_SUBDIRS+=( "environments/$_name" )
    fi
done
while IFS= read -r _dir; do
    _name=$(basename "$_dir")
    _already_listed=false
    for _existing in "${ALL_SUBDIRS[@]}"; do
        [ "$(basename "$_existing")" = "$_name" ] && { _already_listed=true; break; }
    done
    [ "$_already_listed" = "true" ] && continue
    ALL_SUBDIRS+=( "$_dir" )
done < <(find environments -maxdepth 1 -mindepth 1 -type d | sort)
unset _name _dir _already_listed _existing

DIAGNOSTIC_LOG=""

if [ ${#ALL_SUBDIRS[@]} -eq 0 ]; then
    DIAGNOSTIC_LOG="The 'environments/' folder is completely empty.\nPath: $PROJECT_DIR/environments"
else
    DIAGNOSTIC_LOG="Scanned directories inside $PROJECT_DIR/environments:\n\n"
    for dir in "${ALL_SUBDIRS[@]}"; do
        folder_name=$(basename "$dir")
        DIAGNOSTIC_LOG+="📁 /$folder_name -> REJECTED\n"
        
        if [ ! -f "$dir/run.sh" ] && [ ! -f "$dir/docker-compose.yml" ] && [ ! -f "$dir/Dockerfile" ]; then
            DIAGNOSTIC_LOG+="   ⚠️ Reason: Missing run.sh, docker-compose.yml, AND Dockerfile.\n\n"
        else
            DIAGNOSTIC_LOG+="   ⚠️ Reason: Directory structure matched, but path resolving failed.\n\n"
        fi
    done
fi

# Find valid target setups
ENV_DIRS=()
for dir in "${ALL_SUBDIRS[@]}"; do
    if [ -f "$dir/run.sh" ] || [ -f "$dir/docker-compose.yml" ] || [ -f "$dir/Dockerfile" ]; then
        ENV_DIRS+=( "$dir" )
    fi
done

if [ ${#ENV_DIRS[@]} -eq 0 ]; then
    dialog --title " Deployment Scan Breakdown " --msgbox "$DIAGNOSTIC_LOG" 20 70
    clear
    exit 1
fi

# Build the Environments submenu — short tags so users can jump with a
# keypress. Kept separate from the top-level MENU_OPTIONS below so the main
# menu itself stays a short, fixed list of action categories instead of
# growing by one row per environment.
ENV_OPTIONS=()
ENV_PATHS=()    # parallel array: index → actual directory path
ENV_TAGS=()     # parallel array: index → the dialog tag assigned below

# First pass: collect name/type/compat-tag per environment, and the
# longest folder name, so the type column below can be padded to line up
# across every row — dialog displays each item string verbatim, it
# doesn't do any column alignment of its own.
ENV_NAMES=()
ENV_TYPES=()
ENV_COMPATS=()
MAX_NAME_LEN=0

for dir in "${ENV_DIRS[@]}"; do
    folder_name=$(basename "$dir")

    # run.sh, when present, is itself one of several subtypes depending on
    # what it actually orchestrates underneath — shown here since "Custom
    # run.sh" alone doesn't say much about what a given environment
    # actually does. Detected cheaply from what's on disk / referenced in
    # the script, not from any declared metadata:
    if [ -f "$dir/run.sh" ] ; then
        # docker-compose.yml checked before Dockerfile: a compose file can
        # itself reference a local Dockerfile via `build:` (ntopng does) —
        # Compose is what run.sh actually calls in that case, so it takes
        # priority over the Dockerfile's mere presence.
        if [ -f "$dir/docker-compose.yml" ] ; then
            TYPE="[run.sh + Compose]"
        elif [ -f "$dir/Dockerfile" ] ; then
            TYPE="[run.sh + Dockerfile]"
        elif grep -q "git clone" "$dir/run.sh" 2>/dev/null ; then
            TYPE="[run.sh: 3rd-party repo]"
        else
            TYPE="[run.sh: host-only]"
        fi
    elif [ -f "$dir/docker-compose.yml" ] ; then
        TYPE="[Docker Compose]"
    elif [ -f "$dir/Dockerfile" ] ; then
        # No run.sh AND no docker-compose.yml — the generic fallback's
        # `docker run` has no `-v` flag at all, so this can build and run a
        # container but can never actually persist data to a bind mount.
        # Discouraged in favor of a docker-compose.yml with `build: .`,
        # which gets the same "no run.sh needed" simplicity plus real
        # volume/port/flag support — see the README's Archetype section.
        TYPE="[Dockerfile only — no volumes]"
    fi

    # Flag environments that require Linux host features when running on macOS.
    COMPAT_TAG=""
    if [ "$OS_TYPE" = "macos" ]; then
        if grep -qE "\-\-net=host|/dev/bus/usb|/dev/snd|wlan[0-9]|ttyUSB|ttyACM" "$dir/run.sh" 2>/dev/null; then
            COMPAT_TAG="  ⚠️  Linux-only"
        fi
    fi

    ENV_PATHS+=("$dir")
    ENV_NAMES+=("$folder_name")
    ENV_TYPES+=("$TYPE")
    ENV_COMPATS+=("$COMPAT_TAG")
    [ "${#folder_name}" -gt "$MAX_NAME_LEN" ] && MAX_NAME_LEN=${#folder_name}
done

# Second pass: name first, then the type column padded to line up.
#
# Tags are 1-9 for the first nine environments (unchanged single-keypress
# behavior for the common case), then A-Z for the 10th through 35th — past
# nine, dialog's typeahead no longer maps a single digit to a single row
# (e.g. "1" is now ambiguous between tag "1" and every tag starting with
# "1", like a literal "10" would be), so letters are the only way to keep
# one keypress = one environment once there are more than nine. Beyond 35
# (9 + 26 letters) this falls back to a plain multi-digit number — dialog
# still accepts typing it out, just without single-keypress access; not
# worth two-letter tags for a case this repo is unlikely to ever hit.
ENV_TAG_LETTERS="ABCDEFGHIJKLMNOPQRSTUVWXYZ"
for i in "${!ENV_NAMES[@]}"; do
    if [ "$i" -lt 9 ]; then
        TAG="$((i + 1))"
    elif [ "$((i - 9))" -lt "${#ENV_TAG_LETTERS}" ]; then
        TAG="${ENV_TAG_LETTERS:$((i - 9)):1}"
    else
        TAG="$((i + 1))"
    fi
    ENV_TAGS+=("$TAG")
    ENV_OPTIONS+=( "$TAG" "$(printf '%-*s' "$MAX_NAME_LEN" "${ENV_NAMES[$i]}")  ${ENV_TYPES[$i]}${ENV_COMPATS[$i]}" )
done

# Top-level menu — a fixed set of action categories, not one row per
# environment or per sub-action. Environments live behind "Environments";
# container/image listing, deleting, and image-update checking/applying all
# live behind "[Manage] Containers & Images" (see the _manage block below).
MENU_OPTIONS=()
MENU_OPTIONS+=( "E" "Environments" )
MENU_OPTIONS+=( "M" "[Manage] Containers & Images" )
MENU_OPTIONS+=( "D" "[Desktop] Install Desktop Entries" )
MENU_OPTIONS+=( "U" "[Desktop] Uninstall Desktop Entries" )
MENU_OPTIONS+=( "B" "[Backup] Create Backup Archive" )
MENU_OPTIONS+=( "R" "[Backup] Restore From Archive" )

# Everything from here down repeats until the user explicitly cancels the
# top-level menu below (the one true "quit" gesture) — every OTHER action's
# completion or cancellation loops back here instead of exiting to the
# shell, via `continue` at the end of each branch.
while true; do

# Present the Menu
TEMP_FILE=$(mktemp)
dialog --clear \
    --title " Raspberry Pi Deployment Center " \
    --menu "Choose an action:" 15 60 6 \
    "${MENU_OPTIONS[@]}" 2> "$TEMP_FILE"

EXIT_STATUS=$?
SELECTED_NUM=$(cat "$TEMP_FILE")
rm -f "$TEMP_FILE"

if [ $EXIT_STATUS -ne 0 ] || [ -z "$SELECTED_NUM" ]; then
    clear
    echo "❌ Deployment cancelled."
    exit 0
fi

# Resolve the selection to a dispatch target
if [ "$SELECTED_NUM" = "E" ]; then
    SELECTED_PATH="_environments"
elif [ "$SELECTED_NUM" = "M" ]; then
    SELECTED_PATH="_manage"
elif [ "$SELECTED_NUM" = "D" ]; then
    SELECTED_PATH="_desktop"
elif [ "$SELECTED_NUM" = "U" ]; then
    SELECTED_PATH="_desktop_uninstall"
elif [ "$SELECTED_NUM" = "B" ]; then
    SELECTED_PATH="_backup"
elif [ "$SELECTED_NUM" = "R" ]; then
    SELECTED_PATH="_restore"
fi

# ==========================================
# ENVIRONMENTS SUBMENU
# ==========================================
if [ "$SELECTED_PATH" = "_environments" ]; then
    if [ ${#ENV_OPTIONS[@]} -eq 0 ]; then
        clear
        echo "ℹ️  No environments found under environments/."
        read -rp "Press Enter to return to the menu..."
        continue
    fi

    TEMP_ENV_FILE=$(mktemp)
    dialog --clear \
        --title " Environments " \
        --menu "Choose a configuration workspace to deploy:" 20 70 12 \
        "${ENV_OPTIONS[@]}" 2> "$TEMP_ENV_FILE"
    ENV_EXIT=$?
    SELECTED_ENV_NUM=$(cat "$TEMP_ENV_FILE")
    rm -f "$TEMP_ENV_FILE"

    if [ $ENV_EXIT -ne 0 ] || [ -z "$SELECTED_ENV_NUM" ]; then
        clear
        continue
    fi

    # Tags aren't a plain 1-based index once letters are in play (see the
    # ENV_TAGS comment above) — look the chosen tag up in ENV_TAGS instead
    # of computing an offset.
    SELECTED_PATH=""
    for i in "${!ENV_TAGS[@]}"; do
        if [ "${ENV_TAGS[$i]}" = "$SELECTED_ENV_NUM" ]; then
            SELECTED_PATH="${ENV_PATHS[$i]}"
            break
        fi
    done
    # Falls through intentionally, not `continue` — SELECTED_PATH is now a
    # real environment directory, so the rest of the script (the deployment
    # policy selector onward) picks it up exactly as if it had been chosen
    # directly from the main menu, same as before this submenu existed.
fi

# ==========================================
# DOCKER MANAGEMENT SCREEN
# ==========================================
if [ "$SELECTED_PATH" = "_manage" ]; then
    clear

    # Sub-menu: choose what to manage
    TEMP_MGMT_TYPE=$(mktemp)
    dialog --clear \
        --title " Docker Manager " \
        --menu "What would you like to manage?" 12 64 3 \
        "C" "Containers    (list & delete running/stopped)" \
        "I" "Images        (list & delete local images)" \
        "U" "Check Updates (scan, then optionally apply what's flagged)" \
        2> "$TEMP_MGMT_TYPE"
    MGMT_TYPE_EXIT=$?
    MGMT_TYPE=$(cat "$TEMP_MGMT_TYPE")
    rm -f "$TEMP_MGMT_TYPE"

    if [ $MGMT_TYPE_EXIT -ne 0 ] || [ -z "$MGMT_TYPE" ]; then
        clear; echo "ℹ️  Cancelled."; continue
    fi

    # ------------------------------------------
    # CONTAINER MANAGEMENT
    # ------------------------------------------
    if [ "$MGMT_TYPE" = "C" ]; then
        CONTAINER_LIST=()
        while IFS= read -r line; do
            CNAME=$(echo "$line" | awk -F'\t' '{print $1}')
            CSTATUS=$(echo "$line" | awk -F'\t' '{print $2}')
            [ -z "$CNAME" ] && continue
            CONTAINER_LIST+=( "$CNAME" "$CSTATUS" "off" )
        done < <($DOCKER_CMD ps -a --format '{{.Names}}\t{{.Status}}' 2>/dev/null)

        if [ ${#CONTAINER_LIST[@]} -eq 0 ]; then
            dialog --clear --title " Container Manager " \
                --msgbox "\nNo Docker containers found on this system." 8 50
            clear; continue
        fi

        TEMP_MANAGE=$(mktemp)
        dialog --clear \
            --title " Container Manager " \
            --checklist "Space to select containers to DELETE. Running containers will be stopped first:" \
            20 74 12 \
            "${CONTAINER_LIST[@]}" 2> "$TEMP_MANAGE"

        MANAGE_EXIT=$?
        SELECTED_CONTAINERS=$(cat "$TEMP_MANAGE")
        rm -f "$TEMP_MANAGE"

        if [ $MANAGE_EXIT -ne 0 ] || [ -z "$SELECTED_CONTAINERS" ]; then
            clear; echo "ℹ️  No containers selected."; continue
        fi

        CONFIRM_MSG="The following containers will be STOPPED and REMOVED:\n\n"
        for C in $SELECTED_CONTAINERS; do
            CONFIRM_MSG+="  • ${C//\"/}\n"
        done
        CONFIRM_MSG+="\nThis cannot be undone. Continue?"

        dialog --clear --title " Confirm Deletion " --defaultno --yesno "$CONFIRM_MSG" 16 60
        if [ $? -ne 0 ]; then
            clear; echo "ℹ️  Deletion cancelled."; continue
        fi

        clear
        echo "🗑️  Removing selected containers..."
        for C in $SELECTED_CONTAINERS; do
            C="${C//\"/}"
            echo -n "   Stopping $C... "
            $DOCKER_CMD stop "$C" >/dev/null 2>&1 && echo "stopped." || echo "already stopped."
            echo -n "   Removing $C... "
            $DOCKER_CMD rm "$C" >/dev/null 2>&1 && echo "removed." || echo "failed."
        done
        echo "✅ Done."
        echo ""
        read -rp "Press Enter to return to the menu..."

    # ------------------------------------------
    # IMAGE MANAGEMENT
    # ------------------------------------------
    elif [ "$MGMT_TYPE" = "I" ]; then
        IMAGE_LIST=()
        while IFS= read -r line; do
            IREPO=$(echo "$line" | awk -F'\t' '{print $1}')
            ITAG=$(echo "$line"  | awk -F'\t' '{print $2}')
            ISIZE=$(echo "$line" | awk -F'\t' '{print $3}')
            IID=$(echo "$line"   | awk -F'\t' '{print $4}')
            [ -z "$IID" ] && continue
            LABEL="${IREPO}:${ITAG}"
            IMAGE_LIST+=( "$IID" "$LABEL  ($ISIZE)" "off" )
        done < <($DOCKER_CMD images --format '{{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.ID}}' 2>/dev/null)

        if [ ${#IMAGE_LIST[@]} -eq 0 ]; then
            dialog --clear --title " Image Manager " \
                --msgbox "\nNo Docker images found on this system." 8 50
            clear; continue
        fi

        TEMP_IMG=$(mktemp)
        dialog --clear \
            --title " Image Manager " \
            --checklist "Space to select images to REMOVE:" \
            20 74 12 \
            "${IMAGE_LIST[@]}" 2> "$TEMP_IMG"

        IMG_EXIT=$?
        SELECTED_IMAGES=$(cat "$TEMP_IMG")
        rm -f "$TEMP_IMG"

        if [ $IMG_EXIT -ne 0 ] || [ -z "$SELECTED_IMAGES" ]; then
            clear; echo "ℹ️  No images selected."; continue
        fi

        CONFIRM_MSG="The following images will be REMOVED:\n\n"
        for I in $SELECTED_IMAGES; do
            CONFIRM_MSG+="  • ${I//\"/}\n"
        done
        CONFIRM_MSG+="\nThis cannot be undone. Continue?"

        dialog --clear --title " Confirm Deletion " --defaultno --yesno "$CONFIRM_MSG" 16 60
        if [ $? -ne 0 ]; then
            clear; echo "ℹ️  Deletion cancelled."; continue
        fi

        clear
        echo "🗑️  Removing selected images..."
        for I in $SELECTED_IMAGES; do
            I="${I//\"/}"
            echo -n "   Removing $I... "
            $DOCKER_CMD rmi "$I" >/dev/null 2>&1 && echo "removed." || echo "failed (may be in use)."
        done
        echo "✅ Done."
        echo ""
        read -rp "Press Enter to return to the menu..."

    # ------------------------------------------
    # CHECK FOR IMAGE UPDATES (scan, then optionally apply)
    # ------------------------------------------
    elif [ "$MGMT_TYPE" = "U" ]; then
        clear
        CHECK_SCRIPT="$PROJECT_DIR/check-updates.sh"
        if [ ! -f "$CHECK_SCRIPT" ]; then
            echo "❌ check-updates.sh not found at $PROJECT_DIR"
        else
            # Always --apply: check-updates.sh --apply runs the exact same
            # scan first and only ever prompts if something's actually
            # flagged — with nothing to update, this is indistinguishable
            # from a plain scan. When something IS flagged, it confirms
            # per-container ([y/N/a=all/c=cancel]) before touching anything,
            # so no extra dialog confirmation is added here either — a
            # separate scan-only menu entry would just be this same report
            # with the option to act on it removed.
            DOCKER_CMD="$DOCKER_CMD" bash "$CHECK_SCRIPT" --apply
        fi
        echo ""
        read -rp "Press Enter to return to the menu..."
    fi
    continue
fi

# ==========================================
# DESKTOP ENTRIES INSTALLER
# ==========================================
if [ "$SELECTED_PATH" = "_desktop" ]; then
    clear
    DESKTOP_SCRIPT="$PROJECT_DIR/install-desktop-entries.sh"
    if [ ! -f "$DESKTOP_SCRIPT" ]; then
        echo "❌ install-desktop-entries.sh not found at $PROJECT_DIR"
        read -rp "Press Enter to return to the menu..."
        continue
    fi
    echo "🖥️  Installing desktop entries for all deployed environments..."
    bash "$DESKTOP_SCRIPT"
    echo ""
    echo "✅ Desktop entries installed. Re-run to update after deploying new environments."
    read -rp "Press Enter to return to the menu..."
    continue
fi

# ==========================================
# DESKTOP ENTRIES UNINSTALLER
# ==========================================
if [ "$SELECTED_PATH" = "_desktop_uninstall" ]; then
    clear
    DESKTOP_SCRIPT="$PROJECT_DIR/install-desktop-entries.sh"
    if [ ! -f "$DESKTOP_SCRIPT" ]; then
        echo "❌ install-desktop-entries.sh not found at $PROJECT_DIR"
        read -rp "Press Enter to return to the menu..."
        continue
    fi
    echo "🗑️  Removing all pi-bootstrap desktop entries..."
    bash "$DESKTOP_SCRIPT" --uninstall
    echo ""
    read -rp "Press Enter to return to the menu..."
    continue
fi

# ==========================================
# BACKUP
# ==========================================
if [ "$SELECTED_PATH" = "_backup" ]; then
    clear
    BACKUP_SCRIPT="$PROJECT_DIR/backup.sh"
    if [ ! -f "$BACKUP_SCRIPT" ]; then
        echo "❌ backup.sh not found at $PROJECT_DIR"
        read -rp "Press Enter to return to the menu..."
        continue
    fi
    bash "$BACKUP_SCRIPT" -o "$PROJECT_DIR"
    echo ""
    read -rp "Press Enter to return to the menu..."
    continue
fi

# ==========================================
# RESTORE FROM BACKUP
# ==========================================
if [ "$SELECTED_PATH" = "_restore" ]; then
    clear
    RESTORE_SCRIPT="$PROJECT_DIR/restore.sh"
    if [ ! -f "$RESTORE_SCRIPT" ]; then
        echo "❌ restore.sh not found at $PROJECT_DIR"
        read -rp "Press Enter to return to the menu..."
        continue
    fi

    # Offer a pick-list of backups found in $PROJECT_DIR (where "[Backup]
    # Create Backup Archive" writes by default), newest first, plus a manual
    # entry option in case the archive was moved or transferred in from
    # elsewhere. Degrades gracefully to just the manual option if none found.
    FOUND_ARCHIVES=()
    while IFS= read -r f; do
        FOUND_ARCHIVES+=("$f")
    done < <(find "$PROJECT_DIR" -maxdepth 1 -name 'pi-bootstrap-backup-*.tar.gz' 2>/dev/null | sort -r)

    ARCHIVE_MENU_OPTIONS=()
    ARCHIVE_MENU_PATHS=()
    ARCHIVE_MENU_INDEX=1
    for f in "${FOUND_ARCHIVES[@]}"; do
        ARCHIVE_SIZE=$(du -h "$f" 2>/dev/null | cut -f1)
        ARCHIVE_MENU_OPTIONS+=( "$ARCHIVE_MENU_INDEX" "$(basename "$f")  ($ARCHIVE_SIZE)" )
        ARCHIVE_MENU_PATHS+=("$f")
        ((ARCHIVE_MENU_INDEX++))
    done
    ARCHIVE_MENU_OPTIONS+=( "E" "Enter a path manually..." )

    TEMP_ARCHIVE_CHOICE=$(mktemp)
    dialog --clear --title " Restore From Backup " \
        --menu "Choose a backup archive to restore from:" 18 70 10 \
        "${ARCHIVE_MENU_OPTIONS[@]}" 2> "$TEMP_ARCHIVE_CHOICE"
    CHOICE_EXIT=$?
    ARCHIVE_CHOICE=$(cat "$TEMP_ARCHIVE_CHOICE")
    rm -f "$TEMP_ARCHIVE_CHOICE"

    if [ $CHOICE_EXIT -ne 0 ] || [ -z "$ARCHIVE_CHOICE" ]; then
        clear; echo "❌ Restore cancelled."; continue
    fi

    if [ "$ARCHIVE_CHOICE" = "E" ]; then
        TEMP_ARCHIVE_PATH=$(mktemp)
        dialog --clear --title " Restore From Backup " \
            --inputbox "Path to the backup .tar.gz archive:" 10 70 "$PROJECT_DIR/" \
            2> "$TEMP_ARCHIVE_PATH"
        ARCHIVE_EXIT=$?
        ARCHIVE_PATH=$(cat "$TEMP_ARCHIVE_PATH")
        rm -f "$TEMP_ARCHIVE_PATH"

        if [ $ARCHIVE_EXIT -ne 0 ] || [ -z "$ARCHIVE_PATH" ]; then
            clear; echo "❌ Restore cancelled."; continue
        fi
    else
        ARCHIVE_PATH="${ARCHIVE_MENU_PATHS[$((ARCHIVE_CHOICE - 1))]}"
    fi

    # restore.sh itself prompts (which environment, then a "type yes" confirm
    # per environment) — hand off to its own plain-terminal interactive flow
    # rather than re-implementing that inside dialog menus.
    clear
    bash "$RESTORE_SCRIPT" "$ARCHIVE_PATH"
    echo ""
    read -rp "Press Enter to return to the menu..."
    continue
fi

# ==========================================
# DEPLOYMENT POLICY SELECTOR MENU
# ==========================================

# Some environments' run.sh never branches on $POLICY/$REBUILD_POLICY at
# all (pi-barebones is the only current example — pure host provisioning
# that just re-runs the same idempotent setup every time) — for those,
# STOP/TEARDOWN/CLEAN would all silently do the exact same thing as FAST,
# which is actively misleading to present as distinct choices. Detected
# by grepping run.sh for any POLICY reference at all, rather than
# hardcoding environment names, so this stays correct if another
# host-only environment is added later. Both flags are recomputed fresh
# on every pass through deploy.sh's persistent menu loop (never appended
# to), so a later environment never inherits a flag left over from a
# previous one in the same session.
POLICY_HAS_LIFECYCLE=true
ENV_RUN_SH="$PROJECT_DIR/$SELECTED_PATH/run.sh"
if [ -f "$ENV_RUN_SH" ] && ! grep -q "POLICY" "$ENV_RUN_SH"; then
    POLICY_HAS_LIFECYCLE=false
fi

# WIPE is independently meaningless for an environment that declares no
# data at all to delete (info.yaml's data_dirs/install_dirs/named_volumes
# all empty, per pi-barebones' info.yaml) — checked separately from the
# lifecycle flag above, since the two aren't inherently coupled. Reads
# info.yaml directly rather than grepping info.sh's source text — nanoclaw
# and internet-pi's info.sh is a thin override with real branching, not a
# literal DATA_DIRS=() declaration, but their underlying data still comes
# from their own info.yaml, so this check is uniform across every
# environment regardless of whether it has an override script.
POLICY_HAS_WIPABLE_DATA=true
ENV_INFO_YAML="$PROJECT_DIR/$SELECTED_PATH/info.yaml"
if [ -f "$ENV_INFO_YAML" ]; then
    DD_COUNT=$(_yq '.data_dirs // [] | length' "$ENV_INFO_YAML" 2>/dev/null)
    ID_COUNT=$(_yq '.install_dirs // [] | length' "$ENV_INFO_YAML" 2>/dev/null)
    NV_COUNT=$(_yq '.named_volumes // [] | length' "$ENV_INFO_YAML" 2>/dev/null)
    if [ "${DD_COUNT:-1}" = "0" ] && [ "${ID_COUNT:-1}" = "0" ] && [ "${NV_COUNT:-1}" = "0" ]; then
        POLICY_HAS_WIPABLE_DATA=false
    fi
fi

# Optional per-environment extras beyond the fixed lifecycle policies above
# — an environment declares these itself in info.yaml's own custom_actions
# list (see docs/environment-yaml-schemas.md) rather than deploy.sh having
# to know about any specific one. Tagged ACTION_<index> (never a bare
# label) so there's no risk of a custom action's own label colliding with
# a real policy name like FAST/CLEAN — the ACTION_ prefix is what the
# dispatch block further down keys off of. Reset to empty on every pass
# through deploy.sh's persistent menu loop, same reasoning as
# POLICY_HAS_LIFECYCLE/POLICY_HAS_WIPABLE_DATA above: a later environment
# must never inherit a previous one's custom actions.
#
# command must be a SINGLE LINE (chain multiple statements with ; or &&,
# or point it at a script) — confirmed directly against go-yq's own output
# for a multi-line block-scalar command: `.custom_actions[].command`
# prints embedded newlines AND a blank-line separator between array
# elements, which _read_lines (one array entry per physical line) would
# silently split into extra entries, misaligning CUSTOM_ACTION_COMMANDS
# against CUSTOM_ACTION_LABELS from that element onward. Single-line
# values round-trip 1:1 with labels; this isn't worth the complexity of a
# JSON-based extraction just to support multi-line strings here.
CUSTOM_ACTION_LABELS=()
CUSTOM_ACTION_COMMANDS=()
if [ -f "$ENV_INFO_YAML" ]; then
    # (.custom_actions // [])[] — NOT ".custom_actions[].label // \"\"" —
    # confirmed directly: with custom_actions entirely absent (true for
    # every environment except the ones that actually declare one), the
    # latter form still emits one blank line rather than zero, which
    # _read_lines would read as a genuine (empty-label) entry — a real
    # environment with zero custom actions would otherwise get a single
    # bogus blank ACTION_0 menu item every time.
    _read_lines < <(_yq '(.custom_actions // [])[].label' "$ENV_INFO_YAML" 2>/dev/null)
    CUSTOM_ACTION_LABELS=("${_LINES[@]}")
    _read_lines < <(_yq '(.custom_actions // [])[].command' "$ENV_INFO_YAML" 2>/dev/null)
    CUSTOM_ACTION_COMMANDS=("${_LINES[@]}")
fi

POLICY_MENU_ITEMS=()
if [ "$POLICY_HAS_LIFECYCLE" = "true" ]; then
    POLICY_MENU_ITEMS+=(
        "FAST"     "Start if not running; skip if already active"
        "STOP"     "Pause running containers (resumable with FAST)"
        "TEARDOWN" "Stop & remove containers — no reinstall"
        "CLEAN"    "Stop, remove, and reinstall from scratch"
    )
else
    POLICY_MENU_ITEMS+=(
        "FAST"     "Run/re-run setup (always idempotent — safe to repeat)"
    )
fi
POLICY_MENU_ITEMS+=( "INFO" "List data directories and useful commands" )
if [ "$POLICY_HAS_WIPABLE_DATA" = "true" ]; then
    POLICY_MENU_ITEMS+=( "WIPE" "Delete persisted data directories (backup first!)" )
fi
for _i in "${!CUSTOM_ACTION_LABELS[@]}"; do
    POLICY_MENU_ITEMS+=( "ACTION_${_i}" "${CUSTOM_ACTION_LABELS[$_i]}" )
done
unset _i

TEMP_POLICY_FILE=$(mktemp)
dialog --clear \
    --title " Deployment Strategy Policy " \
    --menu "Select how to process the configuration build lifecycle:" 19 70 "$((${#POLICY_MENU_ITEMS[@]} / 2))" \
    "${POLICY_MENU_ITEMS[@]}" \
    2> "$TEMP_POLICY_FILE"

POLICY_EXIT=$?
REBUILD_POLICY=$(cat "$TEMP_POLICY_FILE")
rm -f "$TEMP_POLICY_FILE"  # Clean up temporary allocation file pointer

if [ $POLICY_EXIT -ne 0 ] || [ -z "$REBUILD_POLICY" ]; then
    clear
    echo "❌ Deployment cancelled."
    continue
fi

clear
ENV_NAME=$(basename "$SELECTED_PATH")
echo "🚀 Target Selected: $ENV_NAME"

# Confirm before anything that stops, removes, or deletes existing state.
# The policy dialog's own arrow-key-then-Enter selection isn't itself a
# confirmation — it's easy to land one item off the intended one — so
# STOP/TEARDOWN/CLEAN/WIPE each get an explicit yes/no gate here,
# defaulting to No. FAST and INFO are non-destructive (idempotent
# start-or-reuse, and read-only respectively) and skip this entirely.
# CONFIRM_MSG is reset unconditionally on every loop iteration (this whole
# block runs inside deploy.sh's persistent menu `while true` loop) so a
# FAST/INFO pass never inherits a stale message left over from a previous
# STOP/TEARDOWN/CLEAN/WIPE selection.
CONFIRM_MSG=""
case "$REBUILD_POLICY" in
    STOP)
        CONFIRM_MSG="Pause [$ENV_NAME]'s running container(s)?\n\nThey'll stop responding until resumed with FAST."
        ;;
    TEARDOWN)
        CONFIRM_MSG="Stop and REMOVE [$ENV_NAME]'s container(s)?\n\nData directories are preserved, but you'll need to redeploy (FAST or CLEAN) to use this environment again."
        ;;
    CLEAN)
        CONFIRM_MSG="Stop, remove, and reinstall [$ENV_NAME] from scratch?\n\nThe current container(s) will be replaced with freshly built/pulled ones. A failed build leaves the existing setup untouched, but a successful one does briefly interrupt service."
        ;;
    WIPE)
        CONFIRM_MSG="⚠️  PERMANENTLY DELETE [$ENV_NAME]'s persisted data directories?\n\nThis cannot be undone. Make sure you've backed up first (./backup.sh) if you need this data."
        ;;
esac

if [ -n "$CONFIRM_MSG" ]; then
    dialog --clear --title " Confirm $REBUILD_POLICY " --defaultno --yesno "$CONFIRM_MSG" 14 68
    CONFIRM_STATUS=$?
    if [ $CONFIRM_STATUS -ne 0 ]; then
        clear
        echo "❌ $REBUILD_POLICY cancelled for [$ENV_NAME]."
        echo ""
        read -rp "Press Enter to return to the menu..."
        continue
    fi
fi

# 4. (Removed) — this used to unconditionally tear down the target
# environment's containers by name before CLEAN even reached the archetype
# routing below. Two real problems with that:
#   1. TRACKING_NAME isn't computed until the "DYNAMIC CONTAINER
#      IDENTIFICATION LAYER" further down — this ran BEFORE that, so on
#      the very first deploy of a session it tore down nothing (empty
#      variable), and on every deploy AFTER the first (deploy.sh is a
#      persistent menu loop — see the while-loop wrapper below) it used
#      whichever TRACKING_NAME was left over from the PREVIOUS environment
#      selected, not the current one.
#   2. Tearing down before anything new is built/pulled defeats the whole
#      point of a safe CLEAN — every custom run.sh in this repo
#      deliberately builds/pulls first and only tears down after a
#      successful build, so a bad image never leaves nothing running.
#      This step ran before run.sh was even invoked, silently undermining
#      that safety property (and, for pihole-wireguard specifically,
#      breaking its own CLEAN-rollback fallback snapshot: it needs the
#      OLD container to still exist to `docker commit` it).
# Teardown-for-CLEAN is now each archetype's own responsibility, done at
# the correct point relative to its own build/pull — run.sh already does
# this correctly; the docker-compose.yml/Dockerfile fallback branches below
# now do too.

# 5. Navigate into the folder cleanly using absolute context
TARGET_WORKSPACE_DIR="$PROJECT_DIR/$SELECTED_PATH"
cd "$TARGET_WORKSPACE_DIR" || exit 1


# =======================================================
# 🔐 ADVANCED BULK FORM COMPILER WITH DEFAULT INJECTION
# =======================================================
if [ -f ".env.example" ] && [ "$REBUILD_POLICY" != "STOP" ] && [ "$REBUILD_POLICY" != "TEARDOWN" ] && [ "$REBUILD_POLICY" != "INFO" ] && [ "$REBUILD_POLICY" != "WIPE" ] && [[ "$REBUILD_POLICY" != ACTION_* ]]; then
    echo "🔑 Building multi-field runtime parameters board..."
    
    KEYS=()
    DEFAULTS=()
    HELP_TEXT=""
    CURRENT_COMMENT=""

    while IFS= read -r line || [ -n "$line" ]; do
        line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        
        if [[ "$line" =~ ^# ]]; then
            CLEAN_COMMENT=$(echo "$line" | sed 's/^#[[:space:]]*//')
            if [ -z "$CURRENT_COMMENT" ]; then
                CURRENT_COMMENT="$CLEAN_COMMENT"
            else
                CURRENT_COMMENT="$CURRENT_COMMENT $CLEAN_COMMENT"
            fi
        elif [[ "$line" =~ = ]]; then
            KEY=$(echo "$line" | cut -d'=' -f1 | sed 's/[[:space:]]*$//')
            VAL=$(echo "$line" | cut -d'=' -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            
            if [ ! -z "$KEY" ]; then
                # DYNAMIC FIX: If a configuration profile already exists, parse and inject its value as the new form default
                if [ -f ".env" ] && grep -q "^${KEY}=" .env; then
                    # Strip surrounding single quotes written by the form writer so
                    # the dialog field shows the clean value without escape characters.
                    VAL=$(grep "^${KEY}=" .env | cut -d'=' -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e "s/^'//;s/'$//")
                fi
                
                KEYS+=("$KEY")
                DEFAULTS+=("$VAL")
                
                # Append parameter context into a master scrollable information block string
                if [ -z "$CURRENT_COMMENT" ]; then
                    HELP_TEXT+="$KEY:\n• No explanation provided.\n\n"
                else
                    HELP_TEXT+="$KEY:\n• $CURRENT_COMMENT\n\n"
                fi
                CURRENT_COMMENT=""
            fi
        else
            if [ -z "$line" ]; then
                CURRENT_COMMENT=""
            fi
        fi
    done < .env.example

    if [ ${#KEYS[@]} -gt 0 ]; then
        # Render a scrollable explanation overlay block first so you can read what fields mean
        dialog --clear \
               --title " Variable Parameters Legend: [$ENV_NAME] " \
               --msgbox "\nReview the requirements for this workspace below before completing the configuration form:\n\n$HELP_TEXT" \
               20 74

        # Compile dynamic visual layouts for the inline form grid matrix
        FORM_FIELDS=()
        ROW_Y=1
        for i in "${!KEYS[@]}"; do
            FORM_FIELDS+=(
                "${KEYS[$i]}:"  "$ROW_Y" "2"  \
                "${DEFAULTS[$i]}" "$ROW_Y" "22" \
                "45" "256"
            )
            ((ROW_Y++))
        done

        # Generate responsive screen dimension metrics based on form element sizing criteria
        BOX_HEIGHT=$((ROW_Y + 5))
        [ $BOX_HEIGHT -gt 22 ] && BOX_HEIGHT=22
        
        TEMP_FORM_OUT=$(mktemp)
        
        dialog --clear \
               --title " Configure Runtime Variables " \
               --form "Use [UP/DOWN] to swap slots. Modify parameters or accept defaults directly:" \
               $BOX_HEIGHT 74 $((BOX_HEIGHT - 5)) "${FORM_FIELDS[@]}" 2> "$TEMP_FORM_OUT"
        
        EXIT_CODE=$?
        
        if [ $EXIT_CODE -eq 0 ]; then
            # _read_lines (lib/yaml-lib.sh) preserves empty lines as empty
            # array slots, same as mapfile — `read -a` must NOT be used here
            # instead, since it squeezes consecutive IFS delimiters, dropping
            # blank fields and shifting values.
            _read_lines < "$TEMP_FORM_OUT"
            CAPTURED_USER_INPUTS=("${_LINES[@]}")
            rm -f "$TEMP_FORM_OUT"

            # DYNAMIC FIX: Overwrite/Truncate existing configurations to prevent duplicated trailing rows
            > .env
            for i in "${!KEYS[@]}"; do
                RAW_VAL="${CAPTURED_USER_INPUTS[$i]}"
                # Expand a literal leading "~" (a bare "~" or "~/...") to
                # $HOME now, before the single-quoting below — otherwise
                # it'd be preserved as a literal, non-expanding tilde
                # forever: single quotes suppress tilde expansion exactly
                # the same way they suppress $VAR expansion, so a value
                # like "~/nanoclaw" typed here (or carried over from an
                # .env.example default) would never resolve to the user's
                # actual home directory once written out. "~otheruser/..."
                # is intentionally left alone — resolving another user's
                # home directory isn't worth the complexity for how rarely
                # it'd come up here.
                case "$RAW_VAL" in
                    "~") RAW_VAL="$HOME" ;;
                    "~/"*) RAW_VAL="$HOME/${RAW_VAL#\~/}" ;;
                esac
                # Wrap values in single quotes so $-bearing secrets (e.g. bcrypt hashes)
                # survive being `source`d by run.sh without variable expansion, while
                # remaining round-trip safe: the reader above strips these quotes before
                # displaying in the dialog form, preventing escape characters accumulating.
                # Any literal single quote in a value is escaped as '\''.
                SAFE_VAL="${RAW_VAL//\'/\'\\\'\'}"
                printf "%s='%s'\n" "${KEYS[$i]}" "$SAFE_VAL" >> .env
            done
            echo "✅ Finished compiling system configs successfully."
        else
            rm -f "$TEMP_FORM_OUT"
            clear
            echo "❌ Deployment halted: Missing mandatory parameters profile creation requirements."
            read -rp "Press Enter to return to the menu..."
            continue
        fi
    fi
fi
# =======================================================

# 6. INFO / WIPE — delegate entirely to lib/run-info.sh (environment-agnostic)
if [ "$REBUILD_POLICY" = "INFO" ] || [ "$REBUILD_POLICY" = "WIPE" ]; then
    cd "$TARGET_WORKSPACE_DIR" || exit 1
    if [ -f "info.sh" ] || [ -f "info.yaml" ]; then
        ACTION=$([ "$REBUILD_POLICY" = "INFO" ] && echo "list" || echo "delete")
        mkdir -p "$TARGET_WORKSPACE_DIR/logs"
        LOG_FILE="$TARGET_WORKSPACE_DIR/logs/${REBUILD_POLICY}-$(date +%Y%m%d-%H%M%S).log"
        echo "📝 Logging this run to: $LOG_FILE"
        _run_logged "$LOG_FILE" bash "$PROJECT_DIR/lib/run-info.sh" "$TARGET_WORKSPACE_DIR" "$ACTION"
    else
        echo "ℹ️  No info.sh or info.yaml found for [$ENV_NAME]. No data directory information available."
    fi
    echo ""
    _reset_tty_input
    read -rp "Press Enter to return to the menu..."
    continue
fi

# 6b. Custom actions (ACTION_<index>) — an environment's own info.yaml
# extras, run directly and unwrapped (no _run_logged pty wrapping, unlike
# INFO/WIPE above) so a fully interactive command (a `read` prompt, a
# `docker exec -it` handoff) works exactly as if typed directly, the same
# reasoning deploy_environment() itself uses for run.sh's own interactive
# handoffs. That does mean these aren't session-logged to
# environments/<env>/logs/ the way INFO/WIPE/FAST/CLEAN are — a deliberate
# tradeoff for supporting interactivity at all, not an oversight.
if [[ "$REBUILD_POLICY" == ACTION_* ]]; then
    ACTION_INDEX="${REBUILD_POLICY#ACTION_}"
    ACTION_LABEL="${CUSTOM_ACTION_LABELS[$ACTION_INDEX]}"
    ACTION_CMD_RAW="${CUSTOM_ACTION_COMMANDS[$ACTION_INDEX]}"
    cd "$TARGET_WORKSPACE_DIR" || exit 1
    ENV_DIR="$TARGET_WORKSPACE_DIR"
    [ -f ".env" ] && { set -a; source ".env"; set +a; }
    ACTION_CMD="$(_yaml_expand "$ACTION_CMD_RAW")"
    echo "🚀 [$ENV_NAME] $ACTION_LABEL"
    echo ""
    bash -c "$ACTION_CMD"
    ACTION_STATUS=$?
    echo ""
    _reset_tty_input
    if [ $ACTION_STATUS -ne 0 ]; then
        echo "❌ '$ACTION_LABEL' exited with an error (status $ACTION_STATUS)."
    fi
    read -rp "Press Enter to return to the menu..."
    continue
fi

# 7. ROUTING LOGIC & EXIT BOUNDARY CAPTURE — delegates to
# lib/deploy-lib.sh's deploy_environment(), shared with check-updates.sh
# --apply so both use the exact same archetype-dispatch mechanics (run.sh
# delegation, or the safe build-before-teardown docker-compose.yml/
# Dockerfile fallback) instead of duplicating them.
deploy_environment "$TARGET_WORKSPACE_DIR" "$REBUILD_POLICY" "$DOCKER_CMD"
DEPLOY_SUCCESS=$?

# Verify the execution status code of our build step before clearing
if [ $DEPLOY_SUCCESS -ne 0 ]; then
    echo "❌ ERROR: Deployment task failed for [$ENV_NAME]. Review the terminal logs above."
    echo ""
    read -rp "Press Enter to return to the menu..."
    continue
fi

# 7. Completion message — wording matches the action that was actually taken
case "$REBUILD_POLICY" in
    STOP)     echo "✅ Environment [$ENV_NAME] stopped." ;;
    TEARDOWN) echo "✅ Environment [$ENV_NAME] torn down." ;;
    WIPE)     echo "✅ Environment [$ENV_NAME] data wiped." ;;
    CLEAN)    echo "✅ Environment [$ENV_NAME] rebuilt from scratch." ;;
    INFO)     echo "✅ Environment [$ENV_NAME] info displayed." ;;
    *)        echo "✅ Environment [$ENV_NAME] deployed." ;;
esac

echo ""
read -rp "Press Enter to return to the menu..."
continue

done