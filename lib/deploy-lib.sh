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
# Prints progress to stdout as it goes (and durably records the whole
# session to environments/<env>/logs/ — see _run_logged below). Returns 0
# on success, non-zero on failure. Does NOT handle INFO/WIPE (those
# delegate directly to that environment's own info.sh, unrelated to
# "deploying") or the .env configuration form (TUI-only — this assumes
# .env, if the environment needs one, is already in place before it's
# called).

# Runs a command inside a real pty via `script`, so fully-interactive
# sub-programs that reattach directly to /dev/tty (e.g. nanoclaw/
# nanoclaw-mnemon's own setup wizard, handed off via `docker exec -it`)
# still work exactly as if run directly — output still appears live on
# the real terminal — while everything is also durably recorded to $1. A
# plain pipe/tee wrapper can't do this: anything that does its own
# `exec 1>/dev/tty` breaks straight out of a pipe, which is exactly the
# part of a deploy most likely to be the one thing worth reviewing after
# a failure (verified directly: text written after such a reattach still
# lands in the log file here).
#
# GNU/util-linux script (Linux) and BSD script (macOS) have incompatible
# CLI syntax (-c "one whole command string" vs positional command args)
# AND incompatible exit-code propagation (GNU has -e/--return; BSD has no
# equivalent, and even GNU's reported COMMAND_EXIT_CODE reflects the outer
# wrapper, not reliably the real command) — handled uniformly here by
# wrapping the real command in its own `bash -c` that writes its own $? to
# a sentinel file from inside the pty session itself, read back after
# script exits either way, rather than trusting either script flavor's
# own exit status.
#
# Falls back to running the command directly (no log, but no behavior
# change) if `script` isn't installed at all — logging is a nice-to-have,
# never a reason to block a real deploy.
_run_logged() {
    local log_file="$1"; shift
    if ! command -v script &>/dev/null; then
        "$@"
        return $?
    fi

    local exit_file; exit_file=$(mktemp)
    local inner
    inner=$(printf '%q ' "$@")
    inner="${inner% }; printf '%s' \$? > $(printf '%q' "$exit_file")"

    if script --version 2>&1 | grep -qi "util-linux"; then
        script -q -c "bash -c $(printf '%q' "$inner")" "$log_file"
    else
        script -q "$log_file" bash -c "$inner"
    fi

    local rc=1
    [ -s "$exit_file" ] && rc=$(cat "$exit_file")
    rm -f "$exit_file"
    return "${rc:-1}"
}

# A nested interactive sub-program (nanoclaw/nanoclaw-mnemon's setup wizard,
# handed off via `docker exec -it`, itself its own pty) can exit without
# restoring the controlling terminal to normal line-buffered (canonical)
# mode, and/or leave stray bytes sitting in the input queue. Left alone,
# the very next `read -rp "Press Enter..."` back in deploy.sh either
# returns instantly on that leftover input (looks like the menu "flashing
# by" with no chance to read the status) or misinterprets a single raw
# keystroke as the whole answer. Call this right after any such handoff,
# before prompting the user for anything, to guarantee the next read
# actually waits for a real Enter press.
#
# `-t` must be a whole number of seconds: macOS's bash (3.2) rejects a
# fractional timeout outright ("invalid timeout specification") rather
# than just rounding it, unlike GNU bash — confirmed on a real Mac.
_reset_tty_input() {
    [ -t 0 ] || return 0
    stty sane 2>/dev/null || true
    local _drain_junk
    while read -r -t 1 _drain_junk; do :; done
    return 0
}

# The actual per-archetype deploy logic, split out of deploy_environment so
# it can run inside _run_logged's own `bash -c` (a genuinely separate
# process, spawned by `script` — local-scope closures over deploy_
# environment's own variables wouldn't survive that, so every input is a
# positional arg instead, and this must be `export -f`'d for the new
# process to see it at all).
_deploy_environment_body() {
    local env_dir="$1" policy="$2" docker_cmd="$3" repo_dir="$4" env_name
    env_name="$(basename "$env_dir")"
    cd "$env_dir" || return 1

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
    if [ ! -f "run.sh" ] && { [ -f "info.sh" ] || [ -f "info.yaml" ]; } && { [ "$policy" = "FAST" ] || [ "$policy" = "CLEAN" ]; }; then
        while IFS= read -r dir; do
            [ -n "$dir" ] && mkdir -p "$dir"
        done < <(bash "$repo_dir/lib/run-info.sh" "$env_dir" list-dirs 2>/dev/null)
    fi

    if [ -f "run.sh" ]; then
        echo "⚡ Custom run script detected! Executing run.sh..."
        chmod +x run.sh
        export REBUILD_POLICY="$policy"
        export DOCKER_CMD="$docker_cmd"
        ./run.sh
        return $?

    elif [ -f "docker-compose.yml" ]; then
        case "$policy" in
            STOP)
                echo "🛑 [STOP] Pausing Docker Compose stack (containers preserved)..."
                $docker_cmd compose stop 2>/dev/null || true
                return 0
                ;;
            TEARDOWN)
                echo "🗑️  [TEARDOWN] Stopping and removing Docker Compose stack..."
                $docker_cmd compose down 2>/dev/null || true
                return 0
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
                    return $rc
                else
                    echo "❌ Build failed — leaving the existing stack untouched."
                    return 1
                fi
                ;;
            *)
                echo "🐳 Docker Compose file detected [FAST]! Synchronizing stack changes using cached layer parameters..."
                $docker_cmd compose up -d
                return $?
                ;;
        esac

    elif [ -f "Dockerfile" ]; then
        case "$policy" in
            STOP)
                echo "🛑 [STOP] Pausing container: $tracking_name"
                $docker_cmd stop "$tracking_name" 2>/dev/null || true
                return 0
                ;;
            TEARDOWN)
                echo "🗑️  [TEARDOWN] Stopping and removing container: $tracking_name"
                $docker_cmd stop "$tracking_name" 2>/dev/null || true
                $docker_cmd rm   "$tracking_name" 2>/dev/null || true
                return 0
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
                    return $rc
                else
                    return 1
                fi
                ;;
            *)
                echo "🛠️ Raw Dockerfile detected [FAST]! Checking execution context rules..."
                if $docker_cmd ps --format '{{.Names}}' | grep -q "^${tracking_name}$"; then
                    echo "✅ Container '$tracking_name' is active. Preserving application uptime status!"
                    return 0
                elif $docker_cmd ps -a --format '{{.Names}}' | grep -q "^${tracking_name}$"; then
                    echo "🔄 Container '$tracking_name' is dormant. Triggering pipeline startup recovery..."
                    $docker_cmd start "$tracking_name"
                    return $?
                else
                    echo "🛠️ Container sequence vacant. Building image and provisioning environment layers..."
                    if $docker_cmd build -t "${env_name}:latest" .; then
                        env_flags=""
                        [ -f ".env" ] && env_flags="--env-file .env"
                        $docker_cmd run -d --name "$tracking_name" $env_flags --restart unless-stopped -p 80:80 "${env_name}:latest"
                        return $?
                    else
                        return 1
                    fi
                fi
                ;;
        esac
    else
        echo "❌ No run.sh, docker-compose.yml, or Dockerfile found in $env_dir" >&2
        return 1
    fi
}
export -f _deploy_environment_body

deploy_environment() {
    local env_dir="$1" policy="$2" docker_cmd="${3:-docker}"
    local repo_dir; repo_dir="$(cd "$env_dir/../.." && pwd)"

    local deploy_success log_file=""
    if [ -f "$env_dir/run.sh" ]; then
        # run.sh environments (nanoclaw, nanoclaw-mnemon, etc.) can hand off
        # to their own fully-interactive sub-program via `docker exec -it`
        # (its own nested pty, reattached straight to /dev/tty). Wrapping
        # that in `script`'s pty on top breaks both live rendering and
        # stdin delivery to that sub-program (confirmed against a real
        # terminal) — so this path stays completely unwrapped, exactly as
        # it behaved before session logging was added. No log file either;
        # anything worth reviewing after a failure was on-screen live.
        _deploy_environment_body "$env_dir" "$policy" "$docker_cmd" "$repo_dir"
        deploy_success=$?
        _reset_tty_input
    else
        local log_dir="$env_dir/logs"
        mkdir -p "$log_dir"
        log_file="$log_dir/${policy}-$(date +%Y%m%d-%H%M%S).log"
        echo "📝 Logging this run to: $log_file"

        _run_logged "$log_file" _deploy_environment_body "$env_dir" "$policy" "$docker_cmd" "$repo_dir"
        deploy_success=$?
        _reset_tty_input

        if [ $deploy_success -ne 0 ]; then
            echo ""
            echo "❌ Deploy failed (exit $deploy_success) — last 30 lines of $log_file:"
            echo "----------------------------------------------------------------"
            tail -n 30 "$log_file" 2>/dev/null
            echo "----------------------------------------------------------------"
            echo "📄 Full log: $log_file"
        fi
    fi

    # Best-effort desktop-entry refresh, and the post-deploy info summary,
    # for the generic docker-compose.yml/Dockerfile fallback path only —
    # every environment with its own run.sh already does both itself at the
    # end of run.sh, so doing them again here would just be redundant
    # (harmless, but pointless) work for those. Info is skipped for
    # STOP/TEARDOWN — nothing new to report, matching how run.sh-based
    # environments never print it for those policies either.
    if [ $deploy_success -eq 0 ] && [ ! -f "$env_dir/run.sh" ]; then
        bash "$repo_dir/lib/run-install-desktop.sh" "$env_dir" >/dev/null 2>&1 || true
        if [ "$policy" != "STOP" ] && [ "$policy" != "TEARDOWN" ] && { [ -f "$env_dir/info.sh" ] || [ -f "$env_dir/info.yaml" ]; }; then
            bash "$repo_dir/lib/run-info.sh" "$env_dir" list
        fi
    fi

    return $deploy_success
}
