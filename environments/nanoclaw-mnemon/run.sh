#!/usr/bin/env bash

# =======================================================================================
# NANOCLAW ENVIRONMENT ORCHESTRATOR (run.sh)
# This repository's single NanoClaw environment. NANOCLAW_SETUP=mnemon (the
# default) patches github.com/mnemon-dev/mnemon into NanoClaw's per-group
# agent sandbox, following NanoClaw's own add-mnemon skill; plain leaves the
# upstream agent image unpatched. Both profiles use the same install path and
# container-only deployment.
#
# What mnemon adds: a four-graph (temporal/entity/causal/semantic) memory
# store per conversation group, written to that group's own `.claude/`
# mount — see the README's "Mnemon Integration" section for the full
# picture, including what this does and doesn't change about the
# orchestrator's own trust boundary (it doesn't: mnemon runs inside the
# already-sandboxed per-group agent containers, which never held the
# Docker socket to begin with).
# =======================================================================================

set -euo pipefail

DOCKER="${DOCKER_CMD:-docker}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
POLICY="${REBUILD_POLICY:-FAST}"
# Set to true by any patch that actually rewrites container/Dockerfile, so a
# non-CLEAN deploy knows it has to rebuild the agent-sandbox image for that
# write to mean anything (CLEAN always rebuilds regardless). See the
# "Versioned patch blocks" comment block further down.
AGENT_IMAGE_NEEDS_REBUILD=false

# This script prints emoji/arrows/em-dashes throughout, including via
# lib/run-info.sh's post-deploy summary further down — see lib/locale-lib.sh's
# own comment for why that garbles into raw hex-byte escapes without a UTF-8
# locale forced first (confirmed directly: a real deploy run via this exact
# entry point, invoked directly rather than through deploy.sh's menu, which
# is the only other place this got sourced).
source "$REPO_DIR/lib/locale-lib.sh" || true
# _yaml_expand — resolves `${VAR}`/`${VAR:-default}` markers against real
# bash variables already in scope, safely (plain-name expansion only, no
# command substitution/arbitrary code). Despite the name, it's a generic
# string-templating helper, not YAML-specific — reused below by
# write_patches_manifest() to render templates/patches-manifest.md.tmpl.
source "$REPO_DIR/lib/yaml-lib.sh"

echo "=========================================================="
echo "🧠 NanoClaw + Mnemon Deployment Pipeline"
echo "⚙️  Active Policy: ${POLICY}"
echo "=========================================================="

# ---------------------------------------------------------------------------------------
# 1. Source configuration
# ---------------------------------------------------------------------------------------
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "❌ Error: .env file missing." >&2
    echo "   Copy .env.example to .env and fill in the values, then re-run." >&2
    exit 1
fi

INSTALL_PATH="${NANOCLAW_INSTALL_PATH:-$HOME/nanoclaw-mnemon}"
# .env.example's own literal default (/home/pi/nanoclaw-mnemon) is
# Pi-appropriate for this repo's primary target, but deploy.sh's TUI config
# form always writes a value for every .env.example key — even one nobody
# edited — so ${NANOCLAW_INSTALL_PATH:-$HOME/nanoclaw-mnemon} above never
# actually triggers for anyone going through the TUI: NANOCLAW_INSTALL_PATH
# is never empty once .env exists. On macOS /home/pi doesn't exist at all
# (no `pi` user, no /home), so accepting that default as-is means every
# mkdir/git-clone below fails — worth catching explicitly given this
# environment is specifically documented as Mac-first (see the header
# comment above). Only overrides the exact, unmodified default — a
# deliberate custom path (even a Linux-style one) is left alone.
if [[ "$(uname)" == "Darwin" ]] && [ "$INSTALL_PATH" = "/home/pi/nanoclaw-mnemon" ]; then
    INSTALL_PATH="$HOME/nanoclaw-mnemon"
    echo "⚠️  NANOCLAW_INSTALL_PATH was still the Pi-only default (/home/pi/nanoclaw-mnemon), which doesn't exist on macOS."
    echo "   Switching to \$HOME/nanoclaw-mnemon ($INSTALL_PATH) and updating .env to match."
    # Persisted, not just overridden in-memory for this run — otherwise
    # info.yaml's own display of this same path (and any future run before
    # the override logic above re-runs) would still show the broken /home/pi
    # path even though this run actually installs somewhere else.
    # -i.bak (suffix attached, no space) is the one `sed -i` form GNU and
    # BSD/macOS sed both accept identically.
    if [ -f "$ENV_FILE" ] && grep -q "^NANOCLAW_INSTALL_PATH=" "$ENV_FILE"; then
        sed -i.bak "s#^NANOCLAW_INSTALL_PATH=.*#NANOCLAW_INSTALL_PATH='${INSTALL_PATH}'#" "$ENV_FILE"
        rm -f "${ENV_FILE}.bak"
    fi
fi
NANOCLAW_PORT="${NANOCLAW_PORT:-3081}"
MNEMON_VERSION="${MNEMON_VERSION:-0.1.17}"
NANOCLAW_SETUP="${NANOCLAW_SETUP:-mnemon}"
case "$NANOCLAW_SETUP" in
    mnemon|plain) ;;
    *) echo "❌ NANOCLAW_SETUP must be 'mnemon' or 'plain' (got: $NANOCLAW_SETUP)." >&2; exit 1 ;;
esac
NANOCLAW_INSTALL_CODEX="${NANOCLAW_INSTALL_CODEX:-false}"
case "$NANOCLAW_INSTALL_CODEX" in
    true|false) ;;
    *) echo "❌ NANOCLAW_INSTALL_CODEX must be 'true' or 'false' (got: $NANOCLAW_INSTALL_CODEX)." >&2; exit 1 ;;
esac
# Opt-in — mnemon's own optional hybrid graph+vector recall (unset by
# default: commented out until you actually have Ollama running
# somewhere reachable). Left blank, mnemon runs graph-only, which is its
# own documented default behavior, not a degraded mode.
MNEMON_EMBED_ENDPOINT="${MNEMON_EMBED_ENDPOINT:-}"
MNEMON_EMBED_MODEL="${MNEMON_EMBED_MODEL:-}"
CONTAINER_NAME="${CONTAINER_NAME:-nanoclaw-mnemon}"
IMAGE_TAG="nanoclaw-mnemon-orchestrator:latest"

# Containers default to UTC with no timezone info of their own — /etc/localtime
# is a symlink into .../zoneinfo/<Region>/<City> on both macOS and Linux, so
# this reads the same regardless of host OS. Falls back to UTC (Docker's own
# default anyway) if the host doesn't have that symlink for some reason.
HOST_TZ="$(readlink /etc/localtime 2>/dev/null | sed -n 's#.*/zoneinfo/##p')"
HOST_TZ="${HOST_TZ:-UTC}"

# ---------------------------------------------------------------------------------------
# Identify this install's NanoClaw agent containers.
#
# Two independent identifiers are matched, and that redundancy is the whole
# point — matching only the image reference silently failed for a live
# install, letting an agent container built 2026-07-21 keep serving through
# every CLEAN deploy for over two weeks:
#
#   - CONTAINER NAME: NanoClaw names each one `nanoclaw-v2-<group>-<id>`.
#     Stable, assigned at creation, never rewritten. This is also the
#     identifier the smoke-test checklist in scripts/entrypoint.sh tells the
#     admin session to look for, so the two now agree.
#   - IMAGE REFERENCE: `nanoclaw-agent-v2-<slug>:<per-agent tag>`.
#
# The image alone is not dependable here because `docker ps --format
# '{{.Image}}'` resolves the container's image ID to a *name at query time*
# and falls back to a bare `sha256:...` when that reference no longer
# resolves. NanoClaw tags each agent image ephemerally
# (`:ag-<timestamp>-<random>`), so once such a tag is collected or
# overwritten, the container it produced became invisible to this sweep —
# no error, no output, just silently nothing to remove. That is exactly what
# a live CLEAN showed: the post-rebuild sweep announced itself and found
# zero containers while a stale one was demonstrably still running.
#
# The bind-mount scope check stays: agent containers from a DIFFERENT
# NanoClaw install on the same host share both naming schemes, and only the
# mount path distinguishes them. But a container that matches by name/image
# and is then dropped by that check is now reported rather than silently
# skipped — if the scope check is ever the thing failing, the next run says
# so instead of looking like a clean sweep.
# ---------------------------------------------------------------------------------------
sweep_agent_container_ids() {
    local ids id mounts
    ids=$($DOCKER ps -a --format '{{.ID}} {{.Names}} {{.Image}}' 2>/dev/null \
        | awk '$2 ~ /^nanoclaw-v2-/ || $3 ~ /^nanoclaw-agent-v2-/ {print $1}')
    [ -z "$ids" ] && return 0
    for id in $ids; do
        mounts=$($DOCKER inspect "$id" --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' 2>/dev/null)
        if echo "$mounts" | grep -qF "$INSTALL_PATH"; then
            echo "$id"
        else
            echo "ℹ️  Agent container $id looks like NanoClaw's but has no bind mount under $INSTALL_PATH — leaving it alone (another NanoClaw install on this host?). If this install's own agents keep surviving CLEAN, this line is the reason to look at." >&2
        fi
    done
}

# ---------------------------------------------------------------------------------------
# Per-group DERIVED agent images — the layer of this system that neither this
# script nor its docs knew existed until a live install spent days broken by it.
#
# NanoClaw does not always run agents from the base agent-sandbox image. A
# conversation group that installs custom packages (its own `install_packages`
# self-modification flow, or `ncl groups add-package`) gets its own image,
# built FROM the base and tagged `nanoclaw-agent-v2-<slug>:<group-id>`. The tag
# is stored in NanoClaw's own container_configs table, and container-runner.ts
# passes it straight to `docker run` on every spawn for that group.
#
# Two consequences, both of which bit a real deployment:
#
#   1. **A derived image is never rebuilt by anything in this repo.** CLEAN
#      rebuilds the BASE image (container/build.sh) and stops there — upstream
#      treats derived images as operator-managed, rebuilt only via
#      `ncl groups restart --rebuild`. So every patch this script applies to
#      container/Dockerfile — the statically-linked whisper-cli, the
#      scheme-gated mnemon NO_PROXY ENV — lands in the base and never reaches
#      a group that has one. That group keeps running whatever the base looked
#      like on the day its derived image was built, indefinitely. A live
#      install ran a 2026-07-21 derived image against a 2026-08-06 base for
#      over two weeks, which is the actual reason `whisper-cli` stayed
#      dynamically linked and mnemon kept reporting ollama_available:false
#      through repeated CLEAN deploys. Replacing the CONTAINER does not help:
#      it just respawns from the same stale derived image.
#   2. **Deleting a derived image breaks that group silently and completely.**
#      The tag stays in NanoClaw's database, `docker run` fails instantly
#      (exit 125, nothing on the captured stderr), and NanoClaw's close
#      handler emits nothing at INFO — so the only visible symptom is that
#      messages queue forever while a spawn is retried every 60s. Anyone
#      cleaning up "old nanoclaw images" by hand will hit this.
#
# So: after the base image is rebuilt, any derived image older than it is
# stale by construction, and is rebuilt here. The group ID needed to do that
# is the image tag itself — verified against a real install, where image
# `nanoclaw-agent-v2-91b144eb:ag-1783945827013-hhyk7w` corresponded to group
# `ag-1783945827013-hhyk7w`. That means this needs no database access and no
# parsing of `ncl groups list` output, only Docker's own image list.
# ---------------------------------------------------------------------------------------
AGENT_IMAGE_REPO_PREFIX="nanoclaw-agent-v2-"
GROUP_IMAGES_LOG=""

_group_images_log() { GROUP_IMAGES_LOG="${GROUP_IMAGES_LOG}- ${1}
"; }

rebuild_stale_group_images() {
    local base_tag base_created repo_tag created group_id stale=0 rebuilt=0

    base_tag=$($DOCKER images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
        | awk -F: -v p="^${AGENT_IMAGE_REPO_PREFIX}" '$1 ~ p && $2 == "latest" {print; exit}')
    if [ -z "$base_tag" ]; then
        _group_images_log "Skipped — no ${AGENT_IMAGE_REPO_PREFIX}*:latest base image found to compare against."
        return 0
    fi
    base_created=$($DOCKER image inspect "$base_tag" --format '{{.Created}}' 2>/dev/null) || return 0

    while IFS= read -r repo_tag; do
        [ -z "$repo_tag" ] && continue
        created=$($DOCKER image inspect "$repo_tag" --format '{{.Created}}' 2>/dev/null) || continue
        # Docker reports .Created as RFC3339 in UTC, so a plain string
        # comparison orders these correctly without needing date parsing
        # (`date -d` is GNU-only; this has to work on macOS too).
        if [[ "$created" < "$base_created" ]]; then
            stale=$((stale + 1))
            group_id="${repo_tag##*:}"
            echo "♻️  Group '${group_id}' runs a derived agent image older than the base it should build on — rebuilding it so this deploy's patches actually reach that group..."
            echo "   (this installs that group's own custom packages on top of the new base and can take several minutes)"
            if $DOCKER exec "$CONTAINER_NAME" bash -lc "cd '$INSTALL_PATH' && pnpm ncl groups restart --id '$group_id' --rebuild"; then
                rebuilt=$((rebuilt + 1))
                _group_images_log "Group \`${group_id}\`: derived image was older than the base — **REBUILT**."
            else
                echo "⚠️  Couldn't rebuild group '${group_id}''s derived image automatically." >&2
                echo "   That group will keep running the older image — including, if this deploy changed them, an out-of-date whisper-cli or mnemon proxy configuration." >&2
                echo "   Run this by hand inside the orchestrator container:" >&2
                echo "     cd \$NANOCLAW_INSTALL_PATH && pnpm ncl groups restart --id '${group_id}' --rebuild" >&2
                _group_images_log "Group \`${group_id}\`: derived image is older than the base and the automatic rebuild **FAILED**. Until \`pnpm ncl groups restart --id ${group_id} --rebuild\` succeeds, this group runs a pre-patch image — expect whisper-cli and mnemon symptoms here even though the base image is healthy."
            fi
        fi
    done < <($DOCKER images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
        | awk -F: -v p="^${AGENT_IMAGE_REPO_PREFIX}" '$1 ~ p && $2 != "latest" && $2 != "<none>" {print}')

    if [ "$stale" -eq 0 ]; then
        _group_images_log "No per-group derived images are older than the base image (nothing to rebuild)."
    else
        echo "🧩 Per-group derived agent images: ${stale} stale, ${rebuilt} rebuilt."
    fi
}

remove_agent_containers() {
    local ids; ids=$(sweep_agent_container_ids)
    if [ -n "$ids" ]; then
        echo "🐳 Removing this install's agent containers..."
        echo "$ids" | sed 's/^/     /'
        echo "$ids" | xargs "$DOCKER" stop 2>/dev/null || true
        echo "$ids" | xargs "$DOCKER" rm   2>/dev/null || true
        # Verify rather than assume. `docker rm` is best-effort here (|| true,
        # deliberately — a container that vanished on its own must not abort a
        # deploy), which means a failure to remove otherwise produces no output
        # at all and reads exactly like success. Re-running the sweep is the
        # only honest check, and this is the class of silent failure that let a
        # two-week-old agent container survive every CLEAN unnoticed.
        local remaining; remaining=$(sweep_agent_container_ids)
        if [ -n "$remaining" ]; then
            echo "⚠️  These agent containers were NOT removed and will keep serving from their old image:" >&2
            echo "$remaining" | sed 's/^/     /' >&2
            echo "   Remove them by hand ('docker rm -f <id>') — NanoClaw respawns each group's container from the current image on its next message." >&2
        fi
    else
        # Distinguish "nothing to sweep" from "swept". A live install had this
        # report zero for weeks while a stale container was demonstrably still
        # running, because the matcher missed it — so say which of the two
        # this is, and give the command that answers it independently.
        echo "🐳 No agent containers found for this install (nothing to replace)."
        echo "   If an agent container IS running, this line means the sweep didn't match it — check with:"
        echo "     docker ps --filter 'name=nanoclaw-v2-' --format '{{.Names}}\t{{.Image}}\t{{.CreatedAt}}'"
    fi
    # Every caller of this function has just invalidated whatever the last
    # smoke test observed: TEARDOWN and CLEAN destroy the orchestrator's own
    # ephemeral state (including /root/.claude, per entrypoint.sh's own
    # comment) plus every agent container, and the two post-image-rebuild
    # sweeps further below replace every agent container with one built from
    # a different image. In all four cases a prior smoke-test record is no
    # longer evidence about the environment that exists now. Deleting it here
    # — at the single point they all go through, rather than at each call
    # site — is what makes entrypoint.sh's standing instruction ("run the
    # checklist if this file is missing") correctly re-trigger afterward.
    #
    # Note this is now reachable on a FAST deploy too, via the
    # AGENT_IMAGE_NEEDS_REBUILD sweep — which is the point: a FAST run that
    # actually replaced the agent image has changed exactly the thing the
    # smoke test checks. A FAST run that changed nothing never reaches here,
    # so an ordinary restart still leaves the marker (and the admin session's
    # reactive-only mode) alone.
    rm -f "${INSTALL_PATH}/pi-bootstrap-smoke-test.md" 2>/dev/null || true
}

# ---------------------------------------------------------------------------------------
# NanoClaw's own startup tripwire (data/upgrade-state.json vs the running
# code's version) refuses to start whenever they disagree — by design, to
# catch an install whose source was updated outside the sanctioned upgrade
# flow. Every source-sync branch above (fresh clone, CLEAN's hard reset, and
# the plain FAST `git pull`) changes the running code's version, so each one
# needs this run afterward, once the rebuilt dist/index.js is actually what
# gets (re)started — otherwise this script itself becomes exactly the
# "unsanctioned update" the tripwire exists to catch, and NanoClaw crash-
# loops on its own next restart. Confirmed the hard way: a v2.1.53 -> v2.1.54
# source sync with no matching stamp landed NanoClaw in a boot-time circuit-
# breaker loop until `pnpm exec tsx scripts/upgrade-state.ts set` was run by
# hand. No-ops harmlessly on any install predating this script's own
# addition (older NanoClaw versions with no upgrade-state.ts at all).
# ---------------------------------------------------------------------------------------
stamp_upgrade_state() {
    if [ -f "${INSTALL_PATH}/scripts/upgrade-state.ts" ]; then
        echo "🔏 Stamping upgrade-state.json to the freshly-synced code version (sanctioned upgrade flow)..."
        $DOCKER exec "$CONTAINER_NAME" bash -lc "cd '$INSTALL_PATH' && pnpm exec tsx scripts/upgrade-state.ts set" \
            || echo "⚠️  Failed to stamp upgrade-state.json — NanoClaw's own startup tripwire may refuse to start until 'pnpm exec tsx scripts/upgrade-state.ts set' is run manually inside the container." >&2
    fi
}

# ---------------------------------------------------------------------------------------
# Versioned patch blocks — how a patch fix actually reaches an install that
# was already patched by an older version of this script.
#
# The two container/Dockerfile patches below used to test "is this patched?"
# with a content-blind grep for one token the block happens to contain
# ('yt-dlp', 'MNEMON_VERSION'). That answers "some generation of this patch
# is present", never "the CURRENT generation is present" — so once a block
# was in place, every later deploy said "already patched" and left it alone,
# no matter how much the block's text had changed in this repo since. Two
# real fixes shipped to master and then never reached an existing install on
# a FAST deploy because of exactly this: whisper.cpp's -DBUILD_SHARED_LIBS=OFF
# static-link fix, and scheme-gating the NO_PROXY ENV that was breaking
# mnemon's own Ollama connectivity. CLEAN hid the problem (its `git reset
# --hard` deletes the whole block, so the next apply writes current text) —
# which is why it looked like "fixed in master, still broken live" rather
# than an obvious no-op.
#
# So each block is now wrapped in versioned begin/end markers:
#
#   # >>> pi-bootstrap:<id> v<N> >>>
#   ...block...
#   # <<< pi-bootstrap:<id> <<<
#
# giving three distinguishable states instead of two:
#   - current marker present  -> genuinely up to date, no-op
#   - older marker present    -> stale; strip the old block and re-splice
#                                current text (this is the case FAST could
#                                never handle before)
#   - no marker, but the old  -> a block written before markers existed.
#     content signature is       Can't be stripped reliably (both patches
#     present                    splice at the same anchor, so an unmarked
#                                block has no dependable end boundary), so
#                                warn loudly, record it in the manifest, and
#                                say plainly that a CLEAN is what fixes it.
#
# Bump the version constant whenever you change a block's text — that is the
# whole mechanism; an edit without a bump is invisible to an existing
# install, which is the bug this exists to prevent.
# ---------------------------------------------------------------------------------------
MEDIA_TOOLS_PATCH_VERSION=2
MNEMON_PATCH_VERSION=2

# Deletes a marked block (any version) for one patch id, in place. awk rather
# than sed -i, which is not portable between GNU and BSD/macOS.
_strip_patch_block() {
    local file="$1" id="$2" tmp
    tmp=$(mktemp)
    awk -v id="$id" '
        $0 ~ ("^# >>> pi-bootstrap:" id " v") { skip = 1; next }
        skip && $0 ~ ("^# <<< pi-bootstrap:" id " <<<$") { skip = 0; next }
        !skip { print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

# Classifies one patch block's state in $1 against the current version.
# Echoes exactly one of: current | stale-marked | stale-unmarked | absent
# $2 = patch id, $3 = current version, $4 = legacy content signature (a
# grep -q pattern that matches a pre-marker block).
_patch_block_state() {
    local file="$1" id="$2" version="$3" legacy_sig="$4"
    if grep -qF "# >>> pi-bootstrap:${id} v${version} >>>" "$file"; then
        echo current
    elif grep -q "^# >>> pi-bootstrap:${id} v" "$file"; then
        echo stale-marked
    elif grep -q "$legacy_sig" "$file"; then
        echo stale-unmarked
    else
        echo absent
    fi
}

# ---------------------------------------------------------------------------------------
# mnemon patch — adds github.com/mnemon-dev/mnemon persistent memory to
# NanoClaw's own container/Dockerfile and container/entrypoint.sh, following
# the exact steps documented in NanoClaw's own
# .claude/skills/add-mnemon/SKILL.md (verified against the actual skill
# file at https://github.com/nanocoai/nanoclaw/blob/main/.claude/skills/add-mnemon/SKILL.md,
# not guessed). Idempotent, matching that skill's own "already applied"
# checks — safe to call on every deploy, including CLEAN's fresh re-clone.
# ---------------------------------------------------------------------------------------
apply_mnemon_patch() {
    local dockerfile="${INSTALL_PATH}/container/Dockerfile"
    local entry="${INSTALL_PATH}/container/entrypoint.sh"

    MNEMON_PATCH_OK=true
    MNEMON_PATCH_LOG=""
    _mnemon_log() { MNEMON_PATCH_LOG="${MNEMON_PATCH_LOG}- ${1}
"; }

    if [ ! -f "$dockerfile" ] || [ ! -f "$entry" ]; then
        echo "⚠️  Couldn't find container/Dockerfile or container/entrypoint.sh under $INSTALL_PATH" >&2
        echo "   — NanoClaw's own layout may have changed upstream. Skipping the mnemon patch;" >&2
        echo "   apply it manually per https://github.com/mnemon-dev/mnemon/blob/master/README.md#nanoclaw" >&2
        _mnemon_log "**SKIPPED (whole patch)** — container/Dockerfile or container/entrypoint.sh missing; NanoClaw's own layout may have changed. Apply manually: https://github.com/mnemon-dev/mnemon/blob/master/README.md#nanoclaw"
        MNEMON_PATCH_OK=false
        return 1
    fi

    local mnemon_state do_splice=true
    mnemon_state=$(_patch_block_state "$dockerfile" mnemon "$MNEMON_PATCH_VERSION" 'MNEMON_VERSION')
    case "$mnemon_state" in
        current)
            echo "✅ mnemon already patched into container/Dockerfile (v${MNEMON_PATCH_VERSION}, current)."
            _mnemon_log "container/Dockerfile: already patched, current (mnemon binary install v${MNEMON_PATCH_VERSION})"
            do_splice=false
            ;;
        stale-marked)
            echo "♻️  container/Dockerfile has an OLDER mnemon patch block — replacing it with v${MNEMON_PATCH_VERSION}..."
            _strip_patch_block "$dockerfile" mnemon
            _mnemon_log "container/Dockerfile: **UPDATED** — an older mnemon patch block was replaced with v${MNEMON_PATCH_VERSION}. The agent-sandbox image is rebuilt below so this actually takes effect."
            AGENT_IMAGE_NEEDS_REBUILD=true
            ;;
        stale-unmarked)
            # The pre-marker era, and the reason a live install kept reporting
            # mnemon's ollama_available:false long after the fix shipped: an
            # old block bakes `ENV NO_PROXY=host.docker.internal` in
            # unconditionally, the scheme-gated version below doesn't, and the
            # old content-blind check never noticed the difference.
            echo "⚠️  container/Dockerfile contains an mnemon patch block from before this script tracked patch versions." >&2
            echo "   It can't be replaced in place (an unmarked block has no reliable end boundary), so it is being left alone." >&2
            echo "   Run a CLEAN deploy to fix it: CLEAN hard-resets container/Dockerfile to upstream, and this patch then re-applies at v${MNEMON_PATCH_VERSION}." >&2
            echo "   Until then, mnemon may keep reporting ollama_available:false — the old block bakes an unconditional NO_PROXY=host.docker.internal into the image, which breaks the very routing mnemon needs to reach Ollama." >&2
            _mnemon_log "container/Dockerfile: **STALE (needs CLEAN)** — an unversioned, pre-marker mnemon block is present and cannot be replaced in place. Run a CLEAN deploy to reset container/Dockerfile to upstream and re-apply at v${MNEMON_PATCH_VERSION}. Symptom while stale: \`ollama_available: false\`, because the old block bakes an unconditional \`ENV NO_PROXY=host.docker.internal\` into the agent image and that bypasses the proxy routing that actually reaches Ollama."
            MNEMON_PATCH_OK=false
            do_splice=false
            ;;
    esac

    if [ "$do_splice" = true ]; then
        echo "🧠 Patching mnemon binary install into container/Dockerfile..."
        local anchor
        anchor=$(grep -n '^# ---- Bun runtime' "$dockerfile" | head -1 | cut -d: -f1)
        if [ -z "$anchor" ]; then
            echo "❌ Couldn't find the '# ---- Bun runtime' anchor in container/Dockerfile." >&2
            echo "   NanoClaw's Dockerfile may have changed upstream — skipping the mnemon patch;" >&2
            echo "   apply it manually per https://github.com/mnemon-dev/mnemon/blob/master/README.md#nanoclaw" >&2
            _mnemon_log "container/Dockerfile: **SKIPPED** — '# ---- Bun runtime' anchor not found, upstream layout may have changed. Apply manually: https://github.com/mnemon-dev/mnemon/blob/master/README.md#nanoclaw"
            MNEMON_PATCH_OK=false
            return 1
        fi
        # Both opt-in and unset by default — see MNEMON_EMBED_ENDPOINT's own
        # comment above. Baked into the image as plain ENV (not forwarded
        # per-container-spawn like /add-ollama-tool's OLLAMA_HOST) because
        # mnemon runs inside NanoClaw's own container-runner.ts, which this
        # environment doesn't patch — an image-level ENV is the only hook
        # available without touching NanoClaw's TypeScript source.
        local embed_env=""
        if [ -n "$MNEMON_EMBED_ENDPOINT" ]; then
            embed_env="ENV MNEMON_EMBED_ENDPOINT=${MNEMON_EMBED_ENDPOINT}"
            # NanoClaw's own container-runner.ts unconditionally injects
            # HTTPS_PROXY (+ certs) into every agent container for OneCLI's
            # credential injection — verified directly against its source.
            # That only affects https:// URLs by proxy-env-var convention,
            # so NO_PROXY/no_proxy insurance against it only makes sense for
            # an https:// endpoint — same fix /add-ollama-provider's own
            # SKILL.md applies for its analogous ANTHROPIC_BASE_URL-
            # redirection case.
            #
            # Previously applied unconditionally (including for the http://
            # default, on the reasoning that it'd be a harmless no-op there)
            # — that was wrong, confirmed against a real live deploy: on at
            # least one platform this environment runs on, plain
            # http://host.docker.internal:11434 is NOT a direct socket —
            # it's only reachable because HTTPS_PROXY routes it through the
            # platform's own gateway, exactly the same finding already
            # documented at length in apply_ollama_tool_patch()'s own header
            # comment above (NO_PROXY/no_proxy must NOT include
            # host.docker.internal, or that routing is bypassed and the
            # connection fails outright). mnemon has no equivalent of that
            # patch's per-container-spawn ollamaEnvArgs() reassertion — it
            # only ever gets this baked image-level ENV — so an incorrect
            # NO_PROXY here isn't just suboptimal, it's the only value
            # mnemon's Go HTTP client ever sees. Gating this on scheme
            # keeps the original https:// protection while no longer
            # breaking the http:// default this environment ships as-is.
            case "$MNEMON_EMBED_ENDPOINT" in
                https://*)
                    local embed_host
                    embed_host=$(printf '%s' "$MNEMON_EMBED_ENDPOINT" | sed -E 's#^[a-zA-Z]+://##; s#[:/].*$##')
                    if [ -n "$embed_host" ]; then
                        embed_env="${embed_env}
ENV NO_PROXY=${embed_host}
ENV no_proxy=${embed_host}"
                    fi
                    ;;
            esac
            if [ -n "$MNEMON_EMBED_MODEL" ]; then
                embed_env="${embed_env}
ENV MNEMON_EMBED_MODEL=${MNEMON_EMBED_MODEL}"
            fi
        fi
        local tmp; tmp=$(mktemp)
        {
            head -n "$((anchor - 1))" "$dockerfile"
            cat <<MNEMON_DOCKER_BLOCK
# >>> pi-bootstrap:mnemon v${MNEMON_PATCH_VERSION} >>>
# ---- mnemon — persistent agent memory ----------------------------------------
ARG MNEMON_VERSION=${MNEMON_VERSION}
RUN ARCH=\$(dpkg --print-architecture) && \\
    curl -fsSL "https://github.com/mnemon-dev/mnemon/releases/download/v\${MNEMON_VERSION}/mnemon_\${MNEMON_VERSION}_linux_\${ARCH}.tar.gz" \\
    | tar -xz -C /usr/local/bin mnemon && \\
    chmod +x /usr/local/bin/mnemon

ENV MNEMON_DATA_DIR=/home/node/.claude/mnemon
${embed_env}
# <<< pi-bootstrap:mnemon <<<

MNEMON_DOCKER_BLOCK
            tail -n "+${anchor}" "$dockerfile"
        } > "$tmp"
        mv "$tmp" "$dockerfile"
        _mnemon_log "container/Dockerfile: patched (mnemon binary install v${MNEMON_PATCH_VERSION} added)"
        # See apply_media_tools_patch()'s identical flag for why writing the
        # Dockerfile alone isn't enough.
        AGENT_IMAGE_NEEDS_REBUILD=true
    fi

    if grep -q 'mnemon setup' "$entry"; then
        echo "✅ mnemon already wired into container/entrypoint.sh."
        _mnemon_log "container/entrypoint.sh: already wired (mnemon setup)"
    else
        echo "🧠 Wiring mnemon setup into container/entrypoint.sh..."
        local anchor
        anchor=$(grep -n '^set -e$' "$entry" | head -1 | cut -d: -f1)
        if [ -z "$anchor" ]; then
            echo "❌ Couldn't find 'set -e' in container/entrypoint.sh — skipping the mnemon patch;" >&2
            echo "   apply it manually per https://github.com/mnemon-dev/mnemon/blob/master/README.md#nanoclaw" >&2
            _mnemon_log "container/entrypoint.sh: **SKIPPED** — 'set -e' anchor not found, upstream layout may have changed. Apply manually: https://github.com/mnemon-dev/mnemon/blob/master/README.md#nanoclaw"
            MNEMON_PATCH_OK=false
            return 1
        fi
        # "mnemon setup --yes --global" — NOT bare "mnemon setup --yes"
        # (this line's own immediately-prior version) and NOT the
        # original "--target claude-code --yes --global" either. Both
        # earlier versions were reasoned from mnemon's own docs; this one
        # is verified against its actual live behavior instead, which
        # contradicted both:
        #
        # Confirmed directly inside a real agent-sandbox container:
        # bare "mnemon setup --yes" DOES run and DOES auto-detect Claude
        # Code correctly, but it writes hooks to a *project-local*
        # ".claude/settings.json" relative to entrypoint.sh's own working
        # directory (/workspace/group in this image) — a directory that
        # has nothing to do with the *global* "/home/node/.claude/"
        # NanoClaw actually bind-mounts per group and Claude Code
        # actually reads. That's exactly why hooks never showed up in a
        # real deploy even after fixing the flags once already: the
        # command was succeeding, just writing to the wrong file entirely.
        # Adding --global back (confirmed live, same container, same
        # mnemon binary: "mnemon setup --yes --global" correctly targets
        # "~/.claude/settings.json" instead) fixes it. --target claude-code
        # was NOT re-added — auto-detection alone was never the problem,
        # only the local-vs-global path was, and the working command
        # above didn't need it either.
        local tmp; tmp=$(mktemp)
        {
            head -n "$anchor" "$entry"
            echo ""
            echo 'mnemon setup --yes --global >/dev/stderr 2>&1'
            tail -n "+$((anchor + 1))" "$entry"
        } > "$tmp"
        # mktemp's own file starts non-executable regardless of $entry's
        # mode — mv-ing it straight over $entry silently dropped
        # entrypoint.sh's exec bit (755 -> 644) on every patch application
        # until this line was added. `chmod +x` (not `chmod --reference`,
        # which BSD/macOS chmod doesn't support) to stay portable.
        chmod +x "$tmp"
        mv "$tmp" "$entry"
        _mnemon_log "container/entrypoint.sh: patched (mnemon setup --yes --global wired in)"
    fi
}

# ---------------------------------------------------------------------------------------
# Telegram-import self-heal — defends against upstream NanoClaw silently
# dropping `import './telegram.js';` from its own channels barrel
# (src/channels/index.ts, dist/channels/index.js). Confirmed directly
# against a live deploy: upstream commit 675a6d87 ("remove accidentally
# merged Telegram channel code") removed that import; a plain FAST `git
# pull --ff-only` (the non-CLEAN sync path just above) picked the change up
# with no error anywhere — registerChannelAdapter('telegram', ...) just
# stopped running, and the bot went silently unresponsive (messages sent in
# the meantime were queued upstream by Telegram and delivered once fixed).
#
# Unlike apply_mnemon_patch/apply_media_tools_patch above, this isn't a
# feature this environment is adding on top of stock NanoClaw — Telegram
# support ships in upstream NanoClaw itself. This patch exists purely to
# restore wiring upstream has, at least once, deleted out from under itself.
# Applied unconditionally (not gated on NANOCLAW_SETUP), same reasoning as
# apply_ollama_tool_patch: Telegram is a general NanoClaw capability, not
# specific to the mnemon profile.
#
# Dependency guard + orphan quarantine (added after two rounds of real
# CLEAN build failures — see docs/lessons-learned/nanoclaw-mnemon.md for
# the full history of getting this wrong twice before landing here).
#
# Dependency guard checks *resolvability*, not just package.json — a real
# live deploy (2026-08-06, see pi-bootstrap-patch-fixes.md) hit a false
# SKIP: package.json genuinely lacked "@chat-adapter/telegram" (upstream
# dropped it in commit 25687dc), but the package was still fully present
# in pnpm's content-addressable virtual store
# (node_modules/.pnpm/@chat-adapter+telegram@*/), including its own nested
# deps — only the top-level node_modules/@chat-adapter/telegram symlink
# was missing (pruned by a `pnpm install` run after package.json no longer
# listed it; pnpm's store prune is a separate, not-automatically-triggered
# step, so the store entry survived). grep-on-package.json alone can't see
# that: it treats "not listed" and "not resolvable" as the same case, when
# they aren't. So this guard now checks, in order: (1) does the top-level
# symlink already exist (dangling links correctly fail this, since `-e`
# follows the link); (2) if not, does the package exist in the local pnpm
# virtual store anyway — if so, recreate just the missing top-level
# symlink and treat the dependency as present; (3) only if neither of
# those find it, fall back to the package.json listing, which is the only
# signal available on a fresh install before `pnpm install` has ever
# populated node_modules at all.
#
# Checked directly against upstream's actual git history (not guessed):
# commit 675a6d87 ("remove accidentally merged Telegram channel code",
# 2026-03-25) was a CLEAN, complete removal — src/channels/telegram.ts,
# its test file, and the barrel import were all deleted together in that
# one commit. `@chat-adapter/telegram` was dropped from package.json
# separately, over a month later, in commit 25687dc. Neither commit left
# upstream itself in a broken state at any point — a prior version of
# this comment claimed otherwise ("a half removal"); that was wrong,
# reasoned from a live build error alone rather than upstream's actual
# history, and this session corrected it after actually checking.
#
# So where does a real deploy's own src/channels/telegram.ts (still
# importing the now-gone @chat-adapter/telegram) come from, if upstream's
# removal was clean? Not from `git pull`/`git reset --hard` — both only
# ever touch tracked files, and upstream's history never re-adds
# telegram.ts once 675a6d87 lands. The only mechanism that plants a new,
# untracked telegram.ts into an existing install is NanoClaw's own
# /add-telegram-style channel skill (see src/channels/index.ts's own
# comment: "channel skills ... copy their module from the `channels`
# branch and append a self-registration import") being run at some point
# against this specific deployment. Once that file exists on disk,
# NOTHING in a normal git sync — FAST's `git pull` or CLEAN's
# `git reset --hard` — ever removes it again: reset --hard only resets
# tracked files to match the target commit, and an untracked file has no
# tracked counterpart to reset away. It just sits there, orphaned,
# forever, once its own dependency stops existing.
#
# Why that alone breaks a CLEAN build even with NO import anywhere
# referencing it: NanoClaw's own tsconfig.json sets
# `"include": ["src/**/*"]` — confirmed directly against the real file —
# so tsc type-checks every .ts file physically present under src/,
# whether anything imports it or not. An orphaned telegram.ts with a
# dangling `@chat-adapter/telegram` import fails the build on its own,
# independent of whatever this function does or doesn't do to the barrel
# import. The dependency-guard fix from the previous round (only restore
# the barrel import if the dependency is still in package.json) was
# necessary but not sufficient — it stopped this function from making
# things worse, but did nothing about an orphan that was already there
# before this function ever ran.
#
# So this function now does two things: (1) restore the barrel import,
# same as before, only when the dependency actually resolves; (2)
# unconditionally quarantine (rename out of the tsc-compiled tree, never
# delete) src/channels/telegram.ts and its test file whenever they exist
# AND the dependency does NOT resolve — the one combination that's
# guaranteed to break every future CLEAN build otherwise. Quarantining
# instead of deleting keeps the file recoverable (e.g. if the operator
# wants to vendor @chat-adapter/telegram themselves) while getting it out
# of tsc's `include` glob, which only recognizes known source extensions
# — a `.orphaned-by-pi-bootstrap` suffix is enough on its own.
# ---------------------------------------------------------------------------------------
apply_telegram_import_patch() {
    TELEGRAM_IMPORT_PATCH_OK=true
    TELEGRAM_IMPORT_PATCH_LOG=""
    _telegram_import_log() { TELEGRAM_IMPORT_PATCH_LOG="${TELEGRAM_IMPORT_PATCH_LOG}- ${1}
"; }

    # Quarantine pass — runs regardless of package.json's state below,
    # because an orphaned telegram.ts breaks the build purely by existing
    # (tsconfig's `include: ["src/**/*"]`), whether or not the dependency
    # check that follows ever restores the barrel import. Only fires when
    # the dependency is actually missing (i.e. the file genuinely can't
    # build) — a real, working local Telegram setup with the dependency
    # present is left alone.
    local dep_present=false
    local pkg_json="${INSTALL_PATH}/package.json"
    local telegram_link="${INSTALL_PATH}/node_modules/@chat-adapter/telegram"
    local pnpm_store_dir="${INSTALL_PATH}/node_modules/.pnpm"
    local telegram_store telegram_store_name

    if [ -e "$telegram_link" ]; then
        # -e follows the symlink — a dangling link (store entry gone too)
        # correctly falls through to the store/package.json checks below.
        dep_present=true
        _telegram_import_log "node_modules/@chat-adapter/telegram: already resolvable (symlink present)"
    elif [ -d "$pnpm_store_dir" ]; then
        telegram_store=$(find "$pnpm_store_dir" -maxdepth 1 -type d -name '@chat-adapter+telegram@*' 2>/dev/null | head -1)
        if [ -n "$telegram_store" ] && [ -d "${telegram_store}/node_modules/@chat-adapter/telegram" ]; then
            telegram_store_name=$(basename "$telegram_store")
            mkdir -p "${INSTALL_PATH}/node_modules/@chat-adapter"
            ln -s "../.pnpm/${telegram_store_name}/node_modules/@chat-adapter/telegram" "$telegram_link"
            dep_present=true
            echo "🔗 Recreated missing node_modules/@chat-adapter/telegram symlink — package.json no longer lists it, but it's still present in pnpm's virtual store (see pi-bootstrap-patch-fixes.md 2026-08-06 entry)." >&2
            _telegram_import_log "node_modules/@chat-adapter/telegram: **RESTORED** — symlink recreated pointing at pnpm's virtual store (${telegram_store_name}); package.json listing was stale/absent but the store still had it."
        fi
    fi
    if [ "$dep_present" = false ] && [ -f "$pkg_json" ] && grep -q '"@chat-adapter/telegram"' "$pkg_json"; then
        # Neither the symlink nor the pnpm store has it yet — this is the
        # fresh-install case, before `pnpm install` has ever populated
        # node_modules. Trust package.json here; the upcoming install step
        # will fetch it.
        dep_present=true
    fi
    if [ "$dep_present" = false ]; then
        local orphan tgt
        for orphan in src/channels/telegram.ts src/channels/telegram.test.ts; do
            tgt="${INSTALL_PATH}/${orphan}"
            if [ -f "$tgt" ]; then
                mv "$tgt" "${tgt}.orphaned-by-pi-bootstrap"
                echo "🧹 Quarantined orphaned ${orphan} (its own @chat-adapter/telegram dependency is gone; tsc would otherwise fail on it regardless of the barrel import — see this function's own header comment)." >&2
                _telegram_import_log "${orphan}: **QUARANTINED** — renamed to ${orphan}.orphaned-by-pi-bootstrap (dependency missing from package.json; tsconfig's include: [\"src/**/*\"] would otherwise fail the build on this file alone). Restore it manually once @chat-adapter/telegram is available again."
            fi
        done
    fi

    if [ ! -f "$pkg_json" ]; then
        echo "⚠️  Couldn't find package.json under $INSTALL_PATH — skipping the telegram-import patch (can't verify its dependency is installable)." >&2
        _telegram_import_log "**SKIPPED (barrel import)** — package.json missing, can't verify @chat-adapter/telegram is still a listed dependency."
        TELEGRAM_IMPORT_PATCH_OK=false
        return 1
    fi
    if [ "$dep_present" = false ]; then
        echo "⚠️  telegram.ts's own dependency (@chat-adapter/telegram) is no longer in package.json — skipping the telegram-import patch." >&2
        echo "   Restoring the barrel import would break the build (Cannot find module '@chat-adapter/telegram'); NanoClaw dropped this dependency in commit 25687dc, after cleanly removing telegram.ts itself in 675a6d87." >&2
        _telegram_import_log "**SKIPPED (barrel import)** — @chat-adapter/telegram missing from package.json (dropped upstream in commit 25687dc); restoring the import would break the build. See pi-bootstrap-patch-fixes.md."
        # Strip a STALE barrel import too, not just skip adding a new one —
        # the quarantine pass above just renamed telegram.ts/telegram.js out
        # from under any import that already points at it (e.g. left behind
        # by an earlier run of this function before this guard existed, or
        # by a real prior /add-telegram skill run). Left in place, that
        # import would now fail to resolve './telegram.js' at all, breaking
        # the build in a different way than the one this function exists to
        # prevent. Idempotent either way — a fresh checkout with no barrel
        # import present just no-ops here.
        local rel f
        for rel in src/channels/index.ts dist/channels/index.js; do
            f="${INSTALL_PATH}/${rel}"
            if [ -f "$f" ] && grep -q "^import '\./telegram\.js';" "$f"; then
                grep -v "^import '\./telegram\.js';" "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
                echo "🧹 Removed a stale \"import './telegram.js';\" from ${rel} (its target was just quarantined; leaving the import would break the build differently)." >&2
                _telegram_import_log "${rel}: stale barrel import removed (target file quarantined, dependency unresolvable)"
            fi
        done
        TELEGRAM_IMPORT_PATCH_OK=false
        return 1
    fi

    # Dependency resolves now — undo any quarantine a previous run applied
    # incorrectly (e.g. under the old package.json-only guard, which would
    # have quarantined telegram.ts on the exact false-SKIP scenario this
    # function's dependency guard now avoids; see pi-bootstrap-patch-fixes.md
    # 2026-08-06 entry).
    local orphan tgt
    for orphan in src/channels/telegram.ts src/channels/telegram.test.ts; do
        tgt="${INSTALL_PATH}/${orphan}.orphaned-by-pi-bootstrap"
        if [ -f "$tgt" ]; then
            mv "$tgt" "${INSTALL_PATH}/${orphan}"
            echo "♻️  Restored ${orphan} from a previous incorrect quarantine — its dependency resolves now." >&2
            _telegram_import_log "${orphan}: **RESTORED** — un-quarantined (dependency now resolves)"
        fi
    done

    local any_patched=false
    local rel f anchor tmp
    for rel in src/channels/index.ts dist/channels/index.js; do
        f="${INSTALL_PATH}/${rel}"
        if [ ! -f "$f" ]; then
            echo "⚠️  Couldn't find ${rel} under $INSTALL_PATH — skipping the telegram-import patch for it." >&2
            _telegram_import_log "${rel}: **SKIPPED** — file missing, NanoClaw's own layout may have changed."
            TELEGRAM_IMPORT_PATCH_OK=false
            continue
        fi

        if grep -q "^import '\./telegram\.js';" "$f"; then
            _telegram_import_log "${rel}: already patched (telegram import present)"
            continue
        fi

        anchor=$(grep -n "^import '\./cli\.js';" "$f" | head -1 | cut -d: -f1)
        if [ -z "$anchor" ]; then
            echo "❌ Couldn't find the \"import './cli.js';\" anchor in ${rel} — skipping the telegram-import patch." >&2
            echo "   NanoClaw's channels barrel may have changed upstream; add \"import './telegram.js';\" manually." >&2
            _telegram_import_log "${rel}: **SKIPPED** — \"import './cli.js';\" anchor not found, upstream layout may have changed. Add \"import './telegram.js';\" manually."
            TELEGRAM_IMPORT_PATCH_OK=false
            continue
        fi

        tmp=$(mktemp)
        {
            head -n "$anchor" "$f"
            echo "import './telegram.js';"
            tail -n "+$((anchor + 1))" "$f"
        } > "$tmp"
        mv "$tmp" "$f"
        any_patched=true
        _telegram_import_log "${rel}: patched (telegram import restored)"
    done

    if [ "$any_patched" = true ]; then
        echo "📡 Restored the Telegram channel import — upstream NanoClaw has dropped it before (commit 675a6d87)."
    fi
}

# ---------------------------------------------------------------------------------------
# yt-dlp/ffmpeg/whisper.cpp patch — gives the AGENT itself (not just the
# orchestrator, which already has these — see the Dockerfile in this
# directory) the ability to pull down and transcribe a video when a user
# just pastes a URL in chat, via its own Bash tool. Same idempotent
# text-splice mechanism as apply_mnemon_patch() above, same anchor
# ('# ---- Bun runtime' in NanoClaw's own container/Dockerfile) — composes
# correctly with that patch regardless of which one runs first, since each
# one re-finds the anchor's current position in the file rather than
# assuming a fixed line number.
#
# No model file is baked in here either, same reasoning as the
# orchestrator's own copy (sizes 148MB-3GB+, a user choice) — but unlike the
# orchestrator, there's no shared/global mount into every agent container
# (verified directly against NanoClaw's own container-runner.ts buildMounts():
# only that specific group's own folder is mounted, at /workspace/agent, not
# $NANOCLAW_INSTALL_PATH itself) — so the model has to live inside each
# group's own folder that wants transcription, not the top-level install
# path. See the README's "Transcribing Audio/Video" section for the exact
# one-time download command and path.
# ---------------------------------------------------------------------------------------
apply_media_tools_patch() {
    local dockerfile="${INSTALL_PATH}/container/Dockerfile"

    MEDIA_TOOLS_PATCH_OK=true
    MEDIA_TOOLS_PATCH_LOG=""
    _media_tools_log() { MEDIA_TOOLS_PATCH_LOG="${MEDIA_TOOLS_PATCH_LOG}- ${1}
"; }

    if [ ! -f "$dockerfile" ]; then
        echo "⚠️  Couldn't find container/Dockerfile under $INSTALL_PATH — skipping the media-tools patch." >&2
        _media_tools_log "**SKIPPED (whole patch)** — container/Dockerfile missing; NanoClaw's own layout may have changed."
        MEDIA_TOOLS_PATCH_OK=false
        return 1
    fi

    local state
    state=$(_patch_block_state "$dockerfile" media-tools "$MEDIA_TOOLS_PATCH_VERSION" 'yt-dlp')
    case "$state" in
        current)
            echo "✅ yt-dlp/ffmpeg/whisper.cpp already patched into container/Dockerfile (v${MEDIA_TOOLS_PATCH_VERSION}, current)."
            _media_tools_log "container/Dockerfile: already patched, current (yt-dlp/ffmpeg/whisper.cpp v${MEDIA_TOOLS_PATCH_VERSION})"
            return 0
            ;;
        stale-marked)
            echo "♻️  container/Dockerfile has an OLDER media-tools patch block — replacing it with v${MEDIA_TOOLS_PATCH_VERSION}..."
            _strip_patch_block "$dockerfile" media-tools
            _media_tools_log "container/Dockerfile: **UPDATED** — an older media-tools patch block was replaced with v${MEDIA_TOOLS_PATCH_VERSION}. The agent-sandbox image is rebuilt below so this actually takes effect."
            AGENT_IMAGE_NEEDS_REBUILD=true
            ;;
        stale-unmarked)
            # The pre-marker era. Notably this is the state that kept the
            # whisper-cli static-link fix (-DBUILD_SHARED_LIBS=OFF) out of
            # already-patched installs: the old check saw 'yt-dlp', called it
            # patched, and never looked at the cmake line again.
            echo "⚠️  container/Dockerfile contains a media-tools patch block from before this script tracked patch versions." >&2
            echo "   It can't be replaced in place (an unmarked block has no reliable end boundary), so it is being left alone." >&2
            echo "   Run a CLEAN deploy to fix it: CLEAN hard-resets container/Dockerfile to upstream, and this patch then re-applies at v${MEDIA_TOOLS_PATCH_VERSION}." >&2
            echo "   Until then, whisper-cli in the agent sandbox may still be the older dynamically-linked build (fails with 'libwhisper.so.1: cannot open shared object file')." >&2
            _media_tools_log "container/Dockerfile: **STALE (needs CLEAN)** — an unversioned, pre-marker media-tools block is present and cannot be replaced in place. Run a CLEAN deploy to reset container/Dockerfile to upstream and re-apply at v${MEDIA_TOOLS_PATCH_VERSION}. Symptom while stale: whisper-cli fails with \`libwhisper.so.1: cannot open shared object file\` because the old block linked it dynamically against libs deleted from the image."
            MEDIA_TOOLS_PATCH_OK=false
            return 0
            ;;
    esac

    echo "🎙️  Patching yt-dlp/ffmpeg/whisper.cpp into container/Dockerfile (agent sandbox)..."
    local anchor
    anchor=$(grep -n '^# ---- Bun runtime' "$dockerfile" | head -1 | cut -d: -f1)
    if [ -z "$anchor" ]; then
        echo "❌ Couldn't find the '# ---- Bun runtime' anchor in container/Dockerfile." >&2
        echo "   NanoClaw's Dockerfile may have changed upstream — skipping the media-tools patch;" >&2
        echo "   apply it manually per this environment's README." >&2
        _media_tools_log "container/Dockerfile: **SKIPPED** — '# ---- Bun runtime' anchor not found, upstream layout may have changed. Apply manually per this environment's README."
        MEDIA_TOOLS_PATCH_OK=false
        return 1
    fi
    local tmp; tmp=$(mktemp)
    {
        head -n "$((anchor - 1))" "$dockerfile"
        # Unquoted heredoc delimiter ONLY on the marker line (so the version
        # interpolates); the block body below stays inside its own quoted
        # heredoc so nothing in it is subject to shell expansion.
        cat <<MEDIA_TOOLS_MARKER_BEGIN
# >>> pi-bootstrap:media-tools v${MEDIA_TOOLS_PATCH_VERSION} >>>
MEDIA_TOOLS_MARKER_BEGIN
        cat <<'MEDIA_TOOLS_DOCKER_BLOCK'
# ---- media tools — yt-dlp / ffmpeg / whisper.cpp, so the agent itself can
# transcribe video/audio when given a URL, via its own Bash tool -----------
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# whisper.cpp (whisper-cli) — no Debian package exists, built from source.
# build-essential/cmake/clang installed and purged again in this same layer
# so only the compiled binary adds to the final image.
#
# Built with clang, not GCC: confirmed directly against a real build
# failure on arm64 — Debian bookworm's default GCC 12 hits a known
# ggml/whisper.cpp incompatibility ("inlining failed in call to
# 'always_inline' float16x8_t vfmaq_f16(...): target specific option
# mismatch") in ggml's ARM NEON fp16 vector-arithmetic codepath — GCC 12
# fails outright where GCC 13+ or clang don't. See the orchestrator's own
# Dockerfile (environments/nanoclaw-mnemon/Dockerfile) for the fuller
# writeup — this block mirrors that fix.
#
# -DBUILD_SHARED_LIBS=OFF: without it, cmake links whisper-cli dynamically
# against libwhisper.so.1/libggml*.so, which live under /tmp/whisper.cpp/build
# and get deleted along with the rest of that tree two lines down — only the
# binary is copied out. The resulting whisper-cli then fails at runtime with
# "libwhisper.so.1: cannot open shared object file: No such file or
# directory" (confirmed directly against a live agent container). A static
# build removes the runtime dependency entirely rather than relying on some
# other mechanism to place matching libs on LD_LIBRARY_PATH.
RUN apt-get update && apt-get install -y --no-install-recommends build-essential cmake clang \
    && git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git /tmp/whisper.cpp \
    && cmake -B /tmp/whisper.cpp/build -S /tmp/whisper.cpp -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ -DBUILD_SHARED_LIBS=OFF \
    && cmake --build /tmp/whisper.cpp/build --config Release -j"$(nproc)" \
    && cp /tmp/whisper.cpp/build/bin/whisper-cli /usr/local/bin/whisper-cli \
    && rm -rf /tmp/whisper.cpp \
    && apt-get purge -y --auto-remove build-essential cmake clang \
    && rm -rf /var/lib/apt/lists/*

# yt-dlp — standalone binary release, no Python install needed just for it.
# Must be an arch-matched `yt-dlp_linux*` asset, not the plain `yt-dlp`
# asset: that one is a zipimport script (shebang `#!/usr/bin/env python3`)
# that still needs a system python3 on PATH — this image has none, by
# design. This agent-sandbox image is built on whatever host runs it (arm64
# on a Raspberry Pi or Apple Silicon Mac, amd64 on an Intel Mac via
# OrbStack/Docker Desktop), so the asset is picked via `uname -m` at build
# time rather than hardcoded. See the orchestrator's own Dockerfile
# (environments/nanoclaw-mnemon/Dockerfile) for the fuller writeup — this
# block mirrors that fix.
RUN set -eu; \
    case "$(uname -m)" in \
        x86_64) yt_asset=yt-dlp_linux ;; \
        aarch64) yt_asset=yt-dlp_linux_aarch64 ;; \
        armv7l) yt_asset=yt-dlp_linux_armv7l ;; \
        *) echo "Unsupported architecture for yt-dlp: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/yt-dlp/yt-dlp/releases/latest/download/${yt_asset}" -o /usr/local/bin/yt-dlp \
    && chmod a+rx /usr/local/bin/yt-dlp

# <<< pi-bootstrap:media-tools <<<

MEDIA_TOOLS_DOCKER_BLOCK
        tail -n "+${anchor}" "$dockerfile"
    } > "$tmp"
    mv "$tmp" "$dockerfile"
    _media_tools_log "container/Dockerfile: patched (yt-dlp/ffmpeg/whisper.cpp v${MEDIA_TOOLS_PATCH_VERSION} added)"
    # container/Dockerfile changed on disk — inert until the agent-sandbox
    # image is rebuilt from it. CLEAN always rebuilds; FAST only does when
    # this flag says a patch actually wrote something.
    AGENT_IMAGE_NEEDS_REBUILD=true
}

# ---------------------------------------------------------------------------------------
# /add-ollama-tool patch — registers an MCP server exposing local Ollama
# models (ollama_list_models, ollama_generate, and opt-in admin tools) to
# EVERY per-group agent container, gated on OLLAMA_ADMIN_TOOLS rather than
# NANOCLAW_SETUP — this is a general agent capability, not a mnemon
# feature, so it applies to both the "mnemon" and "plain" profiles (called
# unconditionally below, outside that if/else).
#
# Written directly from NanoClaw's own actual source, not the skill's
# documented output — the shipped /add-ollama-tool skill's own
# ollama-env.ts never actually reads .env (only process.env, which
# NanoClaw's own readEnvFile() doesn't populate) — confirmed directly by a
# live user who ran it, hit this, and fixed it by hand. That fix (config.ts
# exporting OLLAMA_HOST/OLLAMA_ADMIN_TOOLS the same way every other .env
# value is) is baked into the patch text below from the start.
#
# NO_PROXY/no_proxy is explicitly re-asserted on every agent container
# spawn (see ollama-env.ts's own header comment for the full mechanism).
# This one detail went through three revisions before landing here —
# worth recording since the next drift-diagnosis session will otherwise
# re-derive the same confusion from scratch:
#   1. First version: forced NO_PROXY based on a diagnosis that OneCLI's
#      own default was `host.docker.internal`, breaking Ollama routing.
#   2. A live, timestamped env dump from the actual debugging session
#      overturned that — OneCLI's real default was already NO_PROXY=<its
#      own gateway IP> the whole time, never `host.docker.internal`. The
#      actual original bug was OLLAMA_HOST itself pointing at that same
#      gateway IP. This version (wrongly) concluded NO_PROXY didn't need
#      touching at all, and removed it.
#   3. A follow-up reconciliation (the admin `claude` session inspecting
#      the live container directly, with NanoClaw's own container-runner.ts
#      source in hand) restored it: host.docker.internal:11434 is NOT a
#      direct Ollama socket on this platform — it only works because
#      HTTPS_PROXY routes it through OneCLI's own gateway. If NO_PROXY
#      ever includes host.docker.internal, that routing is bypassed and
#      the connection fails outright. OneCLI's own default correctly
#      excludes host.docker.internal — but this repo's own
#      apply_mnemon_patch() bakes `ENV NO_PROXY=host.docker.internal` into
#      the agent-sandbox Dockerfile for unrelated reasons, and `docker run
#      -e` (ollamaEnvArgs()'s own output, applied at container-spawn time)
#      wins over that Dockerfile ENV — so explicitly re-asserting the
#      correct value here is what actually guards against it, not an
#      assumption that the platform default alone is sufficient.
# Confirmed, not just assumed: onecli.applyContainerConfig() (which runs in
# container-runner.ts AFTER ollamaEnvArgs() pushes its own args, so it would
# win on any key it also sets) pushes -e args from OneCLI's server-provided
# config.env — checked directly against @onecli-sh/sdk's own source by
# NanoClaw's own admin session. That response carries HTTPS_PROXY/
# HTTP_PROXY (+ lowercase), NODE_EXTRA_CA_CERTS, NODE_USE_ENV_PROXY, GIT_*,
# and CLAUDE_CODE_OAUTH_TOKEN — no NO_PROXY entry at all. So this function's
# own NO_PROXY value is never contended with or overridden downstream; the
# mechanism above works as intended, not just in theory.
#
# Idempotent per file: the two brand-new files this function owns
# (ollama-mcp-stdio.ts, ollama-env.ts) are only written if missing, NOT
# unconditionally overwritten on every deploy — if the admin `claude`
# session ever hand-fixes either file live (see the pi-bootstrap-patches.md
# manifest write_patches_manifest() writes right after this function runs,
# and its sibling pi-bootstrap-patch-fixes.md), that fix survives every
# later FAST/CLEAN run untouched, since this function only ever fills in a
# MISSING file, never replaces an existing one. The three files this
# function splices INTO
# (index.ts, config.ts, container-runner.ts) use the same marker-based
# idempotency as apply_mnemon_patch/apply_media_tools_patch above, and are
# excluded from CHANNEL_SKILL_MODS's snapshot-and-reapply pathspec below for
# the identical reason those two functions' own files are: this function
# already owns re-applying itself, idempotently, after every CLEAN reset —
# letting the generic reapply mechanism ALSO touch these files risks
# reapplying stale patch text that then satisfies this function's own
# idempotency check and never gets updated again (the exact bug already
# hit once for apply_media_tools_patch, see that function's own comment).
#
# Every anchor is checked before use — if NanoClaw's upstream source has
# changed shape since this was written, the affected sub-patch is skipped
# with a loud warning and a link to the skill's own doc
# (https://github.com/nanocoai/nanoclaw/blob/main/.claude/skills/add-ollama-tool/SKILL.md)
# rather than guessing. Every sub-patch's actual result — applied,
# already-present, or skipped-with-reason — is captured in
# OLLAMA_PATCH_LOG and OLLAMA_PATCH_OK for the manifest this function
# writes at the end, so a broken patch is diagnosable from inside the
# container without needing to reconstruct what run.sh attempted.
# ---------------------------------------------------------------------------------------
apply_ollama_tool_patch() {
    local agent_src="${INSTALL_PATH}/container/agent-runner/src"
    local index_ts="${agent_src}/index.ts"
    local mcp_stdio="${agent_src}/ollama-mcp-stdio.ts"
    local ollama_env="${INSTALL_PATH}/src/ollama-env.ts"
    local config_ts="${INSTALL_PATH}/src/config.ts"
    local container_runner="${INSTALL_PATH}/src/container-runner.ts"
    local skill_url="https://github.com/nanocoai/nanoclaw/blob/main/.claude/skills/add-ollama-tool/SKILL.md"

    OLLAMA_PATCH_OK=true
    OLLAMA_PATCH_LOG=""
    _ollama_log() { OLLAMA_PATCH_LOG="${OLLAMA_PATCH_LOG}- ${1}
"; }

    if [ ! -f "$index_ts" ] || [ ! -f "$config_ts" ] || [ ! -f "$container_runner" ]; then
        echo "⚠️  Couldn't find container/agent-runner/src/index.ts, src/config.ts, or src/container-runner.ts under $INSTALL_PATH" >&2
        echo "   — NanoClaw's own layout may have changed upstream. Skipping the Ollama-tool patch;" >&2
        echo "   apply it manually per $skill_url" >&2
        _ollama_log "**SKIPPED (whole patch)** — one or more expected source files are missing; NanoClaw's own layout may have changed. Apply manually: $skill_url"
        OLLAMA_PATCH_OK=false
        return 1
    fi

    # 1. container/agent-runner/src/ollama-mcp-stdio.ts — the MCP server
    # itself. Fully owned by this patch (nothing upstream creates this
    # file), so this only ever fills it in if missing — never overwrites
    # an existing copy, live-fixed or not.
    if [ -f "$mcp_stdio" ]; then
        echo "✅ ollama-mcp-stdio.ts already present."
        _ollama_log "ollama-mcp-stdio.ts: already present (left untouched — could be a prior deploy's copy or a live admin-session fix)"
    else
        echo "🦙 Writing container/agent-runner/src/ollama-mcp-stdio.ts..."
        cat > "$mcp_stdio" <<'OLLAMA_MCP_STDIO_TS'
/**
 * Ollama MCP Server for NanoClaw
 * Exposes local Ollama models (native Ollama REST API, /api/*) as tools for the
 * container agent. Uses host.docker.internal to reach the host's Ollama daemon
 * from inside the container.
 *
 * Ollama runs locally and is keyless — there are no credentials to thread. The
 * only configuration is the base URL (OLLAMA_HOST) and an opt-in flag for the
 * library-management tools (OLLAMA_ADMIN_TOOLS).
 */

import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';

import fs from 'fs';
import path from 'path';

const OLLAMA_HOST =
  process.env.OLLAMA_HOST || 'http://host.docker.internal:11434';
const OLLAMA_ADMIN_TOOLS = process.env.OLLAMA_ADMIN_TOOLS === 'true';
const OLLAMA_STATUS_FILE = '/workspace/ipc/ollama_status.json';

function log(msg: string): void {
  console.error(`[OLLAMA] ${msg}`);
}

function writeStatus(status: string, detail?: string): void {
  try {
    const data = { status, detail, timestamp: new Date().toISOString() };
    const tmpPath = `${OLLAMA_STATUS_FILE}.tmp`;
    fs.mkdirSync(path.dirname(OLLAMA_STATUS_FILE), { recursive: true });
    fs.writeFileSync(tmpPath, JSON.stringify(data));
    fs.renameSync(tmpPath, OLLAMA_STATUS_FILE);
  } catch {
    /* best-effort */
  }
}

async function ollamaFetch(
  apiPath: string,
  options?: RequestInit,
): Promise<Response> {
  const url = `${OLLAMA_HOST}${apiPath}`;
  try {
    return await fetch(url, options);
  } catch (err) {
    // Fallback to localhost if host.docker.internal fails
    if (OLLAMA_HOST.includes('host.docker.internal')) {
      const fallbackUrl = url.replace('host.docker.internal', 'localhost');
      return await fetch(fallbackUrl, options);
    }
    throw err;
  }
}

function formatBytes(bytes?: number): string {
  if (bytes === undefined || bytes === null) return '?';
  const gb = bytes / 1024 / 1024 / 1024;
  if (gb >= 1) return `${gb.toFixed(1)}GB`;
  const mb = bytes / 1024 / 1024;
  return `${mb.toFixed(0)}MB`;
}

const server = new McpServer({
  name: 'ollama',
  version: '1.0.0',
});

server.tool(
  'ollama_list_models',
  'List all models installed in the local Ollama daemon. Use this to see which models are available before calling ollama_generate.',
  {},
  async () => {
    log('Listing models...');
    writeStatus('listing', 'Listing installed models');
    try {
      const res = await ollamaFetch('/api/tags');
      if (!res.ok) {
        return {
          content: [
            {
              type: 'text' as const,
              text: `Ollama API error: ${res.status} ${res.statusText}`,
            },
          ],
          isError: true,
        };
      }

      const data = (await res.json()) as {
        models?: Array<{
          name: string;
          size?: number;
          details?: { family?: string; parameter_size?: string };
        }>;
      };
      const models = data.models || [];

      if (models.length === 0) {
        return {
          content: [
            {
              type: 'text' as const,
              text: 'No models installed. Pull one on the host with `ollama pull <model>` (e.g. `ollama pull llama3.2`).',
            },
          ],
        };
      }

      const list = models
        .map((m) => {
          const family = m.details?.family ? ` ${m.details.family}` : '';
          const params = m.details?.parameter_size
            ? ` ${m.details.parameter_size}`
            : '';
          return `- ${m.name} (${formatBytes(m.size)}${family}${params})`;
        })
        .join('\n');

      log(`Found ${models.length} models`);
      return {
        content: [
          { type: 'text' as const, text: `Installed models:\n${list}` },
        ],
      };
    } catch (err) {
      return {
        content: [
          {
            type: 'text' as const,
            text: `Failed to connect to Ollama at ${OLLAMA_HOST}: ${err instanceof Error ? err.message : String(err)}`,
          },
        ],
        isError: true,
      };
    }
  },
);

server.tool(
  'ollama_generate',
  'Send a prompt to a local Ollama model and get a response. Good for cheaper/faster tasks like summarization, translation, or general queries. Use ollama_list_models first to see available models.',
  {
    model: z
      .string()
      .describe(
        'The model name as returned by ollama_list_models (e.g. "llama3.2" or "gemma3:1b")',
      ),
    prompt: z.string().describe('The prompt to send to the model'),
    system: z
      .string()
      .optional()
      .describe('Optional system prompt to set model behavior'),
    temperature: z
      .number()
      .optional()
      .describe('Sampling temperature (0.0–2.0). Defaults to model default.'),
  },
  async (args) => {
    log(`>>> Generating with ${args.model} (${args.prompt.length} chars)...`);
    writeStatus('generating', `Generating with ${args.model}`);
    try {
      const body: Record<string, unknown> = {
        model: args.model,
        prompt: args.prompt,
        stream: false,
      };
      if (args.system) body.system = args.system;
      if (args.temperature !== undefined) {
        body.options = { temperature: args.temperature };
      }

      const startedAt = Date.now();
      const res = await ollamaFetch('/api/generate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });

      if (!res.ok) {
        const errorText = await res.text();
        return {
          content: [
            {
              type: 'text' as const,
              text: `Ollama error (${res.status}): ${errorText}`,
            },
          ],
          isError: true,
        };
      }

      const data = (await res.json()) as {
        response?: string;
        eval_count?: number;
      };

      const response = data.response ?? '';
      const elapsedSec = ((Date.now() - startedAt) / 1000).toFixed(1);
      const evalCount = data.eval_count;

      const meta = `\n\n[${args.model} | ${elapsedSec}s${
        evalCount !== undefined ? ` | ${evalCount} tokens` : ''
      }]`;

      log(
        `<<< Done: ${args.model} | ${elapsedSec}s | ${
          evalCount ?? '?'
        } tokens | ${response.length} chars`,
      );
      writeStatus(
        'done',
        `${args.model} | ${elapsedSec}s | ${evalCount ?? '?'} tokens`,
      );

      return { content: [{ type: 'text' as const, text: response + meta }] };
    } catch (err) {
      return {
        content: [
          {
            type: 'text' as const,
            text: `Failed to call Ollama: ${err instanceof Error ? err.message : String(err)}`,
          },
        ],
        isError: true,
      };
    }
  },
);

// Library-management tools — opt-in via OLLAMA_ADMIN_TOOLS=true. These mutate
// the host's model library (pull/delete) or inspect it, so they are gated
// behind an explicit flag rather than exposed by default.
if (OLLAMA_ADMIN_TOOLS) {
  server.tool(
    'ollama_pull_model',
    'Pull (download) a model from the Ollama registry into the local daemon. Blocks until the download completes — large models can take several minutes.',
    {
      model: z
        .string()
        .describe('The model name to pull (e.g. "llama3.2" or "qwen3-coder:30b")'),
    },
    async (args) => {
      log(`Pulling model: ${args.model}`);
      writeStatus('pulling', `Pulling ${args.model}`);
      try {
        const res = await ollamaFetch('/api/pull', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ model: args.model, stream: false }),
        });

        if (!res.ok) {
          const errorText = await res.text();
          return {
            content: [
              {
                type: 'text' as const,
                text: `Ollama pull error (${res.status}): ${errorText}`,
              },
            ],
            isError: true,
          };
        }

        const data = (await res.json()) as { status?: string };
        log(`Pulled: ${args.model} (${data.status ?? 'ok'})`);
        return {
          content: [
            {
              type: 'text' as const,
              text: `Pulled ${args.model}: ${data.status ?? 'success'}`,
            },
          ],
        };
      } catch (err) {
        return {
          content: [
            {
              type: 'text' as const,
              text: `Failed to pull ${args.model}: ${err instanceof Error ? err.message : String(err)}`,
            },
          ],
          isError: true,
        };
      }
    },
  );

  server.tool(
    'ollama_delete_model',
    'Delete a locally installed model from the Ollama daemon to free disk space.',
    {
      model: z.string().describe('The model name to delete (e.g. "gemma3:1b")'),
    },
    async (args) => {
      log(`Deleting model: ${args.model}`);
      writeStatus('deleting', `Deleting ${args.model}`);
      try {
        const res = await ollamaFetch('/api/delete', {
          method: 'DELETE',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ model: args.model }),
        });

        if (!res.ok) {
          const errorText = await res.text();
          return {
            content: [
              {
                type: 'text' as const,
                text: `Ollama delete error (${res.status}): ${errorText}`,
              },
            ],
            isError: true,
          };
        }

        log(`Deleted: ${args.model}`);
        return {
          content: [
            { type: 'text' as const, text: `Deleted ${args.model}.` },
          ],
        };
      } catch (err) {
        return {
          content: [
            {
              type: 'text' as const,
              text: `Failed to delete ${args.model}: ${err instanceof Error ? err.message : String(err)}`,
            },
          ],
          isError: true,
        };
      }
    },
  );

  server.tool(
    'ollama_show_model',
    'Show details for a locally installed model: modelfile, parameters, template, and architecture info.',
    {
      model: z
        .string()
        .describe('The model name to inspect (e.g. "llama3.2")'),
    },
    async (args) => {
      log(`Showing model: ${args.model}`);
      try {
        const res = await ollamaFetch('/api/show', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ model: args.model }),
        });

        if (!res.ok) {
          const errorText = await res.text();
          return {
            content: [
              {
                type: 'text' as const,
                text: `Ollama show error (${res.status}): ${errorText}`,
              },
            ],
            isError: true,
          };
        }

        const data = (await res.json()) as {
          parameters?: string;
          template?: string;
          details?: {
            family?: string;
            parameter_size?: string;
            quantization_level?: string;
          };
        };

        const parts: string[] = [`Model: ${args.model}`];
        if (data.details) {
          const d = data.details;
          parts.push(
            `Family: ${d.family ?? '?'} | Params: ${d.parameter_size ?? '?'} | Quant: ${d.quantization_level ?? '?'}`,
          );
        }
        if (data.parameters) parts.push(`Parameters:\n${data.parameters}`);
        if (data.template) parts.push(`Template:\n${data.template}`);

        return {
          content: [{ type: 'text' as const, text: parts.join('\n\n') }],
        };
      } catch (err) {
        return {
          content: [
            {
              type: 'text' as const,
              text: `Failed to show ${args.model}: ${err instanceof Error ? err.message : String(err)}`,
            },
          ],
          isError: true,
        };
      }
    },
  );

  server.tool(
    'ollama_list_running',
    'List models currently loaded in memory, with memory usage and processor type (CPU/GPU). Use this to see what is warm and consuming resources.',
    {},
    async () => {
      log('Listing running models...');
      try {
        const res = await ollamaFetch('/api/ps');
        if (!res.ok) {
          return {
            content: [
              {
                type: 'text' as const,
                text: `Ollama API error: ${res.status} ${res.statusText}`,
              },
            ],
            isError: true,
          };
        }

        const data = (await res.json()) as {
          models?: Array<{
            name: string;
            size?: number;
            size_vram?: number;
          }>;
        };
        const models = data.models || [];

        if (models.length === 0) {
          return {
            content: [
              {
                type: 'text' as const,
                text: 'No models currently loaded in memory.',
              },
            ],
          };
        }

        const list = models
          .map((m) => {
            const vram = m.size_vram ?? 0;
            const total = m.size ?? 0;
            const processor =
              vram === 0
                ? 'CPU'
                : vram >= total
                  ? 'GPU'
                  : `${Math.round((vram / total) * 100)}% GPU`;
            return `- ${m.name} (${formatBytes(total)}, ${processor})`;
          })
          .join('\n');

        return {
          content: [
            { type: 'text' as const, text: `Loaded models:\n${list}` },
          ],
        };
      } catch (err) {
        return {
          content: [
            {
              type: 'text' as const,
              text: `Failed to connect to Ollama at ${OLLAMA_HOST}: ${err instanceof Error ? err.message : String(err)}`,
            },
          ],
          isError: true,
        };
      }
    },
  );
}

const transport = new StdioServerTransport();
await server.connect(transport);
OLLAMA_MCP_STDIO_TS
        _ollama_log "ollama-mcp-stdio.ts: written fresh"
    fi

    # 2. container/agent-runner/src/index.ts — register the ollama MCP
    # server alongside the existing nanoclaw one.
    if grep -q "ollama-mcp-stdio" "$index_ts"; then
        echo "✅ index.ts already registers the ollama MCP server."
        _ollama_log "index.ts: already registered"
    else
        echo "🦙 Registering the ollama MCP server in index.ts..."
        local anchor
        anchor=$(grep -n "args: \['run', mcpServerPath\]," "$index_ts" | head -1 | cut -d: -f1)
        if [ -z "$anchor" ]; then
            echo "❌ Couldn't find the 'nanoclaw' mcpServers entry anchor in index.ts." >&2
            echo "   NanoClaw's own agent-runner source may have changed upstream — skipping;" >&2
            echo "   apply it manually per $skill_url" >&2
            _ollama_log "index.ts: **SKIPPED** — anchor not found, upstream layout may have changed. Apply manually: $skill_url"
            OLLAMA_PATCH_OK=false
        else
            local insert_after=$((anchor + 2))
            local tmp; tmp=$(mktemp)
            {
                head -n "$insert_after" "$index_ts"
                cat <<'OLLAMA_INDEX_BLOCK'
    ollama: {
      command: 'bun',
      args: ['run', path.join(__dirname, 'ollama-mcp-stdio.ts')],
      env: {
        ...(process.env.OLLAMA_HOST ? { OLLAMA_HOST: process.env.OLLAMA_HOST } : {}),
        ...(process.env.OLLAMA_ADMIN_TOOLS ? { OLLAMA_ADMIN_TOOLS: process.env.OLLAMA_ADMIN_TOOLS } : {}),
      },
    },
OLLAMA_INDEX_BLOCK
                tail -n "+$((insert_after + 1))" "$index_ts"
            } > "$tmp"
            mv "$tmp" "$index_ts"
            _ollama_log "index.ts: patched (ollama entry added after the nanoclaw mcpServers entry)"
        fi
    fi

    # 3. src/config.ts — read OLLAMA_HOST/OLLAMA_ADMIN_TOOLS/
    # OLLAMA_NO_PROXY_OVERRIDE from NanoClaw's own .env (readEnvFile),
    # falling back to process.env — the three-line addition to readEnvFile's
    # own key list, plus three export lines. See this function's own header
    # comment for why OLLAMA_NO_PROXY_OVERRIDE exists.
    if grep -q "^export const OLLAMA_HOST" "$config_ts"; then
        echo "✅ config.ts already exports OLLAMA_HOST/OLLAMA_ADMIN_TOOLS."
        _ollama_log "config.ts: already patched"
    else
        echo "🦙 Wiring OLLAMA_HOST/OLLAMA_ADMIN_TOOLS/OLLAMA_NO_PROXY_OVERRIDE into config.ts..."
        local keys_anchor
        keys_anchor=$(grep -n "^  'ONECLI_GATEWAY_CONTAINER'," "$config_ts" | head -1 | cut -d: -f1)
        if [ -z "$keys_anchor" ]; then
            echo "❌ Couldn't find the readEnvFile() key-list anchor in config.ts." >&2
            echo "   NanoClaw's own config.ts may have changed upstream — skipping;" >&2
            echo "   apply it manually per $skill_url" >&2
            _ollama_log "config.ts: **SKIPPED** — readEnvFile() anchor not found, upstream layout may have changed. Apply manually: $skill_url"
            OLLAMA_PATCH_OK=false
        else
            local tmp; tmp=$(mktemp)
            {
                head -n "$keys_anchor" "$config_ts"
                cat <<'OLLAMA_CONFIG_KEYS_BLOCK'
  'OLLAMA_HOST',
  'OLLAMA_ADMIN_TOOLS',
  'OLLAMA_NO_PROXY_OVERRIDE',
OLLAMA_CONFIG_KEYS_BLOCK
                tail -n "+$((keys_anchor + 1))" "$config_ts"
            } > "$tmp"
            mv "$tmp" "$config_ts"

            # Re-find the export anchor fresh in the just-updated file —
            # never assume the line number from before the first splice
            # still applies after it shifted the file by 3 lines.
            local export_anchor
            export_anchor=$(grep -n "^export const TIMEZONE = resolveConfigTimezone();" "$config_ts" | head -1 | cut -d: -f1)
            if [ -z "$export_anchor" ]; then
                echo "❌ Couldn't find the TIMEZONE export anchor in config.ts after the key-list edit." >&2
                echo "   Reverting the key-list edit — apply the whole config.ts patch manually per $skill_url" >&2
                _ollama_log "config.ts: **PARTIALLY SKIPPED** — key-list edit applied, but the export-line anchor was missing, so the export lines themselves were NOT added. Apply the rest manually: $skill_url"
                OLLAMA_PATCH_OK=false
            else
                local tmp2; tmp2=$(mktemp)
                {
                    head -n "$export_anchor" "$config_ts"
                    cat <<'OLLAMA_CONFIG_EXPORT_BLOCK'

export const OLLAMA_HOST = process.env.OLLAMA_HOST || envConfig.OLLAMA_HOST;
export const OLLAMA_ADMIN_TOOLS = process.env.OLLAMA_ADMIN_TOOLS || envConfig.OLLAMA_ADMIN_TOOLS;
export const OLLAMA_NO_PROXY_OVERRIDE = process.env.OLLAMA_NO_PROXY_OVERRIDE || envConfig.OLLAMA_NO_PROXY_OVERRIDE;
OLLAMA_CONFIG_EXPORT_BLOCK
                    tail -n "+$((export_anchor + 1))" "$config_ts"
                } > "$tmp2"
                mv "$tmp2" "$config_ts"
                _ollama_log "config.ts: patched (readEnvFile key list + three exports added)"
            fi
        fi
    fi

    # 4. src/ollama-env.ts — the fixed ollamaEnvArgs() implementation.
    # Fully owned by this patch, same "fill in if missing, never overwrite"
    # rule as ollama-mcp-stdio.ts above.
    if [ -f "$ollama_env" ]; then
        echo "✅ ollama-env.ts already present."
        _ollama_log "ollama-env.ts: already present (left untouched)"
    else
        echo "🦙 Writing src/ollama-env.ts..."
        cat > "$ollama_env" <<'OLLAMA_ENV_TS'
import { OLLAMA_ADMIN_TOOLS, OLLAMA_HOST, OLLAMA_NO_PROXY_OVERRIDE } from './config.js';

/**
 * Env vars forwarded to every agent container so the Ollama MCP server it
 * spawns (ollama-mcp-stdio.ts) can reach the host's Ollama daemon.
 *
 * host.docker.internal:11434 is not a direct Ollama socket on this
 * platform -- it only works because HTTPS_PROXY routes the request through
 * OneCLI's own gateway, which forwards it to the real Ollama backend.
 * Direct TCP to that hostname (i.e. host.docker.internal excluded from
 * proxying via NO_PROXY) fails outright. OneCLI's own platform default
 * NO_PROXY value does NOT include host.docker.internal -- but something
 * else can leave a container with a NO_PROXY that does: this repo's own
 * apply_mnemon_patch(), for one, bakes `ENV NO_PROXY=host.docker.internal`
 * into the agent-sandbox Dockerfile as "cheap insurance" for its own,
 * unrelated reasons. `docker run -e` (this function's own output) wins
 * over a Dockerfile ENV, so explicitly re-asserting the correct value here
 * -- rather than assuming whatever the image/platform already set is
 * right -- is what actually guards against that. OLLAMA_NO_PROXY_OVERRIDE
 * (see config.ts) lets an operator supply the real platform value if it
 * differs from the default below (confirmed correct on OrbStack; unverified
 * on a real Linux/Raspberry Pi Docker host, where OneCLI's own default may
 * be a different address entirely).
 */
export function ollamaEnvArgs(): string[] {
  const args: string[] = [];
  if (OLLAMA_HOST) {
    args.push('-e', `OLLAMA_HOST=${OLLAMA_HOST}`);
  }
  if (OLLAMA_ADMIN_TOOLS) {
    args.push('-e', `OLLAMA_ADMIN_TOOLS=${OLLAMA_ADMIN_TOOLS}`);
  }
  const noProxy = OLLAMA_NO_PROXY_OVERRIDE || '0.250.250.254';
  args.push('-e', `NO_PROXY=${noProxy}`);
  args.push('-e', `no_proxy=${noProxy}`);
  return args;
}
OLLAMA_ENV_TS
        _ollama_log "ollama-env.ts: written fresh"
    fi

    # 5. src/container-runner.ts — import ollamaEnvArgs and call it in
    # buildContainerArgs(). Two separate splices in the same file; each
    # re-finds its own anchor fresh rather than assuming a line number
    # computed before the first splice still applies after it.
    if grep -q "ollama-env" "$container_runner"; then
        echo "✅ container-runner.ts already wires ollamaEnvArgs()."
        _ollama_log "container-runner.ts: already patched"
    else
        echo "🦙 Wiring ollamaEnvArgs() into container-runner.ts..."
        local import_anchor
        import_anchor=$(grep -n "^import './providers/index.js';" "$container_runner" | head -1 | cut -d: -f1)
        local call_anchor
        call_anchor=$(grep -n 'args.push(.-e., `TZ=\${containerConfig.timezone ?? TIMEZONE}`);' "$container_runner" | head -1 | cut -d: -f1)
        if [ -z "$import_anchor" ] || [ -z "$call_anchor" ]; then
            echo "❌ Couldn't find the providers/index.js import or the TZ args.push() anchor in container-runner.ts." >&2
            echo "   NanoClaw's own container-runner.ts may have changed upstream — skipping;" >&2
            echo "   apply it manually per $skill_url" >&2
            _ollama_log "container-runner.ts: **SKIPPED** — one or both anchors not found, upstream layout may have changed. Apply manually: $skill_url"
            OLLAMA_PATCH_OK=false
        else
            local tmp; tmp=$(mktemp)
            {
                head -n "$import_anchor" "$container_runner"
                echo "import { ollamaEnvArgs } from './ollama-env.js';"
                tail -n "+$((import_anchor + 1))" "$container_runner"
            } > "$tmp"
            mv "$tmp" "$container_runner"

            # Re-find fresh — the import splice above shifted every line
            # after it down by one.
            call_anchor=$(grep -n 'args.push(.-e., `TZ=\${containerConfig.timezone ?? TIMEZONE}`);' "$container_runner" | head -1 | cut -d: -f1)
            local tmp2; tmp2=$(mktemp)
            {
                head -n "$call_anchor" "$container_runner"
                echo "  args.push(...ollamaEnvArgs());"
                tail -n "+$((call_anchor + 1))" "$container_runner"
            } > "$tmp2"
            mv "$tmp2" "$container_runner"
            _ollama_log "container-runner.ts: patched (import added, ollamaEnvArgs() called in buildContainerArgs())"
        fi
    fi

    # Post-patch verification — same checks the original bug-fix
    # replication summary itself specified, run automatically instead of
    # trusting each sub-patch's own idempotency check alone (a check can
    # pass while the surrounding structure it depends on has quietly
    # drifted). No TypeScript toolchain invoked here (tsc/vitest) — this
    # runs on the bare HOST before NanoClaw's own container exists at all,
    # and there's no guarantee node_modules is even installed yet on a
    # first-ever deploy; see the manifest's own note pointing at a
    # `docker exec`-based typecheck instead, which runs after the
    # container (and its dependencies) genuinely exist.
    local mcp_count index_count runner_count config_count
    mcp_count=$([ -f "$mcp_stdio" ] && echo 1 || echo 0)
    index_count=$(grep -c "ollama" "$index_ts" 2>/dev/null || echo 0)
    runner_count=$(grep -c "ollamaEnvArgs" "$container_runner" 2>/dev/null || echo 0)
    config_count=$(grep -c "OLLAMA_HOST" "$config_ts" 2>/dev/null || echo 0)
    if [ "$mcp_count" -gt 0 ] && [ "$index_count" -gt 0 ] && [ "$runner_count" -gt 0 ] && [ "$config_count" -gt 0 ] && [ -f "$ollama_env" ]; then
        echo "✅ Ollama-tool patch verified (all five files present/wired)."
        _ollama_log "**Verification: PASSED** (all five files present/wired)"
    else
        echo "⚠️  Ollama-tool patch verification found a gap — see pi-bootstrap-patches.md in $INSTALL_PATH for details." >&2
        _ollama_log "**Verification: FAILED** — mcp_stdio exists=${mcp_count}, index.ts ollama refs=${index_count}, container-runner.ts ollamaEnvArgs refs=${runner_count}, config.ts OLLAMA_HOST refs=${config_count}, ollama-env.ts exists=$([ -f "$ollama_env" ] && echo yes || echo no)"
        OLLAMA_PATCH_OK=false
    fi
}

# ---------------------------------------------------------------------------------------
# Writes $INSTALL_PATH/pi-bootstrap-patches.md — a status report of every
# host-side patch this environment applies to the NanoClaw checkout
# (mnemon, media-tools/whisper, ollama-tool), regenerated on every deploy.
# This is how the drift-vs-upstream problem gets closed: pi-bootstrap does
# NOT pin NanoClaw's git ref (still tracks latest `main`, same as always),
# so an upstream change can silently break one of these text-splice patches
# at any time. Instead of pinning, this file gives the admin `claude`
# session (see entrypoint.sh's /root/CLAUDE.md, which points here) enough
# detail to notice and self-diagnose that breakage from inside the
# container — each patch's own PASSED/SKIPPED/FAILED status plus a link to
# the real skill doc to apply the missing piece manually if needed.
#
# Deliberately unconditional (always overwritten): unlike the two files
# apply_ollama_tool_patch() itself owns (ollama-mcp-stdio.ts, ollama-env.ts,
# fill-in-if-missing so a live admin fix survives), this file is pure
# run.sh-generated status output, nothing else ever writes to it, so
# overwriting it every deploy is correct, not lossy.
#
# Deliberately NOT the same file the admin session writes fixes back into —
# see write_patch_fixes_template() below for that one (touch-if-missing,
# survives every redeploy) — mixing "what run.sh most recently observed"
# with "what a human/future pi-bootstrap session still needs to read and
# act on" in one file would make the latter easy to lose on the next CLEAN.
#
# The manifest's own markdown body lives in
# templates/patches-manifest.md.tmpl, not inlined here as a heredoc — pulled
# out into its own file so the prose is readable/editable as plain markdown
# (no backslash-escaped backticks to dodge heredoc command substitution) and
# stays visually separate from the status-gathering logic below. Rendered
# via _yaml_expand (lib/yaml-lib.sh) — the same `${VAR}`/`${VAR:-default}`
# substitution mechanism info.yaml/desktop-entries.yaml already use
# elsewhere in this repo — against the plain local variables this function
# sets first.
# ---------------------------------------------------------------------------------------
# Reads one patch's detail section from templates/patch-details/<id>.md.
# Missing file is not fatal — the manifest is a diagnostic aid, and a
# deploy that still applies every patch correctly shouldn't fail because a
# documentation file didn't ship. Says so in the output rather than
# silently emitting an empty section.
_patch_detail() {
    local f="${SCRIPT_DIR}/templates/patch-details/${1}.md"
    if [ -f "$f" ]; then
        cat "$f"
    else
        echo "_(detail unavailable — templates/patch-details/${1}.md is missing from the pi-bootstrap checkout that deployed this container.)_"
    fi
}

write_patches_manifest() {
    local manifest="${INSTALL_PATH}/pi-bootstrap-patches.md"
    local template="${SCRIPT_DIR}/templates/patches-manifest.md.tmpl"

    local mnemon_status media_tools_status
    if [ "$NANOCLAW_SETUP" = "mnemon" ]; then
        mnemon_status="${MNEMON_PATCH_LOG:-- (no status recorded — apply_mnemon_patch may not have run)
}"
        media_tools_status="${MEDIA_TOOLS_PATCH_LOG:-- (no status recorded — apply_media_tools_patch may not have run)
}"
    else
        mnemon_status="- Not applied — NANOCLAW_SETUP=plain (mnemon patches only apply to the mnemon profile; switch profiles via a CLEAN deploy to change this)
"
        media_tools_status="- Not applied — NANOCLAW_SETUP=plain (media-tools/whisper patch only applies to the mnemon profile; switch profiles via a CLEAN deploy to change this)
"
    fi
    local ollama_status="${OLLAMA_PATCH_LOG:-- (no status recorded — apply_ollama_tool_patch may not have run)
}"
    local telegram_status="${TELEGRAM_IMPORT_PATCH_LOG:-- (no status recorded — apply_telegram_import_patch may not have run)
}"
    local generated_at
    generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    # Per-patch documentation — what the patch changes, which anchors it
    # depends on, and what shape a correct fix has to have. Kept in
    # templates/patch-details/*.md rather than inline here: it's reference
    # documentation aimed at whoever has to repair a patch from inside the
    # container, it's the longest prose this environment produces, and
    # burying it in a shell heredoc made it effectively unreviewable — a
    # doc change looked like a code change in every diff.
    local mnemon_detail media_tools_detail ollama_detail telegram_detail group_images_detail
    mnemon_detail="$(_patch_detail mnemon)"
    media_tools_detail="$(_patch_detail media-tools)"
    ollama_detail="$(_patch_detail ollama-tool)"
    telegram_detail="$(_patch_detail telegram-import)"
    group_images_detail="$(_patch_detail group-images)"

    # Unlike the four patch statuses above, this one is only known AFTER the
    # agent-sandbox image is rebuilt, which happens later in the deploy. The
    # manifest is therefore written once here (so a deploy that fails midway
    # still leaves a usable one) and refreshed after the image work — see the
    # second write_patches_manifest call further down.
    local group_images_status="${GROUP_IMAGES_LOG:-- Not checked yet — this deploy had not reached the agent-image rebuild step when this manifest was written. If this line survives to the end of a deploy, the rebuild step did not run at all (it only runs on CLEAN, or on FAST when a patch changed container/Dockerfile).
}"

    # $(...) strips the template file's trailing newline; printf's own
    # trailing \n restores a normal, single newline-terminated text file.
    printf '%s\n' "$(_yaml_expand "$(cat "$template")")" > "$manifest"

    write_patch_fixes_template
}

# ---------------------------------------------------------------------------------------
# Touch-creates $INSTALL_PATH/pi-bootstrap-patch-fixes.md with an
# instructional header — ONLY if it doesn't already exist. Never
# overwritten on subsequent deploys (unlike pi-bootstrap-patches.md
# above): this file's whole purpose is to accumulate whatever the admin
# `claude` session writes into it across the container's lifetime, closing
# the loop back to a human — see write_patches_manifest()'s own header
# comment for the full rationale on why these are two separate files.
# ---------------------------------------------------------------------------------------
write_patch_fixes_template() {
    local fixes="${INSTALL_PATH}/pi-bootstrap-patch-fixes.md"
    [ -f "$fixes" ] && return 0

    cat > "$fixes" <<'FIXES_EOF'
# pi-bootstrap patch fixes — reported by the admin session

This file is created once (empty template below) and then left alone by
every deploy — nothing in pi-bootstrap overwrites or reads it back
automatically. It exists so that if you (the `claude` admin session
running inside this container) diagnose or fix something related to a
patch described in the sibling `pi-bootstrap-patches.md` — mnemon, the
media/whisper tools, the Ollama MCP tool, or anything added after this was
written — you have somewhere durable to record it. A human (or a future
pi-bootstrap session working on the repo that deployed this container)
reads this file to decide whether to update the actual patch scripts in
pi-bootstrap, so your fix stops being a one-off, container-local
workaround and survives the next CLEAN redeploy or a fresh install
elsewhere too.

Append a dated entry below for each thing you find or fix. There's no
required format — plain prose is fine — but it's most useful if it
includes: which patch broke, what NanoClaw upstream changed that broke it
(if you could tell), and exactly what you changed to fix it (file, before/
after, or a diff).

---

FIXES_EOF
}

# ---------------------------------------------------------------------------------------
# Only runs at all if MNEMON_EMBED_ENDPOINT is set — mnemon's embeddings are
# opt-in (see .env.example), and this environment never touches Ollama
# otherwise. Best-effort throughout: every failure path warns and returns 0
# rather than aborting the deploy, since embeddings are optional — mnemon
# itself falls back to graph-only recall if this endpoint stays unreachable.
# Installation is gated behind an explicit y/N prompt; pulling a model is
# not (lower-risk, and mirrors mnemon's own binary being auto-downloaded).
# ---------------------------------------------------------------------------------------
# ---------------------------------------------------------------------------------------
# The gap ensure_ollama_ready()'s own probe structurally cannot see.
#
# That probe rewrites host.docker.internal -> localhost so it works from a
# bare host shell (see its own comment for why that rewrite is correct). The
# consequence is that it answers "is Ollama running?" and never "can a
# CONTAINER reach it?" — and those differ in one specific, easy-to-hit way:
# Ollama's default bind address is 127.0.0.1:11434, loopback only. A host-side
# curl to localhost succeeds; an agent container reaching
# host.docker.internal:11434 arrives as external traffic and is refused.
#
# Confirmed on a live install, after four separate rounds of NO_PROXY theories
# had chased the routing layer instead:
#     lsof -nP -iTCP:11434 -sTCP:LISTEN
#     ollama 986 homer 3u IPv4 ... TCP 127.0.0.1:11434 (LISTEN)
# mnemon reported ollama_available:false the entire time. `curl` from inside
# the same container appeared to succeed, which is what kept sending the
# diagnosis in the wrong direction — but only because it went through the
# platform's own HTTP proxy, which runs ON the host and therefore can reach
# loopback. mnemon's Go client goes direct, so it saw the refusal.
#
# This only warns. Rebinding Ollama to 0.0.0.0 exposes it to the local
# network, which is a security decision for the operator to make deliberately,
# not something a deploy script should do on their behalf.
# ---------------------------------------------------------------------------------------
warn_if_ollama_is_loopback_only() {
    local endpoint="$1" listeners=""

    # Only matters when a container will reach Ollama via host.docker.internal.
    # A localhost/127.0.0.1 endpoint is the orchestrator's own business and a
    # loopback bind is fine — and correct — there.
    case "$endpoint" in
        *host.docker.internal*) ;;
        *) return 0 ;;
    esac

    # lsof on macOS, ss on most modern Linux, netstat as the last resort.
    # Whichever answers first wins; if none is installed we say nothing rather
    # than guessing, since a false alarm here would send the next person
    # chasing a non-problem.
    if command -v lsof >/dev/null 2>&1; then
        # Pick the field that actually holds the address, not $NF: lsof's NAME
        # column is "TCP 127.0.0.1:11434 (LISTEN)", three whitespace-separated
        # fields, so $NF is "(LISTEN)" and every address check downstream would
        # silently pass. Caught by a test against real lsof output.
        listeners=$(lsof -nP -iTCP:11434 -sTCP:LISTEN 2>/dev/null \
            | awk 'NR>1 { for (i = 1; i <= NF; i++) if ($i ~ /[.:]11434$/) print $i }')
    elif command -v ss >/dev/null 2>&1; then
        listeners=$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep ':11434$' || true)
    elif command -v netstat >/dev/null 2>&1; then
        listeners=$(netstat -an 2>/dev/null | awk '/LISTEN/ {print $4}' | grep '[.:]11434$' || true)
    fi
    [ -z "$listeners" ] && return 0

    # Bound anywhere non-loopback (0.0.0.0, *, a LAN IP) — containers can
    # reach it, nothing to warn about.
    if printf '%s\n' "$listeners" | grep -qv -e '^127\.0\.0\.1' -e '^\[::1\]' -e '^::1' -e '^localhost'; then
        return 0
    fi

    echo "" >&2
    echo "⚠️  Ollama is listening on loopback only:" >&2
    printf '%s\n' "$listeners" | sed 's/^/       /' >&2
    echo "   It answers on this host, but an agent container reaching it via" >&2
    echo "   host.docker.internal:11434 arrives as external traffic and will be REFUSED." >&2
    echo "   Expect mnemon to report 'ollama_available: false' while this is the case," >&2
    echo "   even though every host-side check here passes." >&2
    echo "" >&2
    echo "   Fix on the host, then restart Ollama (this exposes it to your local" >&2
    echo "   network — a deliberate security tradeoff, which is why this only warns):" >&2
    if [[ "$(uname)" == "Darwin" ]]; then
        echo "     launchctl setenv OLLAMA_HOST \"0.0.0.0:11434\"      # Ollama.app: then quit and reopen it" >&2
        echo "     OLLAMA_HOST=0.0.0.0:11434 brew services restart ollama" >&2
    else
        echo "     sudo systemctl edit ollama    # add: Environment=\"OLLAMA_HOST=0.0.0.0:11434\"" >&2
    fi
    echo "   Verify: lsof -nP -iTCP:11434 -sTCP:LISTEN   # should no longer say 127.0.0.1" >&2
    echo "" >&2
}

ensure_ollama_ready() {
    [ -z "$MNEMON_EMBED_ENDPOINT" ] && return 0

    local model="${MNEMON_EMBED_MODEL:-nomic-embed-text}"
    local endpoint="$MNEMON_EMBED_ENDPOINT"
    local is_local=false
    case "$endpoint" in
        *host.docker.internal*|*localhost*|*127.0.0.1*) is_local=true ;;
    esac

    # This function runs directly on the HOST, not inside any container —
    # so "host.docker.internal" (a hostname Docker's own embedded DNS
    # resolves only for containers, routing them back to the host) may not
    # resolve at all from a bare host shell, even on a machine where
    # Docker Desktop/OrbStack otherwise works fine. Ollama itself is still
    # genuinely reachable there via plain "localhost" — every curl/ollama
    # call below targets this variable instead of $endpoint directly.
    # $endpoint itself is left untouched for display, and for the value
    # later baked into the container's own image (apply_mnemon_patch, a
    # separate code path) — the CONTAINER's own resolution DOES need
    # host.docker.internal, unlike this host-side probe. Confirmed
    # directly: a real deploy reported "still couldn't reach Ollama"
    # despite Ollama genuinely running and reachable at localhost:11434
    # the whole time — this function's own curl calls were the only thing
    # actually failing to reach it.
    local probe_endpoint="${endpoint//host.docker.internal/localhost}"

    echo "🔎 Checking Ollama at $endpoint (mnemon embeddings are enabled in .env)..."

    if ! curl -fsS "${probe_endpoint}/api/tags" >/dev/null 2>&1; then
        if [ "$is_local" != "true" ]; then
            echo "⚠️  $endpoint isn't reachable, and isn't a local address this script manages." >&2
            echo "   mnemon will run graph-only until that endpoint is reachable — nothing else to do here." >&2
            return 0
        fi

        if ! command -v ollama >/dev/null 2>&1; then
            echo "⚠️  Ollama isn't installed on this host."
            local reply=""
            # `read -p`'s own prompt text goes to stderr, not stdout — and
            # the `2>/dev/null` below (there to quietly handle hosts with
            # no /dev/tty at all, e.g. a non-interactive curl|bash install)
            # was silencing that prompt right along with it. Confirmed
            # directly: a real deploy looked "stuck" right after the
            # "isn't installed" line, with no visible question at all,
            # even though it was genuinely just waiting on stdin the whole
            # time. Printing the question via a plain `echo` first — never
            # subject to that redirect — means it's always visible
            # regardless of whether /dev/tty exists.
            if [[ "$(uname)" == "Darwin" ]]; then
                echo "   Install it now via Homebrew? [y/N] "
            else
                echo "   Install it now via the official installer (curl | sh)? [y/N] "
            fi
            read -r reply < /dev/tty 2>/dev/null || true
            if [[ "$reply" =~ ^[Yy]$ ]]; then
                if [[ "$(uname)" == "Darwin" ]]; then
                    if command -v brew >/dev/null 2>&1; then
                        brew install ollama || echo "⚠️  brew install failed — install manually: https://ollama.com/download" >&2
                    else
                        echo "⚠️  Homebrew not found — install manually: https://ollama.com/download" >&2
                    fi
                else
                    curl -fsSL https://ollama.com/install.sh | sh || echo "⚠️  Installer failed — install manually: https://ollama.com/download" >&2
                fi
            else
                echo "   Skipping — mnemon will run graph-only until Ollama is reachable at $endpoint." >&2
                return 0
            fi
        fi

        if command -v ollama >/dev/null 2>&1 && ! curl -fsS "${probe_endpoint}/api/tags" >/dev/null 2>&1; then
            echo "🚀 Starting Ollama..."
            if [[ "$(uname)" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
                brew services start ollama >/dev/null 2>&1 || (nohup ollama serve >/dev/null 2>&1 &)
            else
                (nohup ollama serve >/dev/null 2>&1 &)
            fi
            local tries=0
            while [ "$tries" -lt 10 ] && ! curl -fsS "${probe_endpoint}/api/tags" >/dev/null 2>&1; do
                sleep 1
                tries=$((tries + 1))
            done
        fi

        if ! curl -fsS "${probe_endpoint}/api/tags" >/dev/null 2>&1; then
            echo "⚠️  Still couldn't reach Ollama at $endpoint — mnemon will run graph-only for now." >&2
            return 0
        fi
    fi

    echo "✅ Ollama is reachable."
    warn_if_ollama_is_loopback_only "$endpoint"

    if curl -fsS "${probe_endpoint}/api/tags" 2>/dev/null | grep -q "\"name\":\"${model}"; then
        echo "✅ Model '$model' already pulled."
    elif [ "$is_local" = "true" ] && command -v ollama >/dev/null 2>&1; then
        echo "📥 Pulling '$model' (this can take a while the first time)..."
        OLLAMA_HOST="${probe_endpoint#http://}" ollama pull "$model" || echo "⚠️  Pull failed — mnemon will run graph-only until '$model' is available." >&2
    else
        echo "⚠️  '$model' isn't pulled on $endpoint and it's not a local daemon this script manages — pull it there yourself." >&2
    fi
}

# Mounted at the SAME absolute path both on the host and inside the
# orchestrator container — not remapped to some internal path like
# /workspace. NanoClaw spawns per-conversation-group agent containers
# itself via the bind-mounted Docker socket (Docker-outside-of-Docker:
# those containers are siblings of this one, not nested inside it) — any
# path it passes to `docker run -v <path>:...` is resolved by the HOST's
# Docker daemon against the real host filesystem, not the orchestrator
# container's view of it. Keeping the path identical on both sides is what
# makes a path NanoClaw computes relative to its own install directory
# valid in both contexts at once.
if [ ! -d "$INSTALL_PATH" ]; then
    echo "📁 Creating install path: $INSTALL_PATH"
    mkdir -p "$INSTALL_PATH"
fi

if [ "$POLICY" = "STOP" ]; then
    echo "🛑 [STOP] Pausing NanoClaw+Mnemon container (agent containers preserved)..."
    $DOCKER stop "$CONTAINER_NAME" 2>/dev/null || true
    echo "✅ Container paused. Run with FAST to resume."
    exit 0
fi

if [ "$POLICY" = "TEARDOWN" ]; then
    echo "🗑️  [TEARDOWN] Stopping and removing the orchestrator container and this install's agent containers..."
    $DOCKER stop "$CONTAINER_NAME" 2>/dev/null || true
    $DOCKER rm   "$CONTAINER_NAME" 2>/dev/null || true
    remove_agent_containers
    bash "$REPO_DIR/lib/run-install-desktop.sh" "$SCRIPT_DIR" >/dev/null 2>&1 || true
    echo "✅ Container and agent containers removed. Install path (\$NANOCLAW_INSTALL_PATH) untouched."
    exit 0
fi

if [ "$POLICY" = "CLEAN" ]; then
    echo "🧹 [CLEAN POLICY] Rebuilding the orchestrator image before touching anything running..."
    if ! $DOCKER build --no-cache -t "$IMAGE_TAG" "$SCRIPT_DIR"; then
        echo "❌ Build failed — leaving the existing container untouched."
        exit 1
    fi
    echo "🛑 Fresh image ready — tearing down the previous container and this install's agent containers..."
    $DOCKER stop "$CONTAINER_NAME" 2>/dev/null || true
    $DOCKER rm   "$CONTAINER_NAME" 2>/dev/null || true
    remove_agent_containers
    $DOCKER image prune -f >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------------------
# Clone or update NanoClaw's own source directly on the host — a plain
# filesystem/git operation, no container runtime needed for this part, and
# $INSTALL_PATH is a normal host directory regardless of deploy mode.
# nanocoai/nanoclaw is the current canonical location (GitHub redirects the
# older qwibitai/nanoclaw URL, but this environment clones the canonical one
# directly).
#
# CLEAN used to `rm -rf "$INSTALL_PATH"` here and re-clone from scratch —
# which also destroyed groups/, data/, store/, and .env (conversation
# history, mnemon's memory graphs, any scaffolded wiki, channel tokens),
# none of which are NanoClaw's own source. Confirmed directly: a CLEAN run
# wiped a real install's wiki along with everything else, forcing the whole
# wizard to be redone for no reason connected to what CLEAN actually needs
# to accomplish (a fresh, patchable source tree). `git reset --hard` fixes
# this correctly rather than papering over it with a manual backup/restore
# dance: it only ever touches git-TRACKED files, so .gitignore'd state
# (dist/, store/, data/, groups/, .env — verified against NanoClaw's own
# .gitignore) is left alone by construction, the same way `git pull` above
# already leaves it alone on a plain FAST redeploy.
# ---------------------------------------------------------------------------------------
if [ ! -f "${INSTALL_PATH}/nanoclaw.sh" ]; then
    echo "📥 Cloning NanoClaw repository to $INSTALL_PATH ..."
    git clone https://github.com/nanocoai/nanoclaw.git "$INSTALL_PATH"
    echo "✅ Clone complete."
elif [ ! -d "${INSTALL_PATH}/.git" ]; then
    # A real, hit-in-the-wild case: some backup/restore tools (confirmed
    # here: Time Machine) skip invisible files/directories, so a restored
    # install path can have all its visible NanoClaw source back with no
    # .git at all — git refuses to `pull`/`reset` a directory that isn't
    # actually a repository (both branches below fail with "fatal: not a
    # git repository"), so a fresh clone is the only way to get a working
    # source tree back. Preserve what actually matters by hand across it,
    # since there's no git history/.gitignore here to protect it the way
    # the CLEAN branch below relies on.
    echo "⚠️  $INSTALL_PATH exists but has no .git directory — not a real git checkout (a partial restore that skipped invisible files/dirs is a known way this happens). Re-cloning fresh, preserving .env/groups/data/store first..."
    PRESERVE_TMP=$(mktemp -d)
    for item in .env groups data store; do
        [ -e "${INSTALL_PATH}/${item}" ] && mv "${INSTALL_PATH}/${item}" "${PRESERVE_TMP}/${item}"
    done
    rm -rf "$INSTALL_PATH"
    git clone https://github.com/nanocoai/nanoclaw.git "$INSTALL_PATH"
    for item in .env groups data store; do
        [ -e "${PRESERVE_TMP}/${item}" ] && mv "${PRESERVE_TMP}/${item}" "${INSTALL_PATH}/${item}"
    done
    rmdir "$PRESERVE_TMP" 2>/dev/null || true
    echo "✅ Fresh clone complete, preserved data restored."
    echo "⚠️  If the same restore skipped invisible files/dirs, that applies inside groups/ too —"
    echo "   check groups/<group>/.env and groups/<group>/.claude/ (mnemon's own per-group memory"
    echo "   lives there) for anything that may not have actually come back with the rest."
elif [ "$POLICY" = "CLEAN" ]; then
    # Any channel/provider skill installed via Claude Code (e.g. /add-telegram,
    # /add-whatsapp) wires itself in by editing TRACKED trunk files — a
    # self-registration import appended to src/channels/index.ts, plus a new
    # dependency line in package.json (and, if the skill's own installer ran
    # `pnpm install` afterward, pnpm-lock.yaml too) — alongside copying in new
    # (untracked) source files for the channel itself. `reset --hard` below
    # only discards uncommitted changes to TRACKED files; it can't touch
    # those untracked new files at all. Confirmed the hard way: a live
    # install's Telegram channel went silently dead after a CLEAN — every
    # telegram.ts-etc. file was still on disk, but the barrel import wiring
    # it in, and the package.json dependency entry, had both been silently
    # reverted, with no error anywhere (registerChannelAdapter('telegram',
    # ...) just never ran again).
    #
    # Snapshot those local edits as a patch before the reset, then try to
    # reapply it afterward — restores the wiring automatically in the
    # common case (nothing upstream touched the same lines). Falls back to
    # the old warn-only behavior if the patch doesn't apply cleanly (e.g.
    # upstream genuinely changed the same file) rather than forcing a
    # conflict onto an unattended CLEAN run.
    #
    # container/Dockerfile and container/entrypoint.sh are excluded from
    # this snapshot: those two are owned and idempotently regenerated by
    # apply_mnemon_patch/apply_media_tools_patch below, every CLEAN run,
    # not something a channel/provider skill ever touches. Including them
    # here was a real bug, confirmed against a live deploy: whatever
    # (possibly stale) patch text apply_media_tools_patch had previously
    # written into container/Dockerfile got snapshotted, reapplied verbatim
    # on top of the freshly hard-synced source, and THEN apply_media_tools_
    # patch's own idempotency check (`grep -q 'yt-dlp'`) saw that reapplied
    # text and skipped re-patching — silently keeping a stale patch (e.g. a
    # bug fix to the yt-dlp download line landing in this script) alive
    # indefinitely across CLEAN runs instead of ever picking up the update.
    # container/agent-runner/src/index.ts, src/config.ts, and
    # src/container-runner.ts are excluded for the identical reason as the
    # Dockerfile/entrypoint.sh pair above: they're owned and idempotently
    # re-patched by apply_ollama_tool_patch below on every CLEAN run, so
    # letting the generic snapshot-and-reapply mechanism also touch them
    # risks resurrecting stale patch text that then satisfies that
    # function's own marker-based idempotency check and never updates again.
    CHANNEL_SKILL_MODS=$(git -C "$INSTALL_PATH" status --porcelain -- . ':!container/Dockerfile' ':!container/entrypoint.sh' ':!container/agent-runner/src/index.ts' ':!src/config.ts' ':!src/container-runner.ts' 2>/dev/null | grep -v '^??' || true)
    CHANNEL_SKILL_PATCH=""
    if [ -n "$CHANNEL_SKILL_MODS" ]; then
        echo "⚠️  CLEAN is about to discard local edits to these tracked files — likely a channel/provider skill's own wiring (e.g. /add-telegram's import in src/channels/index.ts or its package.json dependency):"
        echo "$CHANNEL_SKILL_MODS" | sed 's/^/     /'
        _tmp_patch=$(mktemp)
        if git -C "$INSTALL_PATH" diff HEAD -- . ':!container/Dockerfile' ':!container/entrypoint.sh' ':!container/agent-runner/src/index.ts' ':!src/config.ts' ':!src/container-runner.ts' > "$_tmp_patch" 2>/dev/null && [ -s "$_tmp_patch" ]; then
            CHANNEL_SKILL_PATCH="$_tmp_patch"
            echo "   Saved a patch of these edits — will try to reapply them automatically after the sync."
        else
            rm -f "$_tmp_patch"
        fi
    fi
    echo "🔄 [CLEAN POLICY] Hard-syncing NanoClaw source to latest upstream (your data — .env, groups/, data/, any scaffolded wiki — is untouched; only git-tracked source files are reset)..."
    git -C "$INSTALL_PATH" fetch origin
    git -C "$INSTALL_PATH" reset --hard '@{u}'
    if [ -n "$CHANNEL_SKILL_PATCH" ]; then
        if git -C "$INSTALL_PATH" apply --check "$CHANNEL_SKILL_PATCH" 2>/dev/null; then
            git -C "$INSTALL_PATH" apply "$CHANNEL_SKILL_PATCH"
            echo "✅ Reapplied the local edits CLEAN would otherwise have discarded (channel/provider skill wiring) on top of the freshly-synced source."
            rm -f "$CHANNEL_SKILL_PATCH"
        else
            echo "⚠️  Couldn't automatically reapply those edits — upstream likely changed the same lines. Re-run the relevant channel/provider skill (e.g. /add-telegram) to restore it manually. The saved patch is still at: $CHANNEL_SKILL_PATCH"
        fi
    fi
else
    echo "📦 Install path exists. Pulling latest changes..."
    git -C "$INSTALL_PATH" pull --ff-only || echo "⚠️  Git pull skipped (local changes or detached HEAD)."
fi

if [ "$NANOCLAW_SETUP" = "mnemon" ]; then
    ensure_ollama_ready
    # `|| true` on all four apply_*_patch calls below (not just this one) is
    # load-bearing, not defensive boilerplate: run.sh runs under
    # `set -euo pipefail`, and every one of these functions has `return 1`
    # paths that are explicitly designed to skip just that one sub-patch,
    # log it (SKIPPED, not FAILED) into MNEMON_PATCH_LOG/OLLAMA_PATCH_LOG/
    # etc., and let the rest of the deploy continue — see e.g.
    # apply_telegram_import_patch()'s own header comment. Called bare, a
    # `return 1` from any of these is just this function's normal exit
    # status as far as the shell is concerned, and `set -e` kills the
    # entire deploy on it — confirmed against a real deploy: the
    # telegram-import patch's package.json dependency guard correctly
    # logged its SKIPPED reason and returned 1, and that alone aborted the
    # whole `nanoclaw-mnemon` deployment task before write_patches_manifest
    # (let alone anything after it) ever ran, even though every part of
    # this file's own design — the manifest, the SKIPPED/FAILED status
    # model, the "diagnosable from inside the container" comments — assumes
    # a skipped sub-patch is a recoverable, loudly-logged event, not a
    # deploy-ending one.
    apply_mnemon_patch || true
    apply_media_tools_patch || true
else
    if [ "$POLICY" != "CLEAN" ] && [ -f "${INSTALL_PATH}/container/Dockerfile" ] && grep -q 'MNEMON_VERSION' "${INSTALL_PATH}/container/Dockerfile"; then
        echo "⚠️  NANOCLAW_SETUP=plain needs a CLEAN deploy to remove the existing Mnemon agent-image patch." >&2
    fi
    echo "ℹ️  Plain NanoClaw setup selected — skipping Mnemon, embeddings, and agent media-tool patches."
fi

# Applied regardless of NANOCLAW_SETUP — the Ollama MCP tool is a general
# per-agent-group capability, not specific to the mnemon profile (see
# .env.example's OLLAMA_ADMIN_TOOLS comment).
apply_ollama_tool_patch || true
# Applied regardless of NANOCLAW_SETUP too — Telegram is a base NanoClaw
# channel, not a pi-bootstrap addition; see apply_telegram_import_patch()'s
# own header comment for why this self-heal exists at all.
apply_telegram_import_patch || true
write_patches_manifest

# Group-local CLAUDE.local.md survives CLEAN and is read on every agent
# spawn; install/update the managed policy after source sync and before any
# agent image is rebuilt or resumed. A first deploy has no groups yet, which
# the helper treats as a harmless no-op.
bash "$SCRIPT_DIR/scripts/apply-group-policy.sh" "$INSTALL_PATH"
if [ "$NANOCLAW_SETUP" = "mnemon" ]; then
    bash "$SCRIPT_DIR/scripts/apply-mnemon-recall-policy.sh" "$INSTALL_PATH"
fi

# ---------------------------------------------------------------------------------------
# Build the orchestrator image if missing, then start/create the container.
# ---------------------------------------------------------------------------------------
if [ -z "$($DOCKER images -q "$IMAGE_TAG" 2>/dev/null)" ]; then
    echo "🛠️  Building the orchestrator image (first run)..."
    $DOCKER build -t "$IMAGE_TAG" "$SCRIPT_DIR"
fi

if $DOCKER ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "✅ [FAST POLICY] NanoClaw+Mnemon container is already running."
elif $DOCKER ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "🔄 [FAST POLICY] Container exists but is stopped. Starting..."
    $DOCKER start "$CONTAINER_NAME" >/dev/null
else
    echo "🚀 Launching the NanoClaw+Mnemon orchestrator container..."
    # /tmp:/tmp — same reasoning as NANOCLAW_INSTALL_PATH's identical-path
    # bind mount above (see the README's "Deployment Modes" section): any
    # path this container passes as a bind-mount *source* when spawning its
    # own sibling agent containers (via the shared docker.sock) is resolved
    # by the HOST's Docker daemon against the real host filesystem, not
    # this container's own view of it. OneCLI's SDK writes its per-agent CA
    # cert to a fixed /tmp path from inside this process, then bind-mounts
    # that same path into each new agent container — without /tmp shared
    # identically here, the write lands in this container's own private,
    # disconnected /tmp, while the daemon resolves the mount source against
    # the real host's (empty) /tmp instead, silently creating an empty
    # directory there. Confirmed directly against a live install: the cert
    # path inside a spawned agent container was an empty directory, not the
    # PEM file, causing every API call through the OneCLI proxy to fail
    # self-signed-certificate verification.
    $DOCKER run -d --name "$CONTAINER_NAME" --restart unless-stopped \
        -e NANOCLAW_INSTALL_PATH="$INSTALL_PATH" \
        -e CONTAINER_NAME="$CONTAINER_NAME" \
        -e TZ="$HOST_TZ" \
        -e CLAUDE_MODEL="${CLAUDE_MODEL:-}" \
        -e OLLAMA_HOST="${OLLAMA_HOST:-}" \
        -e OLLAMA_ADMIN_TOOLS="${OLLAMA_ADMIN_TOOLS:-}" \
        -e OLLAMA_NO_PROXY_OVERRIDE="${OLLAMA_NO_PROXY_OVERRIDE:-}" \
        -v "$INSTALL_PATH:$INSTALL_PATH" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v /tmp:/tmp \
        -v /etc/localtime:/etc/localtime:ro \
        -p "$NANOCLAW_PORT:$NANOCLAW_PORT" \
        "$IMAGE_TAG" >/dev/null
fi

# Agent containers NanoClaw spawns reach the OneCLI gateway via Docker's
# `--add-host=host.docker.internal:host-gateway` convention, which OrbStack
# resolves to its own broken pseudo-address instead of the real bridge
# gateway (see patch-host-gateway.cjs's own header for the full story and
# how this was confirmed against a live install). Patch it every run —
# cheap and idempotent — piped straight into `node` inside the already-
# running container rather than baked into the image, so it applies
# immediately with no rebuild required. Exit code 2 means it just now
# freshly patched a previously-unpatched source tree; if dist/index.js was
# already built from that old source (an existing install, not a fresh
# one), rebuild and restart so the running service actually picks it up —
# otherwise the patched source just sits there unused until some other
# rebuild happens to come along.
# Exit-code capture must happen inside the `if` itself, not via a bare
# `cmd; rc=$?` pair — this script runs under `set -e`, which aborts on ANY
# nonzero exit that isn't already inside a conditional, and the patch
# script's own "freshly patched" signal (exit 2) is exactly that: a
# nonzero exit that isn't a real error. Confirmed the hard way: a CLEAN
# run died silently right after the patch's own success message, with no
# further output, because `set -e` killed the script before `patch_rc=$?`
# on the next line ever got a chance to run.
if $DOCKER exec -i "$CONTAINER_NAME" node - "$INSTALL_PATH" < "$SCRIPT_DIR/scripts/patch-host-gateway.cjs"; then
    patch_rc=0
else
    patch_rc=$?
fi

# requestApproval() (src/modules/approvals/primitive.ts) silently drops an
# approval card — logging apparent success — whenever getDeliveryAdapter()
# returns falsy, instead of failing loudly. Confirmed against a live
# install: an agent's install_packages approval sat 'pending' for a week,
# re-requested 3 times, with the card never once reaching the owner's
# Telegram DM and nothing in the logs indicating a failure — see
# patch-approval-delivery.cjs's own header for the full investigation.
# Same idempotent every-run treatment and exit-code-2 rebuild signal as the
# host-gateway patch above, and for the same set -e reason, exit-code
# capture happens inside the `if` itself.
if $DOCKER exec -i "$CONTAINER_NAME" node - "$INSTALL_PATH" < "$SCRIPT_DIR/scripts/patch-approval-delivery.cjs"; then
    approval_patch_rc=0
else
    approval_patch_rc=$?
fi

# Optional Codex provider preparation. The upstream provider-auth entry point
# deliberately combines install + OAuth; CLEAN must remain headless, so apply
# the same upstream skill through its directive engine and stop before auth.
# Do this before either CLEAN rebuild path below so the refreshed host source
# and agent CLI manifest are compiled into the artifacts those paths produce.
# A brand-new install has no dist/index.js yet; its normal setup wizard later
# performs the first build from this already-prepared source.
if [ "$NANOCLAW_INSTALL_CODEX" = "true" ] && { [ "$POLICY" = "CLEAN" ] || [ ! -f "${INSTALL_PATH}/dist/index.js" ]; }; then
    echo "🤖 Preparing the NanoClaw Codex provider headlessly (OAuth deferred)..."
    $DOCKER exec -i "$CONTAINER_NAME" bash -s -- "$INSTALL_PATH" < "$SCRIPT_DIR/scripts/install-codex-provider.sh"
fi

# ---------------------------------------------------------------------------------------
# Rebuild the agent-sandbox image BEFORE either NanoClaw restart path below,
# then sweep this install's agent containers one more time.
#
# Ordering here is load-bearing, and getting it wrong was a real, live bug
# that survived several rounds of "the fix is already in master, why is it
# still broken" — worth spelling out so it doesn't get reordered back:
#
#   apply_mnemon_patch/apply_media_tools_patch (far above) only rewrite
#   container/Dockerfile on the HOST. Nothing an agent actually runs changes
#   until container/build.sh turns that Dockerfile into a new agent-sandbox
#   IMAGE, and nothing a *running* agent runs changes until the container
#   spawned from the old image is replaced. This block used to sit AFTER the
#   two restart paths below, which meant the sequence was:
#
#     CLEAN's early teardown removes every agent container   (~line 1770)
#     ... source sync, patches rewrite container/Dockerfile ...
#     orchestrator container starts, NanoClaw comes back up  (~line 1957)
#     start-nanoclaw.sh restarts NanoClaw again              (below)
#     agent-sandbox image finally rebuilt                    (this block)
#
#   NanoClaw is live and serving from the orchestrator-start step onward, so
#   any group that received a message in that window got a fresh agent
#   container spawned from the STILL-STALE image — and agent containers are
#   long-lived, so it kept serving from that stale image indefinitely, across
#   every later FAST deploy. Two symptoms this produced, both reported as
#   "fixed upstream but still broken live", both explained by exactly this:
#     - whisper-cli dynamically linked against a missing libwhisper.so.1,
#       even though -DBUILD_SHARED_LIBS=OFF was confirmed present in the
#       Dockerfile and a fresh `docker run <tag> whisper-cli --help` passed.
#       The image was fine; the running container predated it.
#     - mnemon reporting ollama_available:false, because the stale image
#       still had the pre-scheme-gating `ENV NO_PROXY=host.docker.internal`
#       baked in (see apply_mnemon_patch()'s own comment) — an image-level
#       ENV that a rebuilt image fixes and a stale container never sees.
#
# So: rebuild first, then sweep whatever was spawned from the old image in
# the meantime, and only then let the restart paths below bring NanoClaw up
# against an image that actually matches the patched Dockerfile. NanoClaw
# respawns a swept group's container on its next message, from the new image.
#
# Kept independent of which restart path runs (patch_rc or the CLEAN one) —
# a newly-applied runtime patch used to skip this rebuild entirely because
# patch_rc=2 bypassed an older combined branch.
if [ "$POLICY" = "CLEAN" ] && [ -f "${INSTALL_PATH}/dist/index.js" ]; then
    if [ -f "${INSTALL_PATH}/container/build.sh" ]; then
        echo "🛠️  Rebuilding the NanoClaw agent-sandbox image (profile patches + optional providers)..."
        # BuildKit cache mounts in container/Dockerfile need DOCKER_BUILDKIT=1
        # — docker exec never forwards the host's env on its own (same
        # reasoning as the nanoclaw.sh wizard call further below).
        if ! $DOCKER exec -e DOCKER_BUILDKIT=1 "$CONTAINER_NAME" bash -lc "bash '$INSTALL_PATH/container/build.sh'"; then
            if [ "$NANOCLAW_INSTALL_CODEX" = "true" ]; then
                echo "❌ Agent-sandbox image rebuild failed — refusing to report a successful CLEAN because Codex would not survive in the replacement image." >&2
                exit 1
            fi
            echo "⚠️  Agent-sandbox image rebuild failed — profile changes won't take effect until this succeeds. See the build output above." >&2
        else
            # Only sweep on a SUCCESSFUL rebuild. After a failed one the old
            # image is still the newest thing that exists, so discarding the
            # running containers would buy nothing and just drop live state.
            echo "🐳 Discarding any agent container spawned from the pre-rebuild image..."
            remove_agent_containers
            # Sweeping containers is not enough for a group that runs its own
            # derived image — it would just respawn from that same stale
            # image. See rebuild_stale_group_images()'s header.
            rebuild_stale_group_images
        fi
    else
        if [ "$NANOCLAW_INSTALL_CODEX" = "true" ]; then
            echo "❌ ${INSTALL_PATH}/container/build.sh not found — refusing to report a successful CLEAN because the replacement Codex agent image cannot be built." >&2
            exit 1
        fi
        echo "⚠️  ${INSTALL_PATH}/container/build.sh not found — skipping the agent-sandbox image rebuild. Profile changes won't take effect until the image is rebuilt some other way." >&2
    fi
fi

# A patch above actually rewrote container/Dockerfile on a non-CLEAN deploy
# (only possible now that the patch functions detect a *stale* block rather
# than accepting any block as "already patched" — see apply_mnemon_patch()'s
# marker comment). The Dockerfile change is inert until the agent-sandbox
# image is rebuilt from it, and CLEAN's own rebuild block above doesn't run
# on FAST, so do it here. Without this, a FAST deploy would report a patch as
# freshly applied while every agent kept running the old image — the same
# class of "fixed on disk, stale in the container" bug documented above.
if [ "$POLICY" != "CLEAN" ] && [ "${AGENT_IMAGE_NEEDS_REBUILD:-false}" = "true" ] && [ -f "${INSTALL_PATH}/dist/index.js" ]; then
    if [ -f "${INSTALL_PATH}/container/build.sh" ]; then
        echo "🛠️  A patch updated container/Dockerfile — rebuilding the agent-sandbox image so it takes effect..."
        if $DOCKER exec -e DOCKER_BUILDKIT=1 "$CONTAINER_NAME" bash -lc "bash '$INSTALL_PATH/container/build.sh'"; then
            echo "🐳 Discarding any agent container still running the pre-rebuild image..."
            remove_agent_containers
            rebuild_stale_group_images
        else
            echo "⚠️  Agent-sandbox image rebuild failed — the updated patch won't take effect until this succeeds. See the build output above." >&2
        fi
    else
        echo "⚠️  ${INSTALL_PATH}/container/build.sh not found — the updated container/Dockerfile patch won't take effect until the agent-sandbox image is rebuilt." >&2
    fi
fi

# Refresh the manifest now that the agent-image and per-group-image work has
# run — that section was written as "not checked yet" earlier, because its
# status doesn't exist until this point in the deploy. Everything else in the
# manifest re-renders identically from the same status variables.
write_patches_manifest

if { [ "$patch_rc" -eq 2 ] || [ "$approval_patch_rc" -eq 2 ]; } && [ -f "${INSTALL_PATH}/dist/index.js" ]; then
    echo "🔄 Rebuilding NanoClaw to pick up patched source (host-gateway and/or approval-delivery fix)..."
    $DOCKER exec "$CONTAINER_NAME" bash -lc "cd '$INSTALL_PATH' && pnpm run build"
    stamp_upgrade_state
    $DOCKER exec "$CONTAINER_NAME" bash -lc "cd '$INSTALL_PATH' && bash start-nanoclaw.sh"
fi

# CLEAN hard-synced NanoClaw's source to latest upstream above — if this is
# an upgrade of an existing install (dist/index.js already built from a
# prior run) rather than a first-time install, rebuild from that freshly-
# synced source so the upgrade actually takes effect instead of silently
# continuing to run the old build. Skipped when either patch above already
# did this same rebuild+restart (patch_rc/approval_patch_rc == 2).
if [ "$POLICY" = "CLEAN" ] && [ "$patch_rc" -ne 2 ] && [ "$approval_patch_rc" -ne 2 ] && [ -f "${INSTALL_PATH}/dist/index.js" ]; then
    echo "🔄 [CLEAN POLICY] Rebuilding NanoClaw from the freshly-synced source..."
    $DOCKER exec "$CONTAINER_NAME" bash -lc "cd '$INSTALL_PATH' && pnpm install && pnpm run build"
    stamp_upgrade_state
    $DOCKER exec "$CONTAINER_NAME" bash -lc "cd '$INSTALL_PATH' && bash start-nanoclaw.sh"
fi

# (The agent-sandbox image rebuild that used to live here has moved ABOVE the
# two NanoClaw restart paths — see that block's own comment for why the
# ordering matters. Rebuilding it here, after NanoClaw was already back up
# and serving, is what let stale-image agent containers survive a CLEAN.)

# NanoClaw's own nohup fallback (setup/service.ts, used whenever there's no
# systemd/launchd — always true here) writes start-nanoclaw.sh but never
# runs it, so the wizard's own later steps (e.g. the cli-agent step, which
# pings data/cli.sock) hit a manual dead end mid-setup, every single fresh
# install — see patch-nohup-autostart.cjs's own header for the full story.
# setup/ scripts run directly via tsx with no build step, so this needs no
# rebuild to take effect, unlike the host-gateway patch above — applying it
# now, before any wizard run, is enough.
$DOCKER exec -i "$CONTAINER_NAME" node - "$INSTALL_PATH" < "$SCRIPT_DIR/scripts/patch-nohup-autostart.cjs" || true

# Checked directly on the host, not via `docker exec` — $INSTALL_PATH is
# the identical path on both sides of the mount, so this doesn't need the
# container to already be running to answer correctly.
if [ ! -f "${INSTALL_PATH}/dist/index.js" ]; then
    echo ""
    echo "🧙 Handing off to the NanoClaw interactive setup wizard (inside the container)..."
    echo "   The wizard will ask for your Anthropic API key, channel setup, and more."
    echo "   Its first build already includes mnemon, patched in above."
    echo "   iMessage isn't offered in this container-only NanoClaw setup."
    echo ""
    exec 0< /dev/tty
    exec 1> /dev/tty
    exec 2> /dev/tty
    # nanoclaw.sh builds its own agent-sandbox image from inside this
    # container, over the mounted host docker.sock — its Dockerfile uses
    # --mount=type=cache, which needs BuildKit. `docker exec` never
    # forwards the host's DOCKER_BUILDKIT env var on its own, so without
    # this the docker CLI inside the container silently falls back to the
    # legacy builder and that build step fails outright.
    $DOCKER exec -it -e DOCKER_BUILDKIT=1 "$CONTAINER_NAME" bash -lc "cd '$INSTALL_PATH' && bash nanoclaw.sh"

    # NanoClaw's own setup, on any platform without systemd or launchd —
    # always true here, since this container has no init system at all
    # (see entrypoint.sh) — only *writes* start-nanoclaw.sh; its own
    # setupNohupFallback() explicitly reports SERVICE_LOADED: false and
    # stops there, verified directly against its source (setup/service.ts).
    # Nothing else in its setup flow ever actually runs that script, so
    # left alone the background service never starts and the wizard's own
    # first "ping/pong" health check fails before the service gets a
    # chance to. Start it ourselves once the wizard hands control back.
    if [ -f "${INSTALL_PATH}/start-nanoclaw.sh" ]; then
        echo "🚀 Starting NanoClaw's background service (nohup fallback)..."
        $DOCKER exec "$CONTAINER_NAME" bash -lc "cd '$INSTALL_PATH' && bash start-nanoclaw.sh"
    fi
fi

echo "ℹ️  NanoClaw has no web UI by default — describe problems in chat instead."
echo "   Want one? Its optional /add-dashboard skill reserves port ${NANOCLAW_PORT} for it."
echo "=========================================================="
bash "$REPO_DIR/lib/run-install-desktop.sh" "$SCRIPT_DIR" >/dev/null 2>&1 || true
bash "$REPO_DIR/lib/run-info.sh" "$SCRIPT_DIR" list
