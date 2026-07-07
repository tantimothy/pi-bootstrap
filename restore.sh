#!/usr/bin/env bash
# Restores an environment's persistent data (data directories + named Docker
# volumes, and its .env if present) from an archive created by backup.sh.
#
# Usage:
#   ./restore.sh <path-to-backup.tar.gz>              # interactive: choose which environment
#   ./restore.sh <path-to-backup.tar.gz> <env-name>   # restore one specific environment
#   ./restore.sh <path-to-backup.tar.gz> all          # restore every environment in the archive

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER="${DOCKER_CMD:-docker}"
if ! $DOCKER ps &>/dev/null; then DOCKER="sudo $DOCKER"; fi

ARCHIVE="${1:-}"
TARGET_ENV="${2:-}"

if [ -z "$ARCHIVE" ] || [ ! -f "$ARCHIVE" ]; then
    echo "Usage: ./restore.sh <path-to-backup.tar.gz> [environment-name|all]" >&2
    exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "📦 Inspecting archive: $ARCHIVE"
# Avoiding `mapfile` here (bash 4+ only) since this may run on a fresh
# machine with an older default bash (e.g. macOS's stock bash 3.2).
AVAILABLE_ENVS=()
while IFS= read -r ENV_ENTRY; do
    AVAILABLE_ENVS+=("$ENV_ENTRY")
done < <(tar tzf "$ARCHIVE" | awk -F/ '{print $1}' | sort -u)

if [ "${#AVAILABLE_ENVS[@]}" -eq 0 ]; then
    echo "❌ Archive contains no recognizable environment data." >&2
    exit 1
fi

if [ -z "$TARGET_ENV" ]; then
    echo ""
    echo "Environments in this backup:"
    for e in "${AVAILABLE_ENVS[@]}"; do echo "   $e"; done
    echo ""
    read -rp "Restore which environment? (name, or 'all'): " TARGET_ENV
fi

restore_one() {
    local env_name="$1"
    local env_path="$REPO_DIR/environments/$env_name"

    if [ ! -d "$env_path" ]; then
        echo "⚠️  Skipping '$env_name' — no matching environments/$env_name/ in this repo checkout." >&2
        return
    fi

    echo ""
    echo "🔎 Previewing what will be restored for $env_name..."

    local has_env=false has_data=false has_volumes=false
    tar tzf "$ARCHIVE" "${env_name}/.env" &>/dev/null && has_env=true
    tar tzf "$ARCHIVE" | grep -q "^${env_name}/data/" && has_data=true
    tar tzf "$ARCHIVE" | grep -q "^${env_name}/volumes/" && has_volumes=true

    if [ "$has_env" = "false" ] && [ "$has_data" = "false" ] && [ "$has_volumes" = "false" ]; then
        echo "ℹ️  Nothing to restore for $env_name."
        return
    fi

    [ "$has_env" = "true" ] && echo "   • .env (will overwrite $env_path/.env if it exists)"
    [ "$has_data" = "true" ] && echo "   • Data directories (will overwrite any existing files at their original paths)"
    [ "$has_volumes" = "true" ] && echo "   • Docker volumes (will overwrite any existing volume of the same name)"

    read -rp "Type 'yes' to restore $env_name: " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "❌ Skipped $env_name."
        return
    fi

    if [ "$has_env" = "true" ]; then
        tar xzf "$ARCHIVE" -C "$TMP_DIR" "${env_name}/.env"
        cp "$TMP_DIR/${env_name}/.env" "$env_path/.env"
        echo "   ✅ Restored .env"
    fi

    if [ "$has_data" = "true" ]; then
        # --strip-components=2 removes "<env_name>/data/" from each archive
        # entry, extracting the remainder (the original absolute path, minus
        # its leading slash — see backup.sh) relative to /, reconstructing
        # every data dir exactly where it originally lived.
        tar xzf "$ARCHIVE" -C / --strip-components=2 "${env_name}/data"
        echo "   ✅ Restored data directories"
    fi

    if [ "$has_volumes" = "true" ]; then
        tar xzf "$ARCHIVE" -C "$TMP_DIR" "${env_name}/volumes"
        for vol_tar in "$TMP_DIR/${env_name}/volumes"/*.tar.gz; do
            [ -e "$vol_tar" ] || continue
            vol_name="$(basename "$vol_tar" .tar.gz)"
            $DOCKER volume create "$vol_name" >/dev/null
            $DOCKER run --rm \
                -v "${vol_name}:/vol" \
                -v "$(dirname "$vol_tar"):/in:ro" \
                alpine sh -c "rm -rf /vol/* && tar xzf /in/$(basename "$vol_tar") -C /vol"
            echo "   ✅ Restored Docker volume: $vol_name"
        done
    fi

    echo "✅ $env_name restored."
}

if [ "$TARGET_ENV" = "all" ]; then
    for e in "${AVAILABLE_ENVS[@]}"; do restore_one "$e"; done
else
    restore_one "$TARGET_ENV"
fi

echo ""
echo "ℹ️  Data restored. Redeploy via ./deploy.sh (or that environment's run.sh, REBUILD_POLICY=FAST) to bring it back up."
