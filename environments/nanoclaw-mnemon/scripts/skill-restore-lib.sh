#!/usr/bin/env bash
# Sourced by run.sh. Restores the SOURCE wiring of an upstream-NanoClaw skill
# install after CLEAN's `git reset --hard` has reverted its tracked half.
#
# What it does and does not do. It replays only the *mechanical, declarative*
# directives in the skill's own SKILL.md — `nc:copy`, `nc:append`, `nc:dep` —
# reading file lists, import lines and dependency pins from that file at deploy
# time, so nothing here goes stale when upstream bumps a pin. It deliberately
# never runs a skill's `nc:run` steps: for /add-onecli that is setup.ts, whose
# default path re-runs the OneCLI *installer* (rebinding the gateway listener
# and installing upstream's pinned gateway version) whenever the `onecli` CLI
# is absent — which it always is right after the orchestrator container is
# recreated. The gateway service and its credentials survive CLEAN; only the
# source wiring needs restoring. Build and tests run later in the normal deploy.
#
# Bash 3.2 compatible (no mapfile, no associative arrays).

SKILL_RESTORE_LOG=""
_skill_restore_log() { SKILL_RESTORE_LOG="${SKILL_RESTORE_LOG}- ${1}
"; }

# Prints, for every ```nc:<directive> fence in a SKILL.md:
#   H<TAB><header args>      once per fence
#   L<TAB><body line>        for each line inside it
_skill_fences() { # <SKILL.md> <directive>
    awk -v d="$2" '
        /^```nc:/ {
            rest = substr($0, 7); split(rest, h, " ")
            if (h[1] == d) { infence = 1; print "H\t" substr(rest, length(d) + 2); next }
        }
        /^```/ { infence = 0; next }
        infence { print "L\t" $0 }
    ' "$1"
}

# A path that stays inside the install: relative, no "..", plain characters.
_skill_safe_relpath() {
    case "$1" in ""|/*|*..*) return 1 ;; esac
    [[ "$1" =~ ^[A-Za-z0-9._/@+-]+$ ]]
}

# Runs a snippet in a throwaway container built from the orchestrator image,
# with the install mounted at the SAME absolute path (as the real container
# has it). Used for `pnpm add`, so the host needs neither node nor pnpm.
_skill_in_install_container() {
    "$DOCKER" run --rm --entrypoint bash -v "${INSTALL_PATH}:${INSTALL_PATH}" -w "$INSTALL_PATH" \
        "$IMAGE_TAG" -lc "$1"
}

# restore_skill_install <skill-dir-name>   e.g. add-onecli, add-telegram
# Returns 0 only if every directive was replayed. Never exits the script.
restore_skill_install() {
    local skill="$1"
    local md="${INSTALL_PATH}/.claude/skills/${skill}/SKILL.md"
    local skill_dir="${INSTALL_PATH}/.claude/skills/${skill}"
    local ok=0 copied=0 kind line hdr dst src tmp branch pkg ver target marker

    if [ ! -f "$md" ]; then
        _skill_restore_log "${skill}: **NOT RESTORED** — ${md#${INSTALL_PATH}/} is missing from this NanoClaw checkout."
        return 1
    fi

    # 1. nc:copy — from the skill's own payload, or from a git branch.
    local fetched_branches=" "
    hdr=""
    while IFS=$'\t' read -r kind line; do
        if [ "$kind" = H ]; then hdr="$line"; continue; fi
        line="${line%%#*}"; line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -z "$line" ] && continue
        if [[ "$line" == *" -> "* ]]; then src="${line%% -> *}"; dst="${line##* -> }"; else src="$line"; dst="$line"; fi
        if ! _skill_safe_relpath "$src" || ! _skill_safe_relpath "$dst"; then
            _skill_restore_log "${skill}: **SKIPPED** copy '${line}' — path not safe/relative."; ok=1; continue
        fi
        mkdir -p "$(dirname "${INSTALL_PATH}/${dst}")"
        tmp="${INSTALL_PATH}/${dst}.pi-bootstrap-tmp"
        if [[ "$hdr" == *from-branch:* ]]; then
            branch="${hdr##*from-branch:}"; branch="${branch%% *}"
            if ! [[ "$branch" =~ ^[A-Za-z0-9._/-]+$ ]]; then
                _skill_restore_log "${skill}: **SKIPPED** branch '${branch}' — unexpected characters."; ok=1; continue
            fi
            if [[ "$fetched_branches" != *" ${branch} "* ]]; then
                if ! git -C "$INSTALL_PATH" fetch -q origin "+refs/heads/${branch}:refs/remotes/origin/${branch}" 2>/dev/null; then
                    _skill_restore_log "${skill}: **FAILED** to fetch origin/${branch} (network?)."; return 1
                fi
                fetched_branches="${fetched_branches}${branch} "
            fi
            if git -C "$INSTALL_PATH" show "origin/${branch}:${src}" > "$tmp" 2>/dev/null; then
                mv "$tmp" "${INSTALL_PATH}/${dst}"; copied=$((copied + 1))
            else
                rm -f "$tmp"; _skill_restore_log "${skill}: **FAILED** to read origin/${branch}:${src}."; ok=1
            fi
        else
            if [ -f "${skill_dir}/${src}" ]; then
                cp "${skill_dir}/${src}" "${INSTALL_PATH}/${dst}"; copied=$((copied + 1))
            else
                _skill_restore_log "${skill}: **FAILED** — payload file '${src}' not found in the skill."; ok=1
            fi
        fi
    done < <(_skill_fences "$md" copy)
    if [ "$copied" -eq 0 ]; then
        _skill_restore_log "${skill}: **NOTHING COPIED** — no usable nc:copy directive found in SKILL.md (its format may have changed)."; ok=1
    else
        _skill_restore_log "${skill}: ${copied} file(s) copied (overwritten from the skill's current payload/branch)"
    fi

    # 2. nc:append — one line at a time, only if absent. A line that targets an
    # `at:<marker>` region is only ever checked, never spliced blind.
    hdr=""
    while IFS=$'\t' read -r kind line; do
        if [ "$kind" = H ]; then hdr="$line"; continue; fi
        [ -z "$line" ] && continue
        target="${hdr#to:}"; target="${target%% *}"; marker=""
        [[ "$hdr" == *" at:"* ]] && marker="${hdr##* at:}"
        if ! _skill_safe_relpath "$target" || [ ! -f "${INSTALL_PATH}/${target}" ]; then
            _skill_restore_log "${skill}: **SKIPPED** append to '${target}' — file missing."; ok=1; continue
        fi
        if grep -qF "$line" "${INSTALL_PATH}/${target}"; then continue; fi
        if [ -n "$marker" ]; then
            _skill_restore_log "${skill}: **NOT SPLICED** '${line}' into ${target} — it targets marker region '${marker}', which is not edited blind."; ok=1; continue
        fi
        # Make sure the file ends in a newline before appending.
        [ -n "$(tail -c1 "${INSTALL_PATH}/${target}")" ] && printf '\n' >> "${INSTALL_PATH}/${target}"
        printf '%s\n' "$line" >> "${INSTALL_PATH}/${target}"
        _skill_restore_log "${skill}: appended \`${line}\` to ${target}"
    done < <(_skill_fences "$md" append)

    # 3. nc:dep — exact pins; `pnpm add` only when package.json doesn't already
    # carry that exact version.
    while IFS=$'\t' read -r kind line; do
        [ "$kind" = H ] && continue
        line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -z "$line" ] && continue
        pkg="${line%@*}"; ver="${line##*@}"
        if ! [[ "$line" =~ ^@?[A-Za-z0-9._/-]+@[0-9][A-Za-z0-9.+-]*$ ]]; then
            _skill_restore_log "${skill}: **SKIPPED** dependency '${line}' — not an exact pin."; ok=1; continue
        fi
        if grep -q "\"${pkg}\": \"${ver}\"" "${INSTALL_PATH}/package.json" 2>/dev/null; then continue; fi
        if [ -z "$("$DOCKER" images -q "$IMAGE_TAG" 2>/dev/null)" ]; then
            _skill_restore_log "${skill}: **NOT RESTORED** dependency ${line} — no orchestrator image to run pnpm in."; ok=1; continue
        fi
        if _skill_in_install_container "pnpm add --save-exact '${line}'" >/dev/null 2>&1; then
            _skill_restore_log "${skill}: dependency ${line} added"
        else
            _skill_restore_log "${skill}: **FAILED** \`pnpm add ${line}\` (network, or node/pnpm engine mismatch)."; ok=1
        fi
    done < <(_skill_fences "$md" dep)

    return "$ok"
}
