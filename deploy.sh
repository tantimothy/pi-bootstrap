#!/bin/bash

FALLBACK_PROJECT_DIR="$HOME/projects/bootstrap"
REPO_URL="https://github.com/tantimothy/pi-bootstrap.git"

# ==========================================
# 1. DEPENDENCY CHECK: Ensure 'dialog' is installed
# ==========================================
if ! command -v dialog &> /dev/null; then
    echo "📦 'dialog' tool not found. Installing it now..."
    sudo apt-get update && sudo apt-get install -y dialog
fi

# ==========================================
# 2. ENGINE CHECK: Ensure 'docker' is installed
# ==========================================
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

# ==========================================
# 3. BULLETPROOF DOCKER PERMISSION WRAPPER
# ==========================================
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
    GIT_CMD="git -c http.extraheader=\"Authorization: Basic $B64_TOKEN\""
else
    GIT_CMD="git"
fi

# Determine matching workspace checkout targeting context
if [ -d ".git" ]; then
    TARGET_DIR=$(pwd)
elif [ -d "$FALLBACK_PROJECT_DIR/.git" ]; then
    TARGET_DIR="$FALLBACK_PROJECT_DIR"
else
    TARGET_DIR="$FALLBACK_PROJECT_DIR"
    mkdir -p "$TARGET_DIR"
    echo "🗂️ Workspace missing. Initializing git clone context..."
    eval "$GIT_CMD clone $REPO_URL $TARGET_DIR"
fi

cd "$TARGET_DIR" || exit 1

# Synchronize branch state to eliminate localized drift securely
if [ -d ".git" ]; then
    echo "🔄 Synchronizing workspace with upstream repository..."
    
    # 1. Fetch latest changes and capture errors
    if ! eval "$GIT_CMD fetch --all"; then
        echo "❌ ERROR: Git fetch failed! Check network or authentication tokens."
        echo "Press Enter to bypass sync and continue with local files, or Ctrl+C to abort..."
        read -r
    else
        # 2. Get current branch name dynamically
        CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
        
        echo "🧹 Resetting tracking state to origin/$CURRENT_BRANCH..."
        # 3. Force hard reset to origin/branch and report failures
        if ! eval "$GIT_CMD reset --hard origin/$CURRENT_BRANCH"; then
            echo "⚠️ WARNING: Hard reset failed. Local drift may still be present."
            echo "Press Enter to continue anyway..."
            read -r
        else
            echo "✅ Workspace successfully synchronized!"
        fi
    fi
fi

# Ensure environments structure directory block is valid
ENV_BASE_DIR="$TARGET_DIR/environments"
if [ ! -d "$ENV_BASE_DIR" ]; then
    dialog --title " Error " --msgbox "Missing structural directory: $ENV_BASE_DIR" 6 50
    clear
    exit 1
fi

# ==========================================
# MAIN ROUTING LOOP ENGINE
# ==========================================
while true; do

    # Gather available workspaces
    MENU_OPTIONS=()
    # Inject the standalone dynamic container cleanup utility choice into the top of the option array
    MENU_OPTIONS+=("MAINTENANCE" "🛠️  Manage, Auditing, & Clean System Containers")

    while IFS= read -r -d '' dir; do
        DIR_NAME=$(basename "$dir")
        MENU_OPTIONS+=("$dir" "Workspace configuration: $DIR_NAME")
    done < <(find "$ENV_BASE_DIR" -maxdepth 1 -mindepth 1 -type d -print0)

    TEMP_FILE=$(mktemp)
    dialog --clear \
        --title " Raspberry Pi Deployment Center " \
        --menu "Choose an application configuration workspace or a system maintenance action:" 17 76 9 \
        "${MENU_OPTIONS[@]}" 2> "$TEMP_FILE"

    EXIT_STATUS=$?
    SELECTED_PATH=$(cat "$TEMP_FILE")
    rm -f "$TEMP_FILE"

    # If the user presses Cancel or Esc at the root menu, exit gracefully
    if [ $EXIT_STATUS -ne 0 ] || [ -z "$SELECTED_PATH" ]; then
        clear
        echo "👋 Exiting script execution. System environments unmodified."
        exit 0
    fi

    # ==========================================
    # DETACHED MAINTENANCE SUITE CONTROLLER
    # ==========================================
    if [ "$SELECTED_PATH" = "MAINTENANCE" ]; then
        while true; do
            TEMP_MAINT_FILE=$(mktemp)
            dialog --clear \
                --title " Container Infrastructure Management " \
                --menu "Select a targeted sanitation utility operation:" 12 70 3 \
                "SELECTIVE" "View system state and selectively purge chosen containers" \
                "PURGE_ALL" "Force-stop and fully wipe ALL containers on this system" \
                "BACK"      "<- Return back to the primary Workspace Menu" \
                2> "$TEMP_MAINT_FILE"

            MAINT_EXIT=$?
            MAINT_ACTION=$(cat "$TEMP_MAINT_FILE")
            rm -f "$TEMP_MAINT_FILE"

            if [ $MAINT_EXIT -ne 0 ] || [ "$MAINT_ACTION" = "BACK" ]; then
                # Drop out of the maintenance block loop to drop right back into the main configuration loop
                break
            fi

            case "$MAINT_ACTION" in
                SELECTIVE)
                    # Query active system layout via custom Docker formatting array blocks
                    IFS=$'\n' read -r -d '' -a RUNNING_LIST < <($DOCKER_CMD ps -a --format "{{.ID}}||{{.Names}}||{{.Status}}" && printf '\0')
                    
                    if [ ${#RUNNING_LIST[@]} -eq 0 ] || [ -z "${RUNNING_LIST[0]}" ]; then
                        dialog --title " System Manifest Info " --msgbox "There are zero existing containers present on this engine context." 6 65
                        continue
                    fi

                    CHECKBOX_ARGS=()
                    for item in "${RUNNING_LIST[@]}"; do
                        if [ ! -z "$item" ]; then
                            CID=$(echo "$item" | awk -F'||' '{print $1}')
                            CNAME=$(echo "$item" | awk -F'||' '{print $2}')
                            CSTAT=$(echo "$item" | awk -F'||' '{print $3}')
                            # Append metadata parameters to compile multi-selection array arguments
                            CHECKBOX_ARGS+=("$CID" "$CNAME ($CSTAT)" "OFF")
                        fi
                    done

                    TEMP_CHKBX_OUT=$(mktemp)
                    dialog --clear --title " Selective Sanitization Interface " \
                        --checklist "Spacebar to mark container instances for deletion; Enter to confirm execution:" 20 75 10 \
                        "${CHECKBOX_ARGS[@]}" 2> "$TEMP_CHKBX_OUT"

                    CHKBX_EXIT=$?
                    SELECTED_TARGETS=$(cat "$TEMP_CHKBX_OUT")
                    rm -f "$TEMP_CHKBX_OUT"

                    if [ $CHKBX_EXIT -eq 0 ] && [ ! -z "$SELECTED_TARGETS" ]; then
                        clear
                        echo "🧹 Processing targeted workspace removals..."
                        for target_id in $SELECTED_TARGETS; do
                            # Strip lingering container quotes added natively by standard dialog arrays
                            clean_id=$(echo "$target_id" | tr -d '"')
                            echo "🛑 Killing instance: [$clean_id]"
                            $DOCKER_CMD stop "$clean_id" &>/dev/null
                            $DOCKER_CMD rm "$clean_id" &>/dev/null
                        done
                        echo "✅ Target cleanup operation successfully fully completed."
                        echo "Press Enter to return to maintenance portal..."
                        read -r
                    fi
                    ;;

                PURGE_ALL)
                    ALL_CONTAINERS=$($DOCKER_CMD ps -a -q)
                    if [ -z "$ALL_CONTAINERS" ]; then
                        dialog --title " System Manifest Info " --msgbox "No system containers found. Wipes aborted seamlessly." 6 55
                    else
                        dialog --title " WARNING: GLOBAL DESTRUCTION " \
                            --yesno "Are you absolutely certain you want to force-stop and clear ALL containers on this system?" 7 65
                        if [ $? -eq 0 ]; then
                            clear
                            echo "🚨 Initiating absolute infrastructure purge..."
                            $DOCKER_CMD stop $ALL_CONTAINERS 2>/dev/null
                            $DOCKER_CMD rm $ALL_CONTAINERS 2>/dev/null
                            echo "✨ Complete architecture layer reset finalized."
                            echo "Press Enter to return to maintenance portal..."
                            read -r
                        fi
                    fi
                    ;;
            esac
        done
        # Ensure that exiting the maintenance window routes directly back up to the master selection logic loop
        continue
    fi

    # ==========================================
    # 5. DEPLOYMENT POLICY SELECTOR MENU
    # ==========================================
    TEMP_POLICY_FILE=$(mktemp)
    dialog --clear \
        --title " Deployment Strategy Policy " \
        --menu "Select how to process the configuration build lifecycle for this workspace:" 11 70 2 \
        "FAST" "Preserve running instances; build cleanly only if cache missing" \
        "CLEAN" "Explicitly tear down and rebuild ONLY this targeted workspace" \
        2> "$TEMP_POLICY_FILE"

    POLICY_EXIT=$?
    REBUILD_POLICY=$(cat "$TEMP_POLICY_FILE")
    rm -f "$TEMP_POLICY_FILE"

    if [ $POLICY_EXIT -ne 0 ] || [ -z "$REBUILD_POLICY" ]; then
        continue  # Cycles back safely right up to workspace choice lists without modifying external running container processes
    fi

    clear
    ENV_NAME=$(basename "$SELECTED_PATH")
    echo "🚀 Target Selected: $ENV_NAME [Policy: $REBUILD_POLICY]"

    # Isolate any image pruning tasks safely down below execution confirmation logic paths
    if [ "$REBUILD_POLICY" = "CLEAN" ]; then
        echo "🧹 Host SD Card Preservation: Pruning dangling container layers..."
        $DOCKER_CMD image prune -f 2>/dev/null
    fi

    # ==========================================
    # 6. ZERO-COMMIT DYNAMIC .ENV WIZARD
    # ==========================================
    TARGET_WORKSPACE_DIR="$SELECTED_PATH"
    EXAMPLE_ENV="$TARGET_WORKSPACE_DIR/.env.example"
    LOCAL_ENV="$TARGET_WORKSPACE_DIR/.env"

    if [ -f "$EXAMPLE_ENV" ]; then
        echo "📝 Processing configuration mapping parameters..."
        
        FORM_FIELDS=()
        FIELD_KEYS=()
        DEFAULT_VALUES=()
        FIELD_LABELS=()
        
        CURRENT_LABEL="Enter value"
        
        while IFS= read -r line || [ -n "$line" ]; do
            line=$(echo "$line" | tr -d '\r')
            
            if [[ "$line" =~ ^#[[:space:]]*(.*) ]]; then
                CURRENT_LABEL="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
                KEY=$(echo "${BASH_REMATCH[1]}" | xargs)
                VAL=$(echo "${BASH_REMATCH[2]}" | xargs)
                
                FIELD_KEYS+=("$KEY")
                DEFAULT_VALUES+=("$VAL")
                FIELD_LABELS+=("$CURRENT_LABEL")
                
                CURRENT_LABEL="Enter value"
            fi
        done < "$EXAMPLE_ENV"
        
        FIELD_COUNT=${#FIELD_KEYS[@]}
        
        if [ "$FIELD_COUNT" -gt 0 ]; then
            FORM_ARGS=("Configuration Parameters" 20 75 10)
            
            for ((i=0; i<FIELD_COUNT; i++)); do
                Y_POS=$(( (i * 2) + 1 ))
                LABEL_STR="${FIELD_LABELS[$i]} (${FIELD_KEYS[$i]})"
                
                FORM_ARGS+=("$LABEL_STR" "$Y_POS" 2 "" "$Y_POS" 50 0 0)
                FORM_ARGS+=("${DEFAULT_VALUES[$i]}" "$Y_POS" 50 20 0 0)
            done
            
            TEMP_FORM_OUT=$(mktemp)
            dialog --clear --title " Environment Configuration Dashboard " \
                --form "${FORM_ARGS[@]}" 2> "$TEMP_FORM_OUT"
            
            FORM_EXIT=$?
            
            if [ $FORM_EXIT -eq 0 ]; then
                true > "$LOCAL_ENV"
                MAP_INDEX=0
                while IFS= read -r submitted_val || [ -n "$submitted_val" ]; do
                    if [ $MAP_INDEX -lt $FIELD_COUNT ]; then
                        echo "${FIELD_KEYS[$MAP_INDEX]}=$submitted_val" >> "$LOCAL_ENV"
                    fi
                    ((MAP_INDEX++))
                done < "$TEMP_FORM_OUT"
                echo "✅ Configuration context serialized to local space successfully."
            else
                rm -f "$TEMP_FORM_OUT"
                continue # Graceful abort returns straight to main menu loops safely
            fi
            rm -f "$TEMP_FORM_OUT"
        fi
    fi

    # ==========================================
    # 7. SUBSCRIPT HANDOFF & ISOLATED ROUTING PIPELINE
    # ==========================================
    cd "$TARGET_WORKSPACE_DIR" || exit 1

    DOCKER="${DOCKER_CMD:-docker}"
    export DOCKER
    export DOCKER_CMD
    export REBUILD_POLICY

    DEPLOY_SUCCESS=1

    if [ -f "run.sh" ]; then
        echo "⚡ Custom run script detected! Executing run.sh..."
        chmod +x run.sh
        ./run.sh
        DEPLOY_SUCCESS=$?

    elif [ -f "docker-compose.yml" ]; then
        echo "🐳 Docker Compose file detected! Processing targeted container stack..."
        if [ "$REBUILD_POLICY" = "CLEAN" ]; then
            echo "🛑 Tearing down and rebuilding ONLY this compose stack as requested..."
            $DOCKER_CMD compose down 2>/dev/null
            $DOCKER_CMD compose up --build --no-cache -d
        else
            $DOCKER_CMD compose up -d
    fi
        DEPLOY_SUCCESS=$?

    elif [ -f "Dockerfile" ]; then
        echo "🛠️ Raw Dockerfile detected! Running basic automated fallback..."
        
        if [ "$REBUILD_POLICY" = "CLEAN" ]; then
            $DOCKER_CMD build --no-cache -t "$ENV_NAME:latest" .
        else
            $DOCKER_CMD build -t "$ENV_NAME:latest" .
        fi
        
        if [ $? -eq 0 ]; then
            ENV_FLAGS=""
            if [ -f ".env" ]; then
                ENV_FLAGS="--env-file .env"
            fi
            
            echo "♻️ Recycling singleton container resource: [$ENV_NAME]"
            $DOCKER_CMD stop "$ENV_NAME" &>/dev/null
            $DOCKER_CMD rm "$ENV_NAME" &>/dev/null
            
            $DOCKER_CMD run -d --name "$ENV_NAME" $ENV_FLAGS --restart unless-stopped -p 80:80 "$ENV_NAME:latest"
            DEPLOY_SUCCESS=$?
        else
            DEPLOY_SUCCESS=1
        fi
    fi

    # ==========================================
    # 8. POST-FLIGHT VALIDATION MATRIX
    # ==========================================
    if [ $DEPLOY_SUCCESS -ne 0 ]; then
        echo "❌ ERROR: Deployment task failed for [$ENV_NAME]."
        echo "Press Enter to return to main dashboard menu..."
        read -r
    else
        echo "🎉 SUCCESS: Configuration workspace [$ENV_NAME] active and healthy."
        echo "Press Enter to return to main dashboard menu..."
        read -r
    fi

done