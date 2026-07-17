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

# Force a UTF-8 locale before any of the emoji-laden progress output below
# prints — see lib/locale-lib.sh's own comment for why. `|| true` because
# a failed/missing-locale outcome there returns non-zero, which `set -e`
# above would otherwise treat as this whole script failing.
source "$REPO_DIR/lib/locale-lib.sh" || true

DOCKER="${DOCKER_CMD:-docker}"
if ! $DOCKER ps &>/dev/null; then DOCKER="sudo $DOCKER"; fi

# Some data dirs contain files written by containers that run as root inside
# their bind mount (e.g. wg-easy's wg0.json/wg0.conf) — reading those back
# out needs root too, regardless of who owns the rest of a given directory.
# Always reading via sudo is simplest and avoids guessing which specific
# files need it; ownership of the final archive is handed back to the
# invoking user at the end.
SUDO_TAR="sudo tar"

# GNU tar (Linux/Raspberry Pi) renames archive entries via --transform,
# which takes a full sed EXPRESSION as its argument (hence needs a leading
# "s", e.g. "s#old#new#") — it hands that string straight to a real sed-
# style engine. BSD tar (macOS's bundled /usr/bin/tar, libarchive-based)
# has no --transform at all ("tar: Option --transform is not supported")
# and instead takes the same substitution via -s — but -s's argument is
# NOT a sed expression, just "#old#new#[flags]", no leading "s". The flag
# name (-s) already means "substitute"; a leading "s" isn't stripped
# before parsing.
#
# Confirmed directly against libarchive's own tar/subst.c source
# (add_substitution(), matching the exact 3.7.4 release a real failing Mac
# reported): it reads the FIRST character of whatever string you pass as
# the delimiter, full stop — `end_pattern = strchr(rule_text + 1,
# *rule_text)`. Passing "s#old#new#" (GNU tar's own required syntax) means
# BSD tar treats the leading "s" ITSELF as the delimiter, then searches
# for the next literal "s" character to close the pattern — which
# silently corrupts the parse the moment any real "s" appears later in
# the pattern or replacement (an near-certainty for this repo's own env/
# path names, e.g. "chat-frontends") rather than stopping at the intended
# "#". The garbled 3-way split then fails to find a matching final
# delimiter at all, producing the exact bare "tar: Invalid replacement
# string" a real Mac hit — unrelated to the delimiter *character* choice
# itself (both "#" and "/" are valid, arbitrary delimiters to bsdtar, same
# as sed) or to zero-width matches (both prior theories this session,
# each fixed something real but neither was actually blocking this).
if tar --version 2>&1 | grep -qi "GNU tar"; then
    TAR_TRANSFORM_FLAG="--transform"
    TAR_SUBST_PREFIX="s"
else
    TAR_TRANSFORM_FLAG="-s"
    TAR_SUBST_PREFIX=""
fi

# Escapes regex metacharacters in $1 so it's safe to splice into the
# pattern's "old" (match) half as a LITERAL string, not a regex. "#" (the
# delimiter) deliberately isn't escaped here at all — bsdtar's own parser
# is a naive strchr() split with no escape awareness for the delimiter
# (confirmed in the same source read above), so an escaped delimiter
# wouldn't be understood as literal anyway. "#" is used specifically
# because it's not a character any real environment name, path, or volume
# name in this repo ever contains — the only real defense against
# delimiter collision bsdtar allows is picking one that can't appear, not
# escaping one that might.
_tar_pattern_escape() {
    local s="$1" out="" c i
    for (( i=0; i<${#s}; i++ )); do
        c="${s:$i:1}"
        case "$c" in
            .|'*'|'['|']'|^|'$'|'\') out+="\\$c" ;;
            *) out+="$c" ;;
        esac
    done
    printf '%s' "$out"
}

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
    # Anchored on the literal $src_name itself (e.g. "#^\.env#prefix.env#"),
    # not a bare "#^#prefix#" zero-width match — kept from an earlier fix
    # this session; not itself the bug that was actually blocking this
    # (see the TAR_SUBST_PREFIX comment above), but doesn't hurt either.
    # $src_name is always non-empty at every call site below.
    #
    # TAR_SUBST_PREFIX is "s" for GNU tar's --transform (a real sed
    # expression, needs it) and empty for BSD tar's -s (whose argument is
    # just the delimited pattern itself — see the comment above
    # TAR_TRANSFORM_FLAG's own assignment for why a leading "s" there
    # silently corrupts the parse instead of erroring cleanly).
    local escaped_pattern; escaped_pattern="$(_tar_pattern_escape "$src_name")"
    local transform_pattern="${TAR_SUBST_PREFIX}#^${escaped_pattern}#${archive_prefix}${src_name}#"
    if [ "$FIRST_APPEND" = "true" ]; then
        $SUDO_TAR "$TAR_TRANSFORM_FLAG" "$transform_pattern" -cf "$ARCHIVE" -C "$src_dir" "$src_name"
        FIRST_APPEND=false
    else
        $SUDO_TAR "$TAR_TRANSFORM_FLAG" "$transform_pattern" -rf "$ARCHIVE" -C "$src_dir" "$src_name"
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
            # Mirrors run.sh's own OS-based default + .env override — there's
            # no systemd unit at all in container mode, and no "nanoclaw"
            # container in host mode either.
            local nanoclaw_mode
            nanoclaw_mode=$(grep -E '^NANOCLAW_DEPLOY_MODE=' "${env_path}.env" 2>/dev/null | cut -d= -f2-)
            if [ -z "$nanoclaw_mode" ]; then
                [[ "$(uname)" == "Darwin" ]] && nanoclaw_mode="container" || nanoclaw_mode="host"
            fi
            if [ "$nanoclaw_mode" = "container" ]; then
                $DOCKER ps -a --filter "name=^/nanoclaw$" -q 2>/dev/null | grep -q .
            else
                systemctl list-unit-files "nanoclaw.service" --no-legend 2>/dev/null | grep -q nanoclaw
            fi
            ;;
        internet-pi)
            local install_path
            install_path=$(grep -E '^INTERNET_PI_INSTALL_PATH=' "${env_path}.env" 2>/dev/null | cut -d= -f2-)
            [ -d "${install_path:-/home/pi/internet-pi}" ]
            ;;
        nanoclaw-mnemon)
            # Container mode only — no host/systemd mode to detect here,
            # unlike the plain nanoclaw environment.
            $DOCKER ps -a --filter "name=^/nanoclaw-mnemon$" -q 2>/dev/null | grep -q .
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
    { [ -f "$ENV_PATH/info.sh" ] || [ -f "$ENV_PATH/info.yaml" ]; } || continue

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
    done < <(bash "$REPO_DIR/lib/run-info.sh" "${ENV_PATH%/}" manifest 2>/dev/null)

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
