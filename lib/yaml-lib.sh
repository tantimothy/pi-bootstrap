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
# more than one marker gets every one resolved, not just the first.
_yaml_expand() {
    local s="$1" result="$1" var default expr val
    while [[ "$result" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)(:-([^}]*))?\} ]]; do
        expr="${BASH_REMATCH[0]}"
        var="${BASH_REMATCH[1]}"
        default="${BASH_REMATCH[3]}"
        val="${!var:-$default}"
        result="${result//$expr/$val}"
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
