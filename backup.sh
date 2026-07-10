#!/usr/bin/env bash
# Builds one archive containing every deployed environment's persistent data
# (data directories + named Docker volumes) and, by default, its .env file.
#
# The archive is written locally — copying it to another machine (scp, rsync,
# a USB drive, cloud sync, etc.) is up to you. That keeps this script free of
# any assumptions about network access, SSH keys, or the destination's OS.
#
# Usage:
#   ./backup.sh                # back up every environment, .env included
#   ./backup.sh --no-env       # exclude .env files (data dirs/volumes only)
#   ./backup.sh -o /path/to/dir   # write the archive somewhere other than cwd

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER="${DOCKER_CMD:-docker}"
if ! $DOCKER ps &>/dev/null; then DOCKER="sudo $DOCKER"; fi

# Some data dirs contain files written by containers that run as root inside
# their bind mount (e.g. wg-easy's wg0.json/wg0.conf) — reading those back
# out needs root too, regardless of who owns the rest of a given directory.
# Always reading via sudo is simplest and avoids guessing which specific
# files need it; ownership of the final archive is handed back to the
# invoking user at the end.
SUDO_TAR="sudo tar"

INCLUDE_ENV=true
OUT_DIR="$(pwd)"

while [ $# -gt 0 ]; do
    case "$1" in
        --no-env) INCLUDE_ENV=false; shift ;;
        -o|--output) OUT_DIR="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

mkdir -p "$OUT_DIR"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="$OUT_DIR/pi-bootstrap-backup-${TIMESTAMP}.tar"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FIRST_APPEND=true
INCLUDED_ENVS=()

# Appends a single file or directory into the growing archive, prefixed with
# $1 inside the archive. Reads directly from $3 (a file/dir under $2) without
# ever copying it elsewhere first — the archive is built incrementally with
# repeated `tar -c`/`tar -r` calls rather than staging a full copy on disk,
# so this stays cheap even for large data dirs (SDR captures, metrics, etc.).
append_to_archive() {
    local archive_prefix="$1" src_dir="$2" src_name="$3"
    if [ "$FIRST_APPEND" = "true" ]; then
        $SUDO_TAR --transform "s#^#${archive_prefix}#" -cf "$ARCHIVE" -C "$src_dir" "$src_name"
        FIRST_APPEND=false
    else
        $SUDO_TAR --transform "s#^#${archive_prefix}#" -rf "$ARCHIVE" -C "$src_dir" "$src_name"
    fi
}

# Mirrors each environment's own "deployed" signal (the same one
# install-desktop.sh uses to decide whether to show a desktop shortcut) —
# a leftover .env from configuring-but-not-deploying an environment in the
# TUI wizard shouldn't make backup.sh treat it as having real data.
is_deployed() {
    local env_name="$1" env_path="$2"
    case "$env_name" in
        pihole-wireguard)
            $DOCKER ps -a --filter "name=^/pihole$" -q 2>/dev/null | grep -q .
            ;;
        ntopng)
            $DOCKER ps -a --filter "name=^/ntopng$" -q 2>/dev/null | grep -q .
            ;;
        portainer)
            $DOCKER ps -a --filter "name=^/portainer$" -q 2>/dev/null | grep -q .
            ;;
        dragonos-sdr|kali-pentest)
            [ -f "${env_path}.deployed" ]
            ;;
        nanoclaw)
            systemctl list-unit-files "nanoclaw.service" --no-legend 2>/dev/null | grep -q nanoclaw
            ;;
        internet-pi)
            local install_path
            install_path=$(grep -E '^INTERNET_PI_INSTALL_PATH=' "${env_path}.env" 2>/dev/null | cut -d= -f2-)
            [ -d "${install_path:-/home/pi/internet-pi}" ]
            ;;
        *)
            # Unknown/future environment type — don't block it, just let
            # its actual manifest content (or lack of it) decide.
            true
            ;;
    esac
}

echo "🗄️  Building backup archive..."
echo ""

for ENV_PATH in "$REPO_DIR"/environments/*/; do
    ENV_NAME="$(basename "$ENV_PATH")"
    [ -f "$ENV_PATH/info.sh" ] || continue

    if ! is_deployed "$ENV_NAME" "$ENV_PATH"; then
        echo "   ⏭️  $ENV_NAME (not deployed — skipping, even though a .env may exist from configuring it in the TUI)"
        continue
    fi

    ENV_HAS_CONTENT=false

    # .env — a fixed, well-known location (environments/<env>/.env), so it's
    # handled directly here rather than through the generic DIR mechanism
    # below (which preserves arbitrary absolute paths for DATA_DIRS instead).
    if [ "$INCLUDE_ENV" = "true" ] && [ -f "${ENV_PATH}.env" ]; then
        append_to_archive "${ENV_NAME}/" "$ENV_PATH" ".env"
        ENV_HAS_CONTENT=true
    fi

    while IFS=':' read -r TYPE VALUE; do
        [ -z "$TYPE" ] && continue
        case "$TYPE" in
            DIR)
                [ -d "$VALUE" ] || continue
                # Store relative to / (stripping the leading slash) so the
                # archive preserves the FULL original absolute path — some
                # environments' data dirs live under environments/<env>/,
                # others live directly under $HOME, and restore.sh needs to
                # put each one back exactly where it came from.
                append_to_archive "${ENV_NAME}/data/" / "${VALUE#/}"
                ENV_HAS_CONTENT=true
                ;;
            VOL)
                # Guarded with `|| true` — if the Docker daemon isn't
                # reachable at all, treat it the same as the volume not
                # existing (skip it) rather than aborting the whole backup.
                VOL_EXISTS=$($DOCKER volume ls -q --filter name="^${VALUE}$" 2>/dev/null || true)
                [ -n "$VOL_EXISTS" ] || continue
                echo "   📦 Snapshotting Docker volume: $VALUE"
                $DOCKER run --rm \
                    -v "${VALUE}:/vol:ro" \
                    -v "${TMP_DIR}:/out" \
                    alpine sh -c "tar czf /out/${VALUE}.tar.gz -C /vol ." >/dev/null
                append_to_archive "${ENV_NAME}/volumes/" "$TMP_DIR" "${VALUE}.tar.gz"
                rm -f "${TMP_DIR:?}/${VALUE}.tar.gz"
                ENV_HAS_CONTENT=true
                ;;
        esac
    done < <(bash "${ENV_PATH}info.sh" manifest 2>/dev/null)

    if [ "$ENV_HAS_CONTENT" = "true" ]; then
        INCLUDED_ENVS+=("$ENV_NAME")
        echo "   ✅ $ENV_NAME"
    else
        echo "   ⏭️  $ENV_NAME (nothing to back up — no .env or existing data)"
    fi
done

if [ "$FIRST_APPEND" = "true" ]; then
    echo "❌ Nothing to back up — no .env files or existing data found in any environment." >&2
    exit 1
fi

# Only now do we know exactly which environments actually ended up in the
# archive — rename it to include their names instead of a bare timestamp,
# so it's identifiable at a glance without having to open it.
ENV_SUFFIX=$(IFS='+'; echo "${INCLUDED_ENVS[*]}")
FINAL_ARCHIVE="$OUT_DIR/pi-bootstrap-backup-${TIMESTAMP}-${ENV_SUFFIX}.tar"
mv "$ARCHIVE" "$FINAL_ARCHIVE"
ARCHIVE="$FINAL_ARCHIVE"

# $ARCHIVE was built via $SUDO_TAR, so it's root-owned — hand it back to the
# invoking user now so a plain, non-root gzip (and later use of the .gz) is
# guaranteed to work regardless of root's umask.
sudo chown "$(id -u):$(id -g)" "$ARCHIVE"

echo ""
echo "🗜️  Compressing..."
gzip -f "$ARCHIVE"

echo ""
echo "✅ Backup complete: ${ARCHIVE}.gz"
echo "   Size: $(du -h "${ARCHIVE}.gz" | cut -f1)"
echo "   Environments included: ${INCLUDED_ENVS[*]}"
if [ "$INCLUDE_ENV" = "true" ]; then
    echo "   Includes .env files (secrets) — treat this archive as sensitive."
fi
echo ""
echo "📤 Copy it to another machine however you like, e.g.:"
echo "   scp \"${ARCHIVE}.gz\" user@remote-host:/path/to/save/"
echo "   rsync -avP \"${ARCHIVE}.gz\" user@remote-host:/path/to/save/"
echo ""
echo "To restore later (same machine or a fresh one with this repo cloned):"
echo "   ./restore.sh \"${ARCHIVE}.gz\""
