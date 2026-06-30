#!/bin/bash

FALLBACK_PROJECT_DIR="$HOME/projects/bootstrap"
REPO_URL="https://github.com/tantimothy/pi-bootstrap.git"

# 1. DEPENDENCY CHECK: Ensure 'dialog' is installed
if ! command -v dialog &> /dev/null; then
    echo "📦 'dialog' tool not found. Installing it now..."
    sudo apt-get update && sudo apt-get install -y dialog
fi

# 2. ENGINE CHECK: Ensure 'docker' is installed
if ! command -v docker &> /dev/null; then
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
# Add this after the Docker installation check
if ! docker compose version &> /dev/null; then
    echo "📦 'docker-compose-plugin' not found. Installing..."
    sudo apt-get update && sudo apt-get install -y docker-compose-plugin
fi

# 3. BULLETPROOF DOCKER PERMISSION CHECK WRAPPER
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

# --- DIAGNOSTIC BLOCK ---
if [ ! -d "environments" ]; then
    dialog --title " Error " --msgbox "Missing directory: Could not find an 'environments/' folder at: $PROJECT_DIR" 8 60
    clear
    exit 1
fi

ALL_SUBDIRS=( $(find environments -maxdepth 1 -mindepth 1 -type d) )
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

# Build menu options
MENU_OPTIONS=()
for dir in "${ENV_DIRS[@]}"; do
    folder_name=$(basename "$dir")

    if [ -f "$dir/run.sh" ] ; then
        TYPE="[Custom run.sh]"
    elif [ -f "$dir/docker-compose.yml" ] ; then
        TYPE="[Docker Compose]"
    elif [ -f "$dir/Dockerfile" ] ; then
        TYPE="[Standalone Dockerfile]"
    fi

    MENU_OPTIONS+=( "$dir" "$TYPE /$folder_name" )
done

# Append management action at the bottom of the menu
MENU_OPTIONS+=( "_manage" "[Manage] List & Delete Containers" )

# Present the Menu
TEMP_FILE=$(mktemp)
dialog --clear \
    --title " Raspberry Pi Deployment Center " \
    --menu "Choose a configuration workspace to deploy:" 16 70 8 \
    "${MENU_OPTIONS[@]}" 2> "$TEMP_FILE"

EXIT_STATUS=$?
SELECTED_PATH=$(cat "$TEMP_FILE")
rm -f "$TEMP_FILE"

if [ $EXIT_STATUS -ne 0 ] || [ -z "$SELECTED_PATH" ]; then
    clear
    echo "❌ Deployment cancelled."
    exit 0
fi

# ==========================================
# CONTAINER MANAGEMENT SCREEN
# ==========================================
if [ "$SELECTED_PATH" = "_manage" ]; then
    clear

    # Collect all containers with their status
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
        clear
        exit 0
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
        clear
        echo "ℹ️  No containers selected. Exiting."
        exit 0
    fi

    # Confirm before deleting
    CONFIRM_MSG="The following containers will be STOPPED and REMOVED:\n\n"
    for C in $SELECTED_CONTAINERS; do
        CONFIRM_MSG+="  • ${C//\"/}\n"
    done
    CONFIRM_MSG+="\nThis cannot be undone. Continue?"

    dialog --clear --title " Confirm Deletion " \
        --yesno "$CONFIRM_MSG" 16 60
    if [ $? -ne 0 ]; then
        clear
        echo "ℹ️  Deletion cancelled."
        exit 0
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
    exit 0
fi

# ==========================================
# DEPLOYMENT POLICY SELECTOR MENU
# ==========================================

TEMP_POLICY_FILE=$(mktemp)
dialog --clear \
    --title " Deployment Strategy Policy " \
    --menu "Select how to process the configuration build lifecycle:" 11 70 2 \
    "FAST" "Preserve existing images & container instances if active" \
    "CLEAN" "Force fresh rebuild/teardown of the active environment" \
    2> "$TEMP_POLICY_FILE"

POLICY_EXIT=$?
REBUILD_POLICY=$(cat "$TEMP_POLICY_FILE")
rm -f "$TEMP_POLICY_FILE"  # Clean up temporary allocation file pointer

if [ $POLICY_EXIT -ne 0 ] || [ -z "$REBUILD_POLICY" ]; then
    clear
    echo "❌ Deployment cancelled."
    exit 0
fi

clear
ENV_NAME=$(basename "$SELECTED_PATH")
echo "🚀 Target Selected: $ENV_NAME"

# 4. Universal Targeted Teardown Pattern
if [ "$REBUILD_POLICY" = "CLEAN" ]; then
    echo "🛑 [CLEAN Policy] Tearing down active target environment container instances..."
    
    # Loop through each container name defined in the variable
    for TARGET_CONTAINER in $TRACKING_NAME; do
        if $DOCKER_CMD ps -a --format '{{.Names}}' | grep -q "^${TARGET_CONTAINER}$"; then
            echo "   Stopping and removing: $TARGET_CONTAINER"
            $DOCKER_CMD stop "$TARGET_CONTAINER" 2>/dev/null
            $DOCKER_CMD rm "$TARGET_CONTAINER" 2>/dev/null
        fi
    done
fi

# 5. Navigate into the folder cleanly using absolute context
TARGET_WORKSPACE_DIR="$PROJECT_DIR/$SELECTED_PATH"
cd "$TARGET_WORKSPACE_DIR" || exit 1


# =======================================================
# 🔐 ADVANCED BULK FORM COMPILER WITH DEFAULT INJECTION
# =======================================================
if [ -f ".env.example" ]; then
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
            # Use mapfile/readarray instead of `read -a`: word-splitting via `read -a`
            # squeezes consecutive IFS delimiters, silently dropping array slots for any
            # field the user left blank and shifting every subsequent value up by one.
            mapfile -t CAPTURED_USER_INPUTS < "$TEMP_FORM_OUT"
            rm -f "$TEMP_FORM_OUT"

            # DYNAMIC FIX: Overwrite/Truncate existing configurations to prevent duplicated trailing rows
            > .env
            for i in "${!KEYS[@]}"; do
                # Wrap values in single quotes so $-bearing secrets (e.g. bcrypt hashes)
                # survive being `source`d by run.sh without variable expansion, while
                # remaining round-trip safe: the reader above strips these quotes before
                # displaying in the dialog form, preventing escape characters accumulating.
                # Any literal single quote in a value is escaped as '\''.
                SAFE_VAL="${CAPTURED_USER_INPUTS[$i]//\'/\'\\\'\'}"
                printf "%s='%s'\n" "${KEYS[$i]}" "$SAFE_VAL" >> .env
            done
            echo "✅ Finished compiling system configs successfully."
        else
            rm -f "$TEMP_FORM_OUT"
            clear
            echo "❌ Deployment halted: Missing mandatory parameters profile creation requirements."
            exit 1
        fi
    fi
fi
# =======================================================

# =======================================================
# 🔍 DYNAMIC CONTAINER IDENTIFICATION LAYER
# =======================================================
# Establish a fallback naming constraint pointing to the folder context
TRACKING_NAME="$ENV_NAME"

# Interrogate compiled configs or blueprints for an explicit container name override
if [ -f ".env" ] && grep -q "^CONTAINER_NAME=" .env; then
    TRACKING_NAME=$(grep "^CONTAINER_NAME=" .env | cut -d'=' -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
elif [ -f ".env.example" ] && grep -q "^CONTAINER_NAME=" .env.example; then
    TRACKING_NAME=$(grep "^CONTAINER_NAME=" .env.example | cut -d'=' -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
fi
# =======================================================

# 6. ROUTING LOGIC & EXIT BOUNDARY CAPTURE
DEPLOY_SUCCESS=1

# Ensure we are strictly pointing to the local workspace context directory
cd "$TARGET_WORKSPACE_DIR" || exit 1

if [ -f "run.sh" ]; then
    echo "⚡ Custom run script detected! Executing run.sh..."
    chmod +x run.sh
    
    # DYNAMIC FIX: Export user selected rebuild policy downstream to custom subscripts
    export REBUILD_POLICY="$REBUILD_POLICY" 
    export DOCKER_CMD
    
    # Execute the run script directly without altering user-permissions or local environmental directory paths
    ./run.sh
    DEPLOY_SUCCESS=$?

elif [ -f "docker-compose.yml" ]; then
    if [ "$REBUILD_POLICY" = "CLEAN" ]; then
        echo "🐳 Docker Compose file detected [CLEAN]! Performing fresh stack teardown and rebuild..."
        $DOCKER_CMD compose down 2>/dev/null
        $DOCKER_CMD compose up --build --no-cache -d
        DEPLOY_SUCCESS=$?
    else
        echo "🐳 Docker Compose file detected [FAST]! Synchronizing stack changes using cached layer parameters..."
        $DOCKER_CMD compose up -d
        DEPLOY_SUCCESS=$?
    fi

elif [ -f "Dockerfile" ]; then
    if [ "$REBUILD_POLICY" = "CLEAN" ]; then
        echo "🛠️ Raw Dockerfile detected [CLEAN]! Executing zero-cache structural compilation..."
        $DOCKER_CMD build --no-cache -t "$ENV_NAME:latest" .
        if [ $? -eq 0 ]; then
            ENV_FLAGS=""
            if [ -f ".env" ]; then ENV_FLAGS="--env-file .env"; fi
            $DOCKER_CMD run -d --name "$TRACKING_NAME" $ENV_FLAGS --restart unless-stopped -p 80:80 "$ENV_NAME:latest"
            DEPLOY_SUCCESS=$?
        else
            DEPLOY_SUCCESS=1
        fi
    else
        echo "🛠️ Raw Dockerfile detected [FAST]! Checking execution context rules..."
        if $DOCKER_CMD ps --format '{{.Names}}' | grep -q "^${TRACKING_NAME}$"; then
            echo "✅ Container '$TRACKING_NAME' is active. Preserving application uptime status!"
            DEPLOY_SUCCESS=0
        elif $DOCKER_CMD ps -a --format '{{.Names}}' | grep -q "^${TRACKING_NAME}$"; then
            echo "🔄 Container '$TRACKING_NAME' is dormant. Triggering pipeline startup recovery..."
            $DOCKER_CMD start "$TRACKING_NAME"
            DEPLOY_SUCCESS=$?
        else
            echo "🛠️ Container sequence vacant. Building image and provisioning environment layers..."
            $DOCKER_CMD build -t "$ENV_NAME:latest" .
            if [ $? -eq 0 ]; then
                ENV_FLAGS=""
                if [ -f ".env" ]; then ENV_FLAGS="--env-file .env"; fi
                $DOCKER_CMD run -d --name "$TRACKING_NAME" $ENV_FLAGS --restart unless-stopped -p 80:80 "$ENV_NAME:latest"
                DEPLOY_SUCCESS=$?
            else
                DEPLOY_SUCCESS=1
            fi
        fi
    fi
fi

# Verify the execution status code of our build step before clearing
if [ $DEPLOY_SUCCESS -ne 0 ]; then
    echo "❌ ERROR: Deployment task failed for [$ENV_NAME]. Review the terminal logs above."
    exit 1
fi

# 7. Image Sweep
echo "🧹 Sweeping unused cache layers..."
# $DOCKER_CMD image prune -a -f

echo "✅ Environment [$ENV_NAME] successfully deployed!"