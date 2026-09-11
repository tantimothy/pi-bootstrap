#!/bin/bash
#
# Generates a Herdr pane layout pointing at whatever agent environments this
# repo currently has deployed.
#
# WHY THIS EXISTS: anyone can install Herdr. What this repo uniquely knows is
# which agent environments are deployed and what SSH port each one listens
# on — that information lives in each environment's own .env, and nothing
# else has it. The discovery below is the valuable part; emitting it is a
# thin layer on top.
#
# ─────────────────────────────────────────────────────────────────────────
# ONE THING IS DELIBERATELY NOT GUESSED
#
# Herdr's own docs say "the installed binary is the authority for command
# syntax" and this repo has NOT verified the exact pane-creation invocation,
# nor Herdr's session.json schema. So this script does not write a
# session.json and does not pretend to know the flags: it emits a shell
# script whose herdr invocation is factored into ONE function at the top
# (`herdr_pane`), which you confirm against `herdr --help` once and then
# never touch again.
#
# That is a deliberate trade. Guessing a JSON schema would produce something
# that looks right, silently fails, and is hard to debug — the exact failure
# mode docs/lessons-learned warns about repeatedly. Emitting a readable
# script fails loudly and is trivially fixable.
# ─────────────────────────────────────────────────────────────────────────
#
# bash 3.2 compatible (macOS default): no mapfile, no associative arrays.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$ENV_DIR/../.." && pwd)"
ENVIRONMENTS_DIR="$REPO_DIR/environments"

DRY_RUN=false
OUTPUT=""

usage() {
    cat <<'USAGE'
Usage: generate-session.sh [--dry-run] [--output PATH]

Discovers deployed agent environments and emits a shell script that opens
one Herdr pane per agent, labelled with the repo its workspace points at.

  --dry-run      Print the generated script to stdout, write nothing.
  --output PATH  Where to write it. Defaults to $HERDR_SESSION_OUTPUT, else
                 ~/.config/herdr/open-fleet.sh
  -h, --help     This message.

Discovery rules — an environment is included when ALL of these hold:
  * environments/<name>/.env exists (i.e. it has been configured), AND
  * that .env defines SSH_PORT.

Environments with no SSH port (openclaw, nanoclaw-mnemon, hermes) are
reported separately with the docker exec command to reach them, rather than
being silently dropped.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --output)  OUTPUT="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# herdr-client's own .env supplies the defaults.
if [ -f "$ENV_DIR/.env" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_DIR/.env"
    set +a
fi
TARGET_HOST="${HERDR_TARGET_HOST:-localhost}"
[ -n "$OUTPUT" ] || OUTPUT="${HERDR_SESSION_OUTPUT:-$HOME/.config/herdr/open-fleet.sh}"

# Reads KEY from a .env file without sourcing it — these files belong to
# other environments and may set anything; we only want two values and have
# no business executing their contents.
_env_value() {
    local file="$1" key="$2" line
    [ -f "$file" ] || return 1
    line="$(grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null | tail -1)" || return 1
    [ -n "$line" ] || return 1
    line="${line#*=}"
    line="${line%\"}"; line="${line#\"}"
    line="${line%\'}"; line="${line#\'}"
    printf '%s' "$line"
}

# A pane labelled "claude" tells you nothing when six agents are running on
# six different repos. The workspace path is what identifies the work, so
# the label is <agent>:<repo-basename>.
_repo_label() {
    local path="$1"
    [ -n "$path" ] || { printf 'no-workspace'; return; }
    path="${path%/}"
    printf '%s' "${path##*/}"
}

# Environments that publish SSH, and the login user baked into each image.
# Kept as parallel arrays rather than an associative array: bash 3.2.
SSH_ENVS="claude-cli codex-cli aider opencode omp pi"
_ssh_user_for() {
    case "$1" in
        claude-cli) printf 'claude' ;;
        codex-cli)  printf 'codex' ;;
        aider)      printf 'aider' ;;
        opencode)   printf 'opencode' ;;
        omp)        printf 'omp' ;;
        pi)         printf 'pi' ;;
        *)          printf '' ;;
    esac
}
_workspace_var_for() {
    case "$1" in
        claude-cli) printf 'CLAUDE_WORKSPACE_PATH' ;;
        codex-cli)  printf 'CODEX_WORKSPACE_PATH' ;;
        aider)      printf 'AIDER_WORKSPACE_PATH' ;;
        opencode)   printf 'OPENCODE_WORKSPACE_PATH' ;;
        omp)        printf 'OMP_WORKSPACE_PATH' ;;
        pi)         printf 'PI_WORKSPACE_PATH' ;;
        *)          printf '' ;;
    esac
}

FOUND=0
PANES=""      # newline-separated "label<TAB>command"
SKIPPED=""

for name in $SSH_ENVS; do
    env_file="$ENVIRONMENTS_DIR/$name/.env"
    [ -f "$env_file" ] || continue

    port="$(_env_value "$env_file" SSH_PORT || true)"
    if [ -z "$port" ]; then
        SKIPPED="${SKIPPED}  $name — .env exists but defines no SSH_PORT
"
        continue
    fi

    ws_var="$(_workspace_var_for "$name")"
    ws_path="$(_env_value "$env_file" "$ws_var" || true)"
    label="${name%%-*}:$(_repo_label "$ws_path")"
    user="$(_ssh_user_for "$name")"

    PANES="${PANES}${label}	ssh -p ${port} ${user}@${TARGET_HOST}
"
    FOUND=$((FOUND + 1))
done

# Environments with no SSH port. Reported rather than dropped — see README's
# "Herdr can drive the orchestrator, and only watch the crew" for why
# nanoclaw-mnemon gets exactly one pane and not one per conversation group.
NO_SSH=""
if [ -f "$ENVIRONMENTS_DIR/openclaw/.env" ]; then
    NO_SSH="${NO_SSH}openclaw	docker exec -it \${CONTAINER_NAME:-openclaw} openclaw-cli-tmux
"
fi
if [ -f "$ENVIRONMENTS_DIR/nanoclaw-mnemon/.env" ]; then
    NO_SSH="${NO_SSH}nanoclaw-admin	docker exec -it \${CONTAINER_NAME:-nanoclaw-mnemon} tmux attach -t claude
"
fi
if [ -f "$ENVIRONMENTS_DIR/hermes/.env" ]; then
    # The venv path, not a bare `hermes`: upstream's own Docker guide gives
    # /opt/hermes/.venv/bin/hermes as the in-container invocation, and the
    # `hermes` shim on PATH behaves differently under docker exec.
    NO_SSH="${NO_SSH}hermes	docker exec -it \${CONTAINER_NAME:-hermes} /opt/hermes/.venv/bin/hermes
"
fi

if [ "$FOUND" -eq 0 ] && [ -z "$NO_SSH" ]; then
    echo "No configured agent environments found under $ENVIRONMENTS_DIR." >&2
    echo "Deploy one (claude-cli, codex-cli, aider, opencode, omp, pi) first." >&2
    exit 1
fi

_emit() {
    cat <<HEADER
#!/bin/bash
# Generated by environments/herdr-client/scripts/generate-session.sh
# on $(date -u +%Y-%m-%dT%H:%M:%SZ) — regenerate rather than editing.
#
# Opens one Herdr pane per deployed agent environment. Panes are labelled
# <agent>:<repo> because six panes reading "claude", "codex", "aider" tell
# you nothing about which project each is in — which is the only thing you
# need when the sidebar says one of them is blocked.
#
# SSH panes are used even for containers on this machine. That costs a local
# hop and buys two things: one pane shape covers local and remote alike, and
# the account running Herdr (and therefore Collie, and therefore your phone)
# stays pointed at an unprivileged container account rather than at the
# container runtime.

set -euo pipefail

# ─── CONFIRM THIS ONCE ───────────────────────────────────────────────────
# Herdr's docs say the installed binary is the authority for command syntax,
# and this repo has not verified the pane-creation flags. Run:
#
#     herdr --help
#     herdr pane --help     # or whichever group owns pane creation
#
# then fix the invocation below. Everything else in this file is discovered
# from your own .env files and does not need touching.
herdr_pane() {
    local label="\$1" command="\$2"
    herdr pane new --label "\$label" -- \$command
}
# ─────────────────────────────────────────────────────────────────────────

HEADER

    if [ -n "$PANES" ]; then
        printf '# --- SSH panes (%s) ---\n' "$FOUND"
        printf '%s' "$PANES" | while IFS='	' read -r label cmd; do
            [ -n "$label" ] || continue
            printf 'herdr_pane "%s" "%s"\n' "$label" "$cmd"
        done
        printf '\n'
    fi

    if [ -n "$NO_SSH" ]; then
        cat <<'NOSSH_HEADER'
# --- No SSH port: docker exec (review before running) ---
# These reach the container runtime rather than an unprivileged SSH account.
# On Linux that needs docker-group membership, which is effectively root on
# that host — and is what a phone reaches if you also run collie-client.
NOSSH_HEADER
        printf '%s' "$NO_SSH" | while IFS='	' read -r label cmd; do
            [ -n "$label" ] || continue
            printf '# herdr_pane "%s" "%s"\n' "$label" "$cmd"
        done
        printf '\n'
    fi

    printf '# nanoclaw-mnemon gets ONE pane (its admin claude session), not one per\n'
    printf '# conversation group: group containers are spawned dynamically, so a\n'
    printf '# generated list of them would be stale by design.\n'
}

if [ "$DRY_RUN" = true ]; then
    _emit
    if [ -n "$SKIPPED" ]; then
        printf '\n# Skipped:\n%s' "$SKIPPED" >&2
    fi
    exit 0
fi

mkdir -p "$(dirname "$OUTPUT")"
_emit > "$OUTPUT"
chmod +x "$OUTPUT"

echo "✅ Wrote $OUTPUT"
echo "   $FOUND SSH pane(s)$([ -n "$NO_SSH" ] && echo ", plus docker-exec entries commented out for review")"
if [ -n "$SKIPPED" ]; then
    printf "   Skipped:\n%s" "$SKIPPED"
fi
echo ""
echo "   ⚠️  Confirm the herdr_pane() invocation at the top of that file"
echo "      against \`herdr --help\` before running it — this repo has not"
echo "      verified Herdr's pane-creation flags."
