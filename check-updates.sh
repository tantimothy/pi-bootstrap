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
# ntopng's own Dockerfile build) fail to pull and are reported as skipped
# rather than as an error.
#
# Usage:
#   ./check-updates.sh

set -uo pipefail
# Deliberately not "-e": one unpullable/locally-built image failing its pull
# is an expected, common case here, not a reason to abort the whole scan.

DOCKER="${DOCKER_CMD:-docker}"
if ! $DOCKER ps &>/dev/null; then DOCKER="sudo $DOCKER"; fi

echo "🔍 Checking for image updates on all running containers..."
echo ""

UP_TO_DATE=0
SKIPPED=0
UPDATES_AVAILABLE=()

while IFS=$'\t' read -r NAME IMAGE_REF CONTAINER_ID; do
    [ -z "$NAME" ] && continue

    RUNNING_IMAGE_ID=$($DOCKER inspect "$CONTAINER_ID" --format '{{.Image}}' 2>/dev/null)
    if [ -z "$RUNNING_IMAGE_ID" ]; then
        continue
    fi

    PULL_OUTPUT=$($DOCKER pull "$IMAGE_REF" 2>&1)
    if [ $? -ne 0 ]; then
        echo "⏭️   $NAME ($IMAGE_REF) — skipped, not pullable (likely built locally)"
        SKIPPED=$((SKIPPED + 1))
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
done < <($DOCKER ps --format '{{.Names}}\t{{.Image}}\t{{.ID}}')

echo ""
echo "=========================================================="
echo "📊 ${#UPDATES_AVAILABLE[@]} update(s) available, $UP_TO_DATE up to date, $SKIPPED skipped (locally built)"
if [ ${#UPDATES_AVAILABLE[@]} -gt 0 ]; then
    echo ""
    echo "Already pulled — nothing further to download. To actually apply an"
    echo "update, redeploy that container's environment with CLEAN (FAST won't"
    echo "pick it up on its own if the container is already running):"
    echo ""
    for name in "${UPDATES_AVAILABLE[@]}"; do
        echo "   $name"
    done
    echo ""
    echo "   REBUILD_POLICY=CLEAN ./run.sh   # from that environment's directory"
fi
echo "=========================================================="
