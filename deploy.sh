#!/bin/bash

FALLBACK_PROJECT_DIR="$HOME/bootstrap"
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

# 3. DOCKER PERMISSION CHECK WRAPPER
# Check if the current user can actually read/write to the docker daemon socket.
# If they cannot, we must prepend 'sudo' to avoid the permission denied crash.
DOCKER_CMD="docker"
if [ ! -w /var/run/docker.sock ]; then
    echo "🔒 Elevated socket permissions required. Using 'sudo docker' wrapper..."
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
    echo "🏠 Running from within local repository: $PROJECT_DIR"
    echo "📥 Fetching and applying latest code from GitHub..."
    eval "$GIT_CMD fetch --all"
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
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
        echo "📥 Fetching and applying latest code from GitHub..."
        eval "$GIT_CMD fetch --all"
        eval "$GIT_CMD reset --hard origin/main"
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

clear
ENV_NAME=$(basename "$SELECTED_PATH")
echo "🚀 Target Selected: $ENV_NAME"

# 4. Universal Teardown Pattern
echo "🛑 Tearing down active running containers across the system..."
$DOCKER_CMD stop $($DOCKER_CMD ps -a -q) 2>/dev/null
$DOCKER_CMD rm $($DOCKER_CMD ps -a -q) 2>/dev/null

# 5. Navigate into the folder
cd "$PROJECT_DIR/$SELECTED_PATH" || exit 1

# 6. ROUTING LOGIC
if [ -f "run.sh" ]; then
    echo "⚡ Custom run script detected! Executing run.sh..."
    chmod +x run.sh
    # Note: If your custom run.sh contains individual docker calls inside, 
    # ensure you either use sudo inside it or restart your SSH session to initialize user group profiles.
    ./run.sh
elif [ -f "docker-compose.yml" ]; then
    echo "🐳 Docker Compose file detected! Launching stack..."
    $DOCKER_CMD compose up --build -d
elif [ -f "Dockerfile" ]; then
    echo "🛠️ Raw Dockerfile detected! Running basic automated fallback..."
    $DOCKER_CMD build -t "$ENV_NAME:latest" .
    $DOCKER_CMD run -d --name "$ENV_NAME" --restart unless-stopped -p 80:80 "$ENV_NAME:latest"
fi

# 7. Image Sweep
echo "🧹 Sweeping unused cache layers..."
$DOCKER_CMD image prune -a -f

echo "✅ Environment [$ENV_NAME] successfully deployed!"