#!/bin/bash
# Shared helpers for environments/*/run.sh scripts using the plain
# `docker build`/`docker run` custom archetype (as opposed to
# docker-compose.yml, which goes through lib/deploy-lib.sh instead). These
# are the pieces that were byte-identical across kali-pentest/legion/
# metasploit's run.sh before being extracted here — each caller still owns
# its own `docker run` flags, volume provisioning, and FAST-attach behavior.
#
# Callers are expected to have already set: DOCKER, SCRIPT_DIR, REPO_DIR,
# CONTAINER_NAME, IMAGE_NAME, DEPLOYED_MARKER, CONFIG_HASH_FILE, POLICY.

# Sources .env if present, else exits with a copy-.env.example hint.
_custom_run_source_env() {
    if [ -f "$SCRIPT_DIR/.env" ]; then
        set -a
        source "$SCRIPT_DIR/.env"
        set +a
    else
        echo "❌ Error: .env file missing." >&2
        echo "   Copy .env.example to .env and fill in the values, then re-run." >&2
        exit 1
    fi
}

# Computes CONFIG_HASH/CONFIG_DRIFTED from CONFIG_HASH_FILE and a
# caller-supplied fingerprint string (the values that feed the eventual
# `docker run`, so FAST's reattach shortcut can detect they changed since
# the running container was created).
_custom_run_config_hash() {
    local fingerprint="$1"
    CONFIG_HASH=$(printf '%s' "$fingerprint" | sha256sum | awk '{print $1}')
    CONFIG_DRIFTED=false
    if [ -f "$CONFIG_HASH_FILE" ] && [ "$(cat "$CONFIG_HASH_FILE")" != "$CONFIG_HASH" ]; then
        CONFIG_DRIFTED=true
    fi
}

# STOP/TEARDOWN policy handling, common to every custom run.sh. Exits the
# script directly (both are terminal policies); returns without exiting for
# any other POLICY so the caller continues.
_custom_run_handle_stop_teardown() {
    if [ "$POLICY" = "STOP" ]; then
        echo "🛑 [STOP] Pausing container: $CONTAINER_NAME"
        $DOCKER stop "$CONTAINER_NAME" 2>/dev/null || true
        echo "✅ Container paused. Run with FAST to resume."
        exit 0
    fi

    if [ "$POLICY" = "TEARDOWN" ]; then
        echo "🗑️  [TEARDOWN] Stopping and removing container: $CONTAINER_NAME"
        $DOCKER stop "$CONTAINER_NAME" 2>/dev/null || true
        $DOCKER rm   "$CONTAINER_NAME" 2>/dev/null || true
        rm -f "$DEPLOYED_MARKER"
        rm -f "$CONFIG_HASH_FILE"
        # Best-effort — immediately removes now-stale desktop entries rather than
        # leaving them until the next manual install-desktop-entries.sh run.
        bash "$REPO_DIR/lib/run-install-desktop.sh" "$SCRIPT_DIR" >/dev/null 2>&1 || true
        echo "✅ Container removed."
        exit 0
    fi
}

# Fills CONTAINER_RUNNING/CONTAINER_EXISTS/IMAGE_EXISTS for the caller's
# CONTAINER_NAME/IMAGE_NAME.
_custom_run_query_state() {
    CONTAINER_RUNNING=$($DOCKER ps -q -f name=^/${CONTAINER_NAME}$)
    CONTAINER_EXISTS=$($DOCKER ps -a -q -f name=^/${CONTAINER_NAME}$)
    IMAGE_EXISTS=$($DOCKER images -q "$IMAGE_NAME" 2>/dev/null)
}

# Tears down any conflicting container instance unless POLICY is CLEAN/
# REBUILD — those defer teardown until after a successful build, so a
# failed build doesn't leave nothing running at all.
_custom_run_teardown_conflicting() {
    if [ "$POLICY" != "CLEAN" ] && [ "$POLICY" != "REBUILD" ] && [ -n "$CONTAINER_EXISTS" ]; then
        echo "🛑 Tearing down conflicting container instances of $CONTAINER_NAME..."
        $DOCKER stop "$CONTAINER_NAME" >/dev/null 2>&1
        $DOCKER rm "$CONTAINER_NAME" >/dev/null 2>&1
    fi
}

# CLEAN/REBUILD/FAST build-policy routing shared by every custom run.sh.
# Sets BUILD_STATUS; exits 1 on build failure. REBUILD sits between FAST
# (never builds once an image exists) and CLEAN (--no-cache, reinstalls
# every apt package from scratch): it's a normal cached `docker build`, so
# Docker only replays layers from the first changed instruction onward.
# Use it for entrypoint.sh/run.sh edits; reach for CLEAN only when the
# Dockerfile's own package list changed. Assumes the caller has already cd'd
# into the directory containing its Dockerfile.
_custom_run_build_image() {
    if [ "$POLICY" = "CLEAN" ] || [ "$POLICY" = "REBUILD" ]; then
        if [ "$POLICY" = "CLEAN" ]; then
            echo "🛠️ [CLEAN Policy] Rebuilding image from scratch (--no-cache)..."
            $DOCKER build --no-cache -t "$IMAGE_NAME" .
        else
            echo "🔧 [REBUILD Policy] Rebuilding with Docker's layer cache (menu/script edits only)..."
            $DOCKER build -t "$IMAGE_NAME" .
        fi
        BUILD_STATUS=$?

        if [ "$BUILD_STATUS" -eq 0 ] && [ -n "$CONTAINER_EXISTS" ]; then
            # Build succeeded — safe to tear down the previous container now.
            # (The build already retagged $IMAGE_NAME onto the new image,
            # leaving the old one dangling rather than deleting it.)
            echo "🛑 Tearing down previous container instance of $CONTAINER_NAME..."
            $DOCKER stop "$CONTAINER_NAME" >/dev/null 2>&1
            $DOCKER rm "$CONTAINER_NAME" >/dev/null 2>&1
        fi

        # Cleans up the now-dangling previous image retagged over above. -f only
        # removes untagged images, never anything still referenced by a container.
        $DOCKER image prune -f >/dev/null 2>&1 || true

    elif [ -z "$IMAGE_EXISTS" ]; then
        echo "⚠️ No cached image found. Building..."
        $DOCKER build -t "$IMAGE_NAME" .
        BUILD_STATUS=$?
    else
        echo "📦 [FAST Policy] Using existing image (no rebuild needed)."
        BUILD_STATUS=0
    fi

    if [ "$BUILD_STATUS" -ne 0 ]; then
        echo "❌ ERROR: Image build failed." >&2
        exit 1
    fi
}
