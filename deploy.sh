#!/bin/bash

FALLBACK_PROJECT_DIR="$HOME/projects/myapp"
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

# 3. BULLETPROOF DOCKER PERMISSION CHECK WRAPPER
DOCKER_CMD="docker"
if ! docker ps &>/dev/null; then
    echo "🔒 Raw docker commands denied. Escalating to 'sudo docker' wrapper..."
    DOCKER_CMD="sudo docker"
fi

# Extract the token directly from the CURL_USER environment variable
TOKEN=$(echo "$CURL_USER" | cut -d':' -f2)

# Build a specialized git command that forces token authentication via headers
if [ ! -z "$TOKEN" ]; then
    B64_TOKEN=$(echo -n "tantimothy:$TOKEN" | base64 | tr -d '\n')
    GIT_CMD="git -c http.extraHeader=\"Authorization: Basic $B64_TOKEN\""
else
    GIT_CMD="git"
fi

echo "🔍 Checking execution environment..."
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    PROJECT_DIR=$(git rev-parse --show-toplevel)
    cd "$PROJECT_DIR" || exit 1
    
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    echo "🏠 Running from within local repository: $PROJECT_DIR ($CURRENT_BRANCH)"
    echo "📥 Fetching latest upstream tree..."
    eval "$GIT_CMD fetch --all --prune"
    
    echo "🔄 Forcing workspace sync with remote origin repository..."
    eval "$GIT_CMD reset --hard origin/$CURRENT_BRANCH"
else
    PROJECT_DIR="$FALLBACK_PROJECT_DIR"
    echo "📂 Preparing project directory at $PROJECT_DIR..."
    
    if [ ! -d "$PROJECT_DIR" ]; then
        echo "📁 Creating missing fallback directories..."
        mkdir -p "$(dirname "$PROJECT_DIR")"
        
        echo "📦 Repository not found locally. Cloning cleanly..."
        eval "$GIT_CMD clone \"$REPO_URL\" \"$PROJECT_DIR\""
        cd "$PROJECT_DIR" || exit 1
    else
        cd "$PROJECT_DIR" || exit 1
        
        CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
        echo "📥 Fetching and applying latest code from GitHub..."
        eval "$GIT_CMD fetch --all --prune"
        eval "$GIT_CMD reset --hard origin/$CURRENT_BRANCH"
    fi
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
# 🆕 NEW: DEPLOYMENT POLICY SELECTOR MENU
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
rm -f "$POLICY_POLICY_FILE"

if [ $POLICY_EXIT -ne 0 ] || [ -z "$REBUILD_POLICY" ]; then
    clear
    echo "❌ Deployment cancelled."
    exit 0
fi

clear
ENV_NAME=$(basename "$SELECTED_PATH")
echo "🚀 Target Selected: $ENV_NAME [Policy: $REBUILD_POLICY]"

# 4. Conditional Teardown Pattern based on user choice
if [ "$REBUILD_POLICY" = "CLEAN" ]; then
    echo "🛑 CLEAN policy active: Tearing down active running containers..."
    RUNNING_CONTAINERS=$($DOCKER_CMD ps -a -q)
    if [ ! -z "$RUNNING_CONTAINERS" ]; then
        $DOCKER_CMD stop $RUNNING_CONTAINERS 2>/dev/null
        $DOCKER_CMD rm $RUNNING_CONTAINERS 2>/dev/null
    fi
fi

# 5. Navigate into the folder
cd "$PROJECT_DIR/$SELECTED_PATH" || exit 1


# =======================================================
# 🔐 ADVANCED SINGLE-SCREEN METADATA FORM INTERFACE
# =======================================================
if [ -f ".env.example" ] && [ ! -f ".env" ]; then
    echo "🔑 Processing unified configuration layout..."
    
    KEYS=()
    DEFAULTS=()
    DESCRIPTIONS=()
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
                KEYS+=("$KEY")
                DEFAULTS+=("$VAL")
                if [ -z "$CURRENT_COMMENT" ]; then
                    DESCRIPTIONS+=("No explanation provided.")
                else
                    DESCRIPTIONS+=("$CURRENT_COMMENT")
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
        FORM_FIELDS=()
        ROW_Y=1
        
        for i in "${!KEYS[@]}"; do
            DESC="${DESCRIPTIONS[$i]}"
            
            IFS=' ' read -r -a WORDS <<< "$DESC"
            LINE_BUFF="ℹ️ "
            for word in "${WORDS[@]}"; do
                if [ ${#LINE_BUFF} -gt 60 ]; then
                    FORM_FIELDS+=("$LINE_BUFF" "$ROW_Y" "2" "" "$ROW_Y" "2" "0" "0")
                    ((ROW_Y++))
                    LINE_BUFF="   "
                fi
                LINE_BUFF+="$word "
            done
            [ ! -z "$LINE_BUFF" ] && FORM_FIELDS+=("$LINE_BUFF" "$ROW_Y" "2" "" "$ROW_Y" "2" "0" "0")
            ((ROW_Y++))

            FORM_FIELDS+=(
                "👉 ${KEYS[$i]}:" "$ROW_Y" "2" \
                "${DEFAULTS[$i]}" "$ROW_Y" "22" \
                "45" "0"
            )
            ((ROW_Y+=2))
        done

        BOX_HEIGHT=$((ROW_Y + 4))
        [ $BOX_HEIGHT -gt 24 ] && BOX_HEIGHT=24
        
        TEMP_FORM_OUT=$(mktemp)
        
        dialog --clear \
               --title " Workspace Configuration: [$ENV_NAME] " \
               --form "Review descriptions inline. Use [UP/DOWN] to edit missing or default values:" \
               $BOX_HEIGHT 74 $((BOX_HEIGHT - 5)) "${FORM_FIELDS[@]}" 2> "$TEMP_FORM_OUT"
        
        EXIT_CODE=$?
        
        if [ $EXIT_CODE -eq 0 ]; then
            IFS=$'\n' read -d '' -r -a CAPTURED_USER_INPUTS < "$TEMP_FORM_OUT"
            rm -f "$TEMP_FORM_OUT"
            
            touch .env
            for i in "${!KEYS[@]}"; do
                echo "${KEYS[$i]}=${CAPTURED_USER_INPUTS[$i]}" >> .env
            done
            echo "✅ Finished compiling local environment properties profile."
        else
            rm -f "$TEMP_FORM_OUT"
            clear
            echo "❌ Deployment halted: Configuration dashboard requirements aborted."
            exit 1
        fi
    fi
fi
# =======================================================


# 6. ROUTING LOGIC & EXIT BOUNDARY CAPTURE
DEPLOY_SUCCESS=1

# Export variables down into custom run.sh files
export DOCKER_CMD
export REBUILD_POLICY

if [ -f "run.sh" ]; then
    echo "⚡ Custom run script detected! Executing run.sh..."
    chmod +x run.sh
    if [ "$DOCKER_CMD" = "sudo docker" ]; then
        sudo -E ./run.sh
    else
        ./run.sh
    fi
    DEPLOY_SUCCESS=$?

elif [ -f "docker-compose.yml" ]; then
    echo "🐳 Docker Compose file detected! Launching stack..."
    if [ "$REBUILD_POLICY" = "CLEAN" ]; then
        $DOCKER_CMD compose up --build --no-cache -d
    else
        $DOCKER_CMD compose up -d
    fi
    DEPLOY_SUCCESS=$?

elif [ -f "Dockerfile" ]; then
    echo "🛠️ Raw Dockerfile detected! Running basic automated fallback..."
    
    # Check if image exists before building under FAST strategy
    IMAGE_EXISTS=$($DOCKER_CMD images -q "$ENV_NAME:latest" 2>/dev/null)
    if [ "$REBUILD_POLICY" = "CLEAN" ] || [ -z "$IMAGE_EXISTS" ]; then
        $DOCKER_CMD build --no-cache -t "$ENV_NAME:latest" .
    fi
    
    if [ $? -eq 0 ]; then
        ENV_FLAGS=""
        if [ -f ".env" ]; then
            ENV_FLAGS="--env-file .env"
        fi
        
        # Ensure we clear a path for the run if CLEAN policy is chosen
        if [ "$REBUILD_POLICY" = "CLEAN" ]; then
            $DOCKER_CMD stop "$ENV_NAME" 2>/dev/null
            $DOCKER_CMD rm "$ENV_NAME" 2>/dev/null
        fi
        
        $DOCKER_CMD run -d --name "$ENV_NAME" $ENV_FLAGS --restart unless-stopped -p 80:80 "$ENV_NAME:latest"
        DEPLOY_SUCCESS=$?
    else
        DEPLOY_SUCCESS=1
    fi
fi

if [ $DEPLOY_SUCCESS -ne 0 ]; then
    echo "❌ ERROR: Deployment task failed for [$ENV_NAME]. Review the terminal logs above."
    exit 1
fi

# 7. Image Sweep (Only prune if clean policy requested)
if [ "$REBUILD_POLICY" = "CLEAN" ]; then
    echo "🧹 CLEAN policy active: Sweeping unused cache layers..."
    $DOCKER_CMD image prune -a -f
fi

echo "✅ Environment [$ENV_NAME] successfully deployed!"