#!/usr/bin/env bash
# Shared readers for environment-local maintenance.yaml manifests. These
# manifests keep deployment detection and locally-built-image metadata beside
# the environment that owns it, rather than in root-script case statements.

MAINTENANCE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MAINTENANCE_LIB_DIR/yaml-lib.sh"

# Returns success when an environment is deployed. Environments without a
# manifest deliberately preserve the old permissive behavior: their own data
# declarations decide whether backup.sh has anything to archive.
is_environment_deployed() (
    local env_path="$1" manifest kind value custom_check docker_cmd
    manifest="${env_path}/maintenance.yaml"
    custom_check="${env_path}/scripts/is-deployed.sh"

    if [ -x "$custom_check" ]; then
        DOCKER_CMD="${DOCKER_CMD:-docker}" bash "$custom_check"
        return $?
    fi
    [ -f "$manifest" ] || return 0
    _require_yq || return 1

    # Deployment settings commonly use .env values. This is the same trusted,
    # local configuration file each environment's own run.sh reads.
    if [ -f "${env_path}/.env" ]; then
        set -a
        source "${env_path}/.env"
        set +a
    fi
    ENV_DIR="$env_path"
    docker_cmd="${DOCKER_CMD:-docker}"
    kind=$(_yq '.deployment.kind // ""' "$manifest")
    value=$(_yaml_expand "$(_yq '.deployment.value // ""' "$manifest")")
    case "$kind" in
        container) $docker_cmd ps -a --filter "name=^/${value}$" -q 2>/dev/null | grep -q . ;;
        marker) test -f "$value" ;;
        directory) test -d "$value" ;;
        systemd-service) systemctl list-unit-files "$value" --no-legend 2>/dev/null | grep -q "${value%%.*}" ;;
        "") return 0 ;;
        *) echo "⚠️  Unknown deployment.kind '$kind' in $manifest" >&2; return 1 ;;
    esac
)

# Emits '<environment-dir>|<dockerfile-relative-path>|<apt-updates>' for the
# first local-image declaration whose glob matches $1. Manifest order is
# significant, allowing a specific pattern to precede a broader one.
local_image_metadata() {
    local image_ref="$1" manifest env_dir pattern dockerfile apt_updates row
    _require_yq || return 1
    for manifest in "$REPO_DIR"/environments/*/maintenance.yaml; do
        [ -f "$manifest" ] || continue
        env_dir="$(dirname "$manifest")"
        while IFS='|' read -r pattern dockerfile apt_updates; do
            [ -n "$pattern" ] || continue
            case "$image_ref" in
                $pattern)
                    printf '%s|%s|%s\n' "$env_dir" "$dockerfile" "${apt_updates:-true}"
                    return 0
                    ;;
            esac
        # Two separate bugs were fixed on this one line; both made it return
        # nothing or the wrong thing, silently, for every image.
        #
        # 1. No -r. _yq is `yq eval "$1" "$2"` — exactly two arguments — so a
        #    third is silently dropped. `_yq -r <expr> <manifest>` therefore
        #    ran `yq eval -r <expr>`: the EXPRESSION was "-r" and the real
        #    expression was taken as the FILENAME, leaving yq with nothing to
        #    read. It printed its usage banner to stderr and matched nothing,
        #    every time. -r is redundant anyway — raw unquoted scalars are
        #    go-yq eval's default (see _yq's own comment in lib/yaml-lib.sh).
        #
        # 2. No `// true` on .apt_updates. go-yq's `//` is jq's alternative
        #    operator, which treats `false` as absent exactly like `null` —
        #    so `.apt_updates // true` turned every explicitly-declared
        #    `apt_updates: false` (aider, claude-cli, codex-cli,
        #    classic-mac-vnc, nanoclaw-mnemon, openclaw) into `true`. The
        #    default belongs on the bash side, where it already is and where
        #    an empty field means absent and nothing else:
        #    "${apt_updates:-true}" just above.
        done < <(_yq '.updates.local_images[]? | [.image_pattern, .dockerfile, .apt_updates] | join("|")' "$manifest")
    done
    return 1
}
