#!/bin/bash

FALLBACK_PROJECT_DIR="$HOME/bootstrap"
REPO_URL="https://github.com/tantimothy/pi-bootstrap.git"

if ! command -v dialog &> /dev/null; then
    echo "📦 'dialog' tool not found. Installing it now..."
    sudo apt-get update && sudo apt-get install -y dialog
fi

echo "🔍 Checking execution environment..."
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    PROJECT_DIR=$(git rev-parse --show-toplevel)
    cd "$PROJECT_DIR" || exit 1
    echo "🏠 Running from within local repository: $PROJECT_DIR"
    echo "📥 Fetching latest code from GitHub..."
    git fetch --all
else
    PROJECT_DIR="$FALLBACK_PROJECT_DIR"
    if [ ! -d "$PROJECT_DIR" ]; then
        git clone "$REPO_URL" "$PROJECT_DIR"
        cd "$PROJECT_DIR" || exit 1
    else
        cd "$PROJECT_DIR" || exit 1
        git fetch --all
        git reset --hard origin/main
    fi
fi

# 1. Dynamic Scan: Find any folder inside 'environments/' 
# This looks exactly 1 level deep inside the environments folder
ENV_DIRS=( $(find environments -maxdepth 1 -mindepth 1 -type d) )

if [ ${#ENV_DIRS[@]} -eq 0 ]; then
    dialog --title " Error " --msgbox "No deployment folders found in environments/ !" 8 50
    clear
    exit 1
fi

# 2. Build the dynamic menu options
MENU_OPTIONS=()
for dir in "${ENV_DIRS[@]}"; do
    folder_name=$(basename "$dir")
    
    # Check what kind of project it is to label it nicely in the menu
    if [ -f "$dir/run.sh" ]; then
        TYPE="[Custom run.sh]"
    elif [ -f "$dir/docker-compose.yml" ]; then
        TYPE="[Docker Compose]"
    elif [ -f "$dir/Dockerfile" ]; then
        TYPE="[Standalone Dockerfile]"
    else
        TYPE="[Empty/Invalid]"
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

# 6. ROUTING LOGIC: Determine deployment style based on available files
if [ -f "run.sh" ]; then
    echo "⚡ Custom run script detected! Executing run.sh..."
    chmod +x run.sh
    ./run.sh

elif [ -f "docker-compose.yml" ]; then
    echo "🐳 Docker Compose file detected! Launching stack..."
    docker compose up --build -d

elif [ -f "Dockerfile" ]; then
    echo "🛠️ Raw Dockerfile detected! Running basic automated fallback..."
    # Builds an image named after the folder, runs it mapping port 80 to 80
    docker build -t "$ENV_NAME:latest" .
    docker run -d --name "$ENV_NAME" --restart unless-stopped -p 80:80 "$ENV_NAME:latest"

else
    echo "❌ Error: No valid run.sh, docker-compose.yml, or Dockerfile found in this directory."
    exit 1
fi

# 7. Image Sweep
echo "🧹 Sweeping unused cache layers..."
docker image prune -a -f

echo "✅ Environment [$ENV_NAME] successfully deployed!"
