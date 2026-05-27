#!/bin/bash

FALLBACK_PROJECT_DIR="$HOME/bootstrap"
REPO_URL="https://github.com/tantimothy/pi-bootstrap.git"

if ! command -v dialog &> /dev/null; then
    echo "📦 'dialog' tool not found. Installing it now..."
    sudo apt-get update && sudo apt-get install -y dialog
fi

# Extract token if passed via curl context to handle private repo cloning automatically
# This checks if a token was used during user authentication in the active shell process
TOKEN=$(echo "$CURL_USER" | cut -d':' -f2)

echo "🔍 Checking execution environment..."
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    PROJECT_DIR=$(git rev-parse --show-toplevel)
    cd "$PROJECT_DIR" || exit 1
    echo "🏠 Running from within local repository: $PROJECT_DIR"
    echo "📥 Fetching latest code from GitHub..."
    git fetch --all
else
    PROJECT_DIR="$FALLBACK_PROJECT_DIR"
    echo "📂 Preparing project directory at $PROJECT_DIR..."
    
    if [ ! -d "$PROJECT_DIR" ]; then
        echo "📁 Creating missing fallback directories..."
        # Safely create all parent folders recursively
        mkdir -p "$(dirname "$PROJECT_DIR")"
        
        echo "📦 Repository not found locally. Cloning for the first time..."
        # If a token was provided in the curl wrapper, use it to authenticate the clone
        if [ ! -z "$TOKEN" ]; then
            AUTH_REPO_URL=$(echo "$REPO_URL" | sed "s/https:\/\//https:\/\/${TOKEN}@/")
            git clone "$AUTH_REPO_URL" "$PROJECT_DIR"
        else
            git clone "$REPO_URL" "$PROJECT_DIR"
        fi
        
        cd "$PROJECT_DIR" || exit 1
    else
        cd "$PROJECT_DIR" || exit 1
        echo "📥 Fetching latest code from GitHub..."
        git fetch --all
        # Optional: uncomment to force overwrite local files
        # git reset --hard origin/main
    fi
fi

# Double check that we are working from the normalized absolute base directory
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

# 1. Dynamic Scan
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

# 2. Build menu options
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

# 3. Present the Menu
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

clear
ENV_NAME=$(basename "$SELECTED_PATH")
echo "🚀 Target Selected: $ENV_NAME"

# 4. Universal Teardown Pattern
echo "🛑 Tearing down active running containers across the system..."
docker stop $(docker ps -a -q) 2>/dev/null
docker rm $(docker ps -a -q) 2>/dev/null

# 5. Navigate into the folder
cd "$PROJECT_DIR/$SELECTED_PATH" || exit 1

# 6. ROUTING LOGIC
if [ -f "run.sh" ]; then
    echo "⚡ Custom run script detected! Executing run.sh..."
    chmod +x run.sh
    ./run.sh
elif [ -f "docker-compose.yml" ]; then
    echo "🐳 Docker Compose file detected! Launching stack..."
    docker compose up --build -d
elif [ -f "Dockerfile" ]; then
    echo "🛠️ Raw Dockerfile detected! Running basic automated fallback..."
    docker build -t "$ENV_NAME:latest" .
    docker run -d --name "$ENV_NAME" --restart unless-stopped -p 80:80 "$ENV_NAME:latest"
fi

# 7. Image Sweep
echo "🧹 Sweeping unused cache layers..."
docker image prune -a -f

echo "✅ Environment [$ENV_NAME] successfully deployed!"