#!/usr/bin/env bash
# Shared archetype-aware deploy/redeploy mechanics for a single environment
# directory. Two callers:
#   - deploy.sh (interactive TUI): gathers environment/policy/.env config
#     via dialogs, then calls deploy_environment to actually do it.
#   - check-updates.sh --apply: targets one single-container environment's
#     own CLEAN directly, no TUI involved — this is exactly why the logic
#     lives here instead of inside deploy.sh itself; a script driving
#     deploy.sh's own dialogs non-interactively would be far more awkward
#     than both callers sharing the actual mechanics directly.
#
# deploy_environment <env_dir> <policy> [docker_cmd]
#   env_dir    — absolute path to the environment directory
#   policy     — FAST | STOP | TEARDOWN | CLEAN
#   docker_cmd — defaults to "docker" (pass "sudo docker" etc. as needed)
#
# Prints progress to stdout as it goes. Returns 0 on success, non-zero on
# failure. Does NOT handle INFO/WIPE (those delegate directly to that
# environment's own info.sh, unrelated to "deploying") or the .env
# configuration form (TUI-only — this assumes .env, if the environment
# needs one, is already in place before it's called).
deploy_environment() {
    local env_dir="$1" policy="$2" docker_cmd="${3:-docker}"
    local env_name; env_name="$(basename "$env_dir")"

    (
        cd "$env_dir" || exit 1

        # 🔍 Container identification — .env override, else the folder name.
        local tracking_name="$env_name"
        if [ -f ".env" ] && grep -q "^CONTAINER_NAME=" .env; then
            tracking_name=$(grep "^CONTAINER_NAME=" .env | cut -d'=' -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        elif [ -f ".env.example" ] && grep -q "^CONTAINER_NAME=" .env.example; then
            tracking_name=$(grep "^CONTAINER_NAME=" .env.example | cut -d'=' -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        fi

        # Pre-create data directories (as the invoking user) before Docker
        # ever touches them as a bind-mount target — generic fallback only
        # (no run.sh), since every run.sh already does this itself, and
        # only for FAST/CLEAN, since STOP/TEARDOWN never create anything.
        if [ ! -f "run.sh" ] && [ -f "info.sh" ] && { [ "$policy" = "FAST" ] || [ "$policy" = "CLEAN" ]; }; then
            while IFS= read -r dir; do
                [ -n "$dir" ] && mkdir -p "$dir"
            done < <(bash info.sh list-dirs 2>/dev/null)
        fi

        if [ -f "run.sh" ]; then
            echo "⚡ Custom run script detected! Executing run.sh..."
            chmod +x run.sh
            export REBUILD_POLICY="$policy"
            export DOCKER_CMD="$docker_cmd"
            ./run.sh
            exit $?

        elif [ -f "docker-compose.yml" ]; then
            case "$policy" in
                STOP)
                    echo "🛑 [STOP] Pausing Docker Compose stack (containers preserved)..."
                    $docker_cmd compose stop 2>/dev/null || true
                    exit 0
                    ;;
                TEARDOWN)
                    echo "🗑️  [TEARDOWN] Stopping and removing Docker Compose stack..."
                    $docker_cmd compose down 2>/dev/null || true
                    exit 0
                    ;;
                CLEAN)
                    echo "🐳 Docker Compose file detected [CLEAN]! Pulling/building fresh images before touching anything running..."
                    $docker_cmd compose pull 2>/dev/null
                    if $docker_cmd compose build --no-cache; then
                        echo "🛑 Fresh images ready — tearing down and relaunching..."
                        $docker_cmd compose down 2>/dev/null || true
                        $docker_cmd compose up -d
                        rc=$?
                        # --no-cache retags over the previous image, leaving
                        # it dangling. -f only removes untagged images,
                        # never anything still referenced by a container.
                        $docker_cmd image prune -f >/dev/null 2>&1 || true
                        exit $rc
                    else
                        echo "❌ Build failed — leaving the existing stack untouched."
                        exit 1
                    fi
                    ;;
                *)
                    echo "🐳 Docker Compose file detected [FAST]! Synchronizing stack changes using cached layer parameters..."
                    $docker_cmd compose up -d
                    exit $?
                    ;;
            esac

        elif [ -f "Dockerfile" ]; then
            case "$policy" in
                STOP)
                    echo "🛑 [STOP] Pausing container: $tracking_name"
                    $docker_cmd stop "$tracking_name" 2>/dev/null || true
                    exit 0
                    ;;
                TEARDOWN)
                    echo "🗑️  [TEARDOWN] Stopping and removing container: $tracking_name"
                    $docker_cmd stop "$tracking_name" 2>/dev/null || true
                    $docker_cmd rm   "$tracking_name" 2>/dev/null || true
                    exit 0
                    ;;
                CLEAN)
                    echo "🛠️ Raw Dockerfile detected [CLEAN]! Building fresh image before touching the running container..."
                    if $docker_cmd build --no-cache -t "${env_name}:latest" .; then
                        echo "🛑 Fresh image ready — tearing down previous container..."
                        $docker_cmd stop "$tracking_name" 2>/dev/null || true
                        $docker_cmd rm   "$tracking_name" 2>/dev/null || true
                        env_flags=""
                        [ -f ".env" ] && env_flags="--env-file .env"
                        $docker_cmd run -d --name "$tracking_name" $env_flags --restart unless-stopped -p 80:80 "${env_name}:latest"
                        rc=$?
                        $docker_cmd image prune -f >/dev/null 2>&1 || true
                        exit $rc
                    else
                        exit 1
                    fi
                    ;;
                *)
                    echo "🛠️ Raw Dockerfile detected [FAST]! Checking execution context rules..."
                    if $docker_cmd ps --format '{{.Names}}' | grep -q "^${tracking_name}$"; then
                        echo "✅ Container '$tracking_name' is active. Preserving application uptime status!"
                        exit 0
                    elif $docker_cmd ps -a --format '{{.Names}}' | grep -q "^${tracking_name}$"; then
                        echo "🔄 Container '$tracking_name' is dormant. Triggering pipeline startup recovery..."
                        $docker_cmd start "$tracking_name"
                        exit $?
                    else
                        echo "🛠️ Container sequence vacant. Building image and provisioning environment layers..."
                        if $docker_cmd build -t "${env_name}:latest" .; then
                            env_flags=""
                            [ -f ".env" ] && env_flags="--env-file .env"
                            $docker_cmd run -d --name "$tracking_name" $env_flags --restart unless-stopped -p 80:80 "${env_name}:latest"
                            exit $?
                        else
                            exit 1
                        fi
                    fi
                    ;;
            esac
        else
            echo "❌ No run.sh, docker-compose.yml, or Dockerfile found in $env_dir" >&2
            exit 1
        fi
    )
    local deploy_success=$?

    # Best-effort desktop-entry refresh for the generic docker-compose.yml/
    # Dockerfile fallback path only — every environment with its own
    # run.sh already does this itself at the end of run.sh, so doing it
    # again here would just be redundant (harmless, but pointless) work
    # for those.
    if [ $deploy_success -eq 0 ] && [ ! -f "$env_dir/run.sh" ] && [ -x "$env_dir/install-desktop.sh" ]; then
        ( cd "$env_dir" && bash install-desktop.sh >/dev/null 2>&1 || true )
    fi

    return $deploy_success
}
