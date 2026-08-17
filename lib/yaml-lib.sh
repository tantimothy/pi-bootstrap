#!/usr/bin/env bash
# Shared YAML-reading helpers for the *-lib.sh generic drivers
# (desktop-lib.sh's run_desktop_install_yaml, info-lib.sh's run_info_yaml)
# and any per-environment override script that needs the same primitives.
#
# Requires go-yq (github.com/mikefarah/yq) specifically — NOT the
# Python jq-wrapper some distros package under the same "yq" name (Debian/
# Ubuntu's apt package is that wrapper; its `yq '.foo' file.yaml` jq-filter
# syntax silently means something different and will misparse or error on
# the eval-style filters used here). deploy.sh installs the real one to
# /usr/local/bin/yq (ahead of /usr/bin on $PATH) before anything in this
# repo relies on it — _require_yq below is the runtime guard for any script
# invoked directly, bypassing deploy.sh's own install step.

# Confirms the `yq` on $PATH is go-yq, not a same-named impostor. Checked
# once per calling script (cheap — a single --version call) rather than
# once per yq invocation.
_require_yq() {
    if ! command -v yq &>/dev/null; then
        echo "❌ Error: yq is required but not installed." >&2
        echo "   Run ./deploy.sh once (it installs it automatically), or see:" >&2
        echo "   https://github.com/mikefarah/yq#install" >&2
        return 1
    fi
    if ! yq --version 2>/dev/null | grep -q "mikefarah/yq"; then
        echo "❌ Error: found a 'yq' on \$PATH that isn't go-yq (mikefarah/yq)." >&2
        echo "   This is likely the Python jq-wrapper some distros package under" >&2
        echo "   the same name (e.g. Debian/Ubuntu's apt 'yq') — it uses jq-filter" >&2
        echo "   syntax, not the eval syntax this repo's YAML files rely on." >&2
        echo "   Run ./deploy.sh once (it installs the correct one to" >&2
        echo "   /usr/local/bin/yq, ahead of /usr/bin on \$PATH), or install it" >&2
        echo "   yourself: https://github.com/mikefarah/yq#install" >&2
        return 1
    fi
    return 0
}

# Resolves ${VAR} / ${VAR:-default} markers in a string against real bash
# variables already in scope (the calling *_yaml() loader is expected to
# have sourced .env and set any synthetic ones — SCRIPT_DIR, ENV_DIR,
# HOST_IP — before calling this). Deliberately NOT full shell
# interpolation: only plain-name parameter expansion is recognized, no
# command substitution or arbitrary code, since the source strings come
# from YAML files this function has no reason to trust more than any other
# repo-authored input. A ${VAR} with no default resolves to the variable's
# value, or "" if unset — matching plain bash expansion.
#
# Loops (rather than a single non-overlapping regex pass) so a string with
# more than one marker gets every one resolved, not just the first. Each
# iteration resolves the first remaining marker; repeated markers are picked
# up by later iterations.
#
# Substitution is done with prefix/suffix splitting rather than the obvious
# `result="${result//$expr/$val}"`, and that is not a style preference:
#
#   - In bash 5.2+, an unquoted `&` in a pattern-substitution REPLACEMENT
#     expands to whatever the pattern just matched. So a value containing
#     `&` — a URL with two query parameters, a shell snippet redirecting
#     with `2>&1`, an "X & Y" label — silently expanded to the marker text
#     itself, re-injecting `${VAR}` into the result. The loop above then
#     matched it again, substituted again, and never terminated: a hang, not
#     a wrong answer. Hit for real by a template containing `2>&1`.
#   - Escaping the `&` instead would work on 5.2+ but relies on replacement
#     backslash handling that differs on the bash 3.2 macOS still ships,
#     which this repo has to keep working.
#
# Quoting "$expr" inside the pattern makes it a literal (only the trailing/
# leading `*` stays a wildcard), and the value is concatenated in directly,
# so no character in it is special. Works identically on bash 3.2 and 5.x.
_yaml_expand() {
    local s="$1" result="$1" var default expr val prefix suffix
    while [[ "$result" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)(:-([^}]*))?\} ]]; do
        expr="${BASH_REMATCH[0]}"
        var="${BASH_REMATCH[1]}"
        default="${BASH_REMATCH[3]}"
        val="${!var:-$default}"
        prefix="${result%%"$expr"*}"
        suffix="${result#*"$expr"}"
        result="${prefix}${val}${suffix}"
    done
    printf '%s' "$result"
}

# Runs `yq eval <expr> <file>`, one result per line — the workhorse behind
# every scalar/array read in the two *_yaml() loaders. `-r`-equivalent
# (raw, unquoted scalars) is go-yq's eval default, so plain strings come
# back exactly as written in the YAML, no quote-stripping needed.
_yq() {
    yq eval "$1" "$2"
}

# Portable replacement for `mapfile -t ARRAY < <(cmd)` — mapfile/readarray
# is bash 4+ only, but macOS ships bash 3.2 (GPL licensing, unmaintained by
# Apple since 2007) with neither builtin at all, silently leaving the
# target array unset rather than erroring (e.g. WEB_UI_NAMES never gets
# populated, so the "Web UIs" section just never prints — no error, no
# obvious cause). Populates the fixed global _LINES array rather than
# taking a caller-supplied array name: bash 3.2 has neither `mapfile` NOR
# `declare -n` nameref (that's 4.3+ too), so there's no eval-free way to
# write into a dynamically-named array — copy out of _LINES immediately
# after calling this.
# Usage: _read_lines < <(cmd); ARRAY=("${_LINES[@]}")
_read_lines() {
    _LINES=()
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        _LINES+=("$line")
    done
}

# ---------------------------------------------------------------------------
# Batched multi-field YAML read.
#
# The two *_yaml() loaders used to make one `yq eval` call per field against
# the same small file — 18 for info.yaml, 15 for desktop-entries.yaml, plus
# _require_yq's own `yq --version | grep` on top. That is per environment, and
# both backup.sh and install-desktop-entries.sh run a loader for every one of
# the ~21 environments in a single command, so reading a few hundred lines of
# YAML cost several hundred process startups. yq's startup dominates; the
# parsing does not.
#
# _yaml_read_fields runs ONE yq invocation for the whole file. The field map
# ($2) is "<name>|<yq expression>" lines; each field is announced in the output
# by a marker line and followed by its value lines, and $3 is called once per
# field with the name in $1 and the lines in _YAML_FIELD_LINES.
#
# The marker is a lone \001 byte plus the field name. It cannot be produced by
# a value in these files: a literal control character in YAML source is already
# unusual, and yq quotes any string containing one on output, so it could never
# emerge as a bare marker line.
#
# An array field emits one line per element and a scalar emits however many
# lines it has, which is what keeps a `useful_commands: |` block intact —
# callers rejoin those with _yaml_field_scalar.
# ---------------------------------------------------------------------------
_YAML_FIELD_MARK=$'\001'

_yaml_read_fields() {
    local yaml="$1" field_map="$2" handler="$3"
    local name expr query="" line current="" started=false

    while IFS='|' read -r name expr; do
        [ -n "$name" ] || continue
        query="${query}\"${_YAML_FIELD_MARK}${name}\", (${expr}), "
    done <<YAML_FIELD_MAP
$field_map
YAML_FIELD_MAP
    # Trailing ", " removed — yq rejects a dangling comma.
    query="${query%, }"

    _YAML_FIELD_LINES=()
    while IFS= read -r line; do
        case "$line" in
            "${_YAML_FIELD_MARK}"*)
                # A marker closes the previous field before opening this one.
                # $started guards only the very first marker, which has no
                # predecessor to flush.
                [ "$started" = "true" ] && "$handler" "$current"
                started=true
                current="${line#"$_YAML_FIELD_MARK"}"
                _YAML_FIELD_LINES=()
                ;;
            *)
                _YAML_FIELD_LINES+=("$line")
                ;;
        esac
    done < <(yq eval "$query" "$yaml")
    [ "$started" = "true" ] && "$handler" "$current"
    return 0
}

# Rejoins the current field's lines into one scalar, reproducing exactly what
# `$(_yq '<expr>' file)` used to yield for the same field — including command
# substitution's stripping of trailing newlines, which is why trailing empty
# lines are dropped rather than preserved.
_yaml_field_scalar() {
    local i last=-1 out=""
    for i in "${!_YAML_FIELD_LINES[@]}"; do
        [ -n "${_YAML_FIELD_LINES[$i]}" ] && last=$i
    done
    [ "$last" -lt 0 ] && return 0
    # Arithmetic for-loop, not `seq` — a subprocess here would undo part of
    # what this whole mechanism exists to save.
    for (( i=0; i<=last; i++ )); do
        if [ "$i" -eq 0 ]; then out="${_YAML_FIELD_LINES[$i]}"
        else out="${out}"$'\n'"${_YAML_FIELD_LINES[$i]}"; fi
    done
    printf '%s' "$out"
}
