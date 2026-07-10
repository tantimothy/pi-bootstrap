#!/usr/bin/env bash
# Checks whether any currently-running container's image has a newer version
# available upstream. Informational only — never restarts, recreates, or
# pulls anything into use. This repo deliberately doesn't auto-update (see
# docs/future-enhancements/pihole-wireguard-additional-services.md's "Not
# recommended: Watchtower" section for why); this is the on-demand, you're-
# still-in-control alternative to that.
#
# How it works: for each running container, this pulls its exact image
# reference fresh — pulling only ever refreshes docker's LOCAL image cache;
# a container that's already running keeps using the image ID it actually
# started from regardless of what a later pull fetches, so this is safe to
# run at any time without affecting anything live. The freshly-pulled image
# ID is then compared against the ID the container is actually running. A
# mismatch means an update is available but not yet applied.
#
# Images with no matching upstream registry entry (built locally, e.g.
# darkstat/ntopng/dragonos-sdr/kali-pentest's own Dockerfile builds) can't be
# checked that way — there's no registry tag for the built image itself to
# compare against. For those, see check_locally_built() below instead.
#
# Usage:
#   ./check-updates.sh

set -uo pipefail
# Deliberately not "-e": one unpullable/locally-built image failing its pull
# is an expected, common case here, not a reason to abort the whole scan.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER="${DOCKER_CMD:-docker}"
if ! $DOCKER ps &>/dev/null; then DOCKER="sudo $DOCKER"; fi

UP_TO_DATE=0
SKIPPED=0
UPDATES_AVAILABLE=()

# Maps a locally-built image reference back to the Dockerfile that built it
# — needed only to find its FROM line for the base-image-drift check below.
# Keyed on the image reference itself, not container name: dragonos-sdr and
# kali-pentest let CONTAINER_NAME be renamed via .env, but the image tags/
# build contexts here are fixed by each environment's own docker-compose.yml
# or run.sh, not user-configurable, so they're a stable match target.
_dockerfile_for_image() {
    case "$1" in
        *darkstat*)   echo "$REPO_DIR/environments/pihole-wireguard/darkstat/Dockerfile" ;;
        *ntopng*)     echo "$REPO_DIR/environments/ntopng/Dockerfile" ;;
        dragonos-pi)  echo "$REPO_DIR/environments/dragonos-sdr/Dockerfile" ;;
        pi-pentest*)  echo "$REPO_DIR/environments/kali-pentest/Dockerfile" ;;
        *) return 1 ;;
    esac
}

# For an image with no matching upstream registry entry, "an update" means
# one of two separate things a plain `docker pull` can never see, since
# there's no registry tag for the assembled image itself to compare
# against:
#   1. The Debian base image named in its Dockerfile's FROM line has moved
#      (a rebuild would pick up newer base OS/security patches even if the
#      package this environment actually installs hasn't changed version).
#   2. An apt package baked into the image (e.g. darkstat itself) has a
#      newer version available in Debian's own repos.
# Both are only checkable by actually asking — pulling the base tag fresh,
# and running `apt-get update` live inside the container. Neither mutates
# anything: apt-get update only refreshes local package-list metadata, and
# pulling the base tag never touches the already-running container.
check_locally_built() {
    local name="$1" image_ref="$2" container_id="$3" pull_output="$4"

    local dockerfile
    dockerfile=$(_dockerfile_for_image "$image_ref") || true

    local has_apt=false
    $DOCKER exec "$container_id" sh -c 'command -v apt-get' >/dev/null 2>&1 && has_apt=true

    # Neither a Dockerfile this repo recognizes as one of its own local
    # builds, nor apt-get inside — this isn't a known local build at all,
    # so the pull almost certainly SHOULD have succeeded (e.g. a normal
    # registry image like prom/prometheus) and something else went wrong
    # instead: a Docker Hub rate limit, DNS, a network blip. Surface the
    # actual pull error rather than a generic "skipped," which otherwise
    # looks identical to a genuinely local, never-pullable image like
    # darkstat or ntopng and hides what's actually worth investigating.
    if [ -z "$dockerfile" ] && [ "$has_apt" = "false" ]; then
        echo "❓  $name ($image_ref) — pull failed, and this isn't a recognized local build:"
        echo "$pull_output" | sed 's/^/       /'
        SKIPPED=$((SKIPPED + 1))
        return
    fi

    if [ "$has_apt" = "false" ]; then
        echo "⏭️   $name ($image_ref) — skipped, not pullable and not apt-based"
        SKIPPED=$((SKIPPED + 1))
        return
    fi

    local upgradable
    upgradable=$($DOCKER exec "$container_id" sh -c \
        'apt-get update -qq >/dev/null 2>&1 && apt list --upgradable 2>/dev/null' \
        | grep -v '^Listing' || true)

    local base_msg="" dockerfile base_ref base_id
    dockerfile=$(_dockerfile_for_image "$image_ref") || true
    if [ -n "$dockerfile" ] && [ -f "$dockerfile" ]; then
        base_ref=$(grep -m1 '^FROM' "$dockerfile" | awk '{print $2}')
        if [ -n "$base_ref" ] && $DOCKER pull "$base_ref" >/dev/null 2>&1; then
            base_id=$($DOCKER inspect "$base_ref" --format '{{.Id}}' 2>/dev/null)
            if [ -n "$base_id" ] && ! $DOCKER history --no-trunc "$image_ref" --format '{{.ID}}' 2>/dev/null | grep -qF "$base_id"; then
                base_msg="base image $base_ref has moved since this was last built"
            fi
        fi
    fi

    if [ -n "$upgradable" ] || [ -n "$base_msg" ]; then
        echo "⬆️   $name ($image_ref) — UPDATE AVAILABLE (locally built — rebuild with CLEAN to apply)"
        [ -n "$base_msg" ] && echo "       🧱 $base_msg"
        if [ -n "$upgradable" ]; then
            echo "       📦 apt packages with newer versions available:"
            echo "$upgradable" | sed 's/^/          /'
        fi
        UPDATES_AVAILABLE+=("$name")
    else
        echo "✅  $name ($image_ref) — up to date (base image + all installed apt packages current)"
        UP_TO_DATE=$((UP_TO_DATE + 1))
    fi
}

echo "🔍 Checking for image updates on all running containers..."
echo ""

while IFS=$'\t' read -r NAME CONTAINER_ID; do
    [ -z "$NAME" ] && continue

    RUNNING_IMAGE_ID=$($DOCKER inspect "$CONTAINER_ID" --format '{{.Image}}' 2>/dev/null)
    if [ -z "$RUNNING_IMAGE_ID" ]; then
        continue
    fi

    # NOT `docker ps --format '{{.Image}}'` — Docker silently falls back to a
    # bare image ID there once the tag a container was created from no
    # longer points at the image it's actually running (e.g. a later pull —
    # including one from a PRIOR run of this very script — already moved
    # that tag forward without the container being redeployed). `docker
    # inspect --format '{{.Config.Image}}'` instead returns the original
    # image reference the container was actually created with, which stays
    # a stable, correct repo:tag string regardless of where the tag points
    # now.
    IMAGE_REF=$($DOCKER inspect "$CONTAINER_ID" --format '{{.Config.Image}}' 2>/dev/null)
    if [ -z "$IMAGE_REF" ]; then
        continue
    fi

    PULL_OUTPUT=$($DOCKER pull "$IMAGE_REF" 2>&1)
    if [ $? -ne 0 ]; then
        check_locally_built "$NAME" "$IMAGE_REF" "$CONTAINER_ID" "$PULL_OUTPUT"
        continue
    fi

    PULLED_IMAGE_ID=$($DOCKER inspect "$IMAGE_REF" --format '{{.Id}}' 2>/dev/null)

    if [ "$PULLED_IMAGE_ID" = "$RUNNING_IMAGE_ID" ]; then
        echo "✅  $NAME ($IMAGE_REF) — up to date"
        UP_TO_DATE=$((UP_TO_DATE + 1))
    else
        echo "⬆️   $NAME ($IMAGE_REF) — UPDATE AVAILABLE (pulled fresh; not applied yet)"
        UPDATES_AVAILABLE+=("$NAME")
    fi
done < <($DOCKER ps --format '{{.Names}}\t{{.ID}}')

echo ""
echo "=========================================================="
echo "📊 ${#UPDATES_AVAILABLE[@]} update(s) available, $UP_TO_DATE up to date, $SKIPPED skipped/failed (see ⏭️/❓ lines above for why)"
if [ ${#UPDATES_AVAILABLE[@]} -gt 0 ]; then
    echo ""
    echo "Already pulled (or checked live via apt) — nothing further to download."
    echo "To actually apply an update, redeploy that container's environment with"
    echo "CLEAN (FAST won't pick it up on its own if the container is already"
    echo "running):"
    echo ""
    for name in "${UPDATES_AVAILABLE[@]}"; do
        echo "   $name"
    done
    echo ""
    echo "   REBUILD_POLICY=CLEAN ./run.sh   # from that environment's directory"
fi
echo "=========================================================="
