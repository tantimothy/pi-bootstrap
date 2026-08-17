#!/usr/bin/env bash
# Shared list/delete logic for all environment info.sh scripts.
#
# The calling info.sh must set before sourcing this file:
#   SCRIPT_DIR   — absolute path to the environment directory
#   ACTION       — "list", "delete", or "manifest" (the last is used by the
#                  repo root's backup.sh — see run_info()'s manifest branch)
#
# "list" also (re)generates SCRIPT_DIR/post-deploy-info.html — the same
# content as the terminal listing, as a self-contained HTML page with any
# web UI URLs in USEFUL_COMMANDS turned into clickable links.
#
# Arrays (always declare these; set to () if unused):
#   DATA_DIRS + DATA_DESCRIPTIONS       — also what backup.sh backs up (paths
#                                         are preserved as-is, wherever they
#                                         actually live: inside this
#                                         environment's own directory or
#                                         elsewhere, e.g. $HOME)
#   INSTALL_DIRS + INSTALL_DESCRIPTIONS
#   NAMED_VOLUMES + NAMED_VOLUME_DESCRIPTIONS  — also what backup.sh snapshots
#                                                 via a throwaway container
#
# Optional arrays (declare as () if unused):
#   WIPE_PARENT_DIRS     — parent dirs to rm -rf after DATA_DIRS are deleted (e.g. ~/internet-monitoring)
#   WEB_UI_NAMES + WEB_UI_URLS  — parallel arrays of clickable web UIs; the
#                                 HTML page renders these as a table, the
#                                 terminal listing as an aligned list. Skip
#                                 for non-http endpoints (e.g. a VNC address)
#                                 — put those in USEFUL_COMMANDS as plain text.
#   ACTIVE_CONFIG_LABELS + ACTIVE_CONFIG_VALUES  — parallel arrays of
#                                 runtime-relevant settings and their
#                                 resolved values (e.g. "Wireless interface"
#                                 / "wlan1") — the outer-menu equivalent of
#                                 an in-container "Active configuration"
#                                 block. Only for values that actually vary
#                                 per-deploy (an env var with a real
#                                 default); a fixed architectural fact
#                                 belongs in USEFUL_COMMANDS' Notes instead.
#
# Optional scalars (library provides defaults):
#   DATA_DIRS_LABEL      — heading for the data dirs section
#   INSTALL_DIRS_LABEL   — heading for the install dirs section
#   NO_DATA_MSG          — shown in list when DATA_DIRS is empty
#   NO_DELETE_MSG        — shown in delete when there is nothing to remove
#   DELETE_CONFIRM_MSG   — text shown in the deletion confirmation prompt
#   DELETE_INSTALL_DIRS  — "true" to include INSTALL_DIRS in the wipe (default: false)
#   USEFUL_COMMANDS      — multiline string of commands to display (bash-interpolated in info.sh)

# REPO_DIR is already set by every caller (each environment's info.sh)
# before it sources this file.
source "$REPO_DIR/lib/yaml-lib.sh"

_C_BOLD=$'\033[1m'
_C_CYAN=$'\033[36m'
_C_GREEN=$'\033[32m'
_C_DIM=$'\033[2m'
_C_RESET=$'\033[0m'

# Wraps $2 in color code $1 (one of the _C_* above) — unless _INFO_PLAIN=1
# (set while run_info() builds the HTML page via _info_html, which captures
# _info_dirs_and_volumes_text's output through command substitution and
# HTML-escapes it; raw ANSI codes would leak into the page as garbage) or
# stdout isn't an actual terminal (a non-interactive `curl | bash` deploy,
# or output redirected to a file/log).
#
# `[ -t 1 ]` alone isn't enough: run_info()'s normal terminal path pipes
# `_info_list | less -Xr` so long output can be paged — the left side of
# that pipe runs with its OWN stdout connected to the pipe, not the real
# terminal, so `[ -t 1 ]` inside _info_list (and everything it calls) is
# always false there, silently disabling color on every ordinary run
# (confirmed directly: not a hypothetical). run_info() sets
# _INFO_FORCE_COLOR=1 on that specific invocation — from ITS OWN, still-a-
# real-terminal context — to say "yes, this really is going to a
# real terminal, even though you personally can't see that from here."
_color() {
    if [ "${_INFO_PLAIN:-0}" = "1" ]; then
        printf '%s' "$2"
    elif [ "${_INFO_FORCE_COLOR:-0}" = "1" ] || [ -t 1 ]; then
        printf '%s%s%s' "$1" "$2" "$_C_RESET"
    else
        printf '%s' "$2"
    fi
}

# ---------------------------------------------------------------------------
# Measurement cache for the dirs/volumes listing.
#
# run_info's "list" action renders this same content TWICE — once plain into
# post-deploy-info.html, once colored to the terminal — and the two passes
# can't share their rendered output, because the whole point of the second
# one is that it's colored differently. What they can share is the expensive
# part: a `du -sh` per directory, and (per named volume) a `docker volume
# inspect` plus a `docker volume ls`. Caching the *measurements* instead of
# the text keeps both passes independent while paying for the measuring once.
#
# The Docker CLI round-trips are the ones that hurt: chat-frontends declares
# 12 named volumes, so the per-volume version cost 24 daemon round-trips per
# render — 48 across both passes — for one INFO screen. Now it's two calls
# total, regardless of how many volumes an environment declares.
#
# An entry holds the `du -sh` size column, or $_INFO_ABSENT when the path/
# volume doesn't exist. That distinction needs its own sentinel rather than
# just an empty string, because "exists but du couldn't read it" legitimately
# produces an empty size and must still render as a size, not as "not yet
# created" — which is what the per-row `[ -d ]`/EXISTS tests used to convey.
# ---------------------------------------------------------------------------
_INFO_ABSENT=$'\001absent'
_INFO_SIZES_CACHED=0
_DATA_DIR_SIZES=()
_INSTALL_DIR_SIZES=()
_NAMED_VOLUME_SIZES=()

# Existing Docker volume names, newline-separated, fetched at most once per
# process. Replaces `docker volume ls -q --filter name=^<vol>$` per volume.
_INFO_VOLUME_LIST_CACHED=0
_INFO_VOLUME_LIST=""
_info_load_volume_list() {
    [ "$_INFO_VOLUME_LIST_CACHED" = "1" ] && return 0
    _INFO_VOLUME_LIST="$(docker volume ls -q 2>/dev/null)"
    _INFO_VOLUME_LIST_CACHED=1
}

# Membership test against that cached listing, as a `case` glob rather than a
# grep, so checking N volumes costs no processes at all. "$1" is quoted inside
# the pattern, so a volume name is matched literally.
_info_volume_exists() {
    _info_load_volume_list
    case $'\n'"$_INFO_VOLUME_LIST"$'\n' in
        *$'\n'"$1"$'\n'*) return 0 ;;
    esac
    return 1
}

# `du -sh`'s size column for an existing directory, else $_INFO_ABSENT. The
# tab split is a parameter expansion rather than the `| cut -f1` this
# replaces — same result, one fewer process per row.
_info_measure_dir() {
    local out
    if [ -d "$1" ]; then
        out="$(du -sh "$1" 2>/dev/null)"
        printf '%s' "${out%%$'\t'*}"
    else
        printf '%s' "$_INFO_ABSENT"
    fi
}

_info_cache_sizes() {
    [ "$_INFO_SIZES_CACHED" = "1" ] && return 0
    _INFO_SIZES_CACHED=1

    local i
    _DATA_DIR_SIZES=()
    if [ "${#DATA_DIRS[@]}" -gt 0 ]; then
        for i in "${!DATA_DIRS[@]}"; do
            _DATA_DIR_SIZES[$i]="$(_info_measure_dir "${DATA_DIRS[$i]}")"
        done
    fi

    _INSTALL_DIR_SIZES=()
    if [ "${#INSTALL_DIRS[@]}" -gt 0 ]; then
        for i in "${!INSTALL_DIRS[@]}"; do
            _INSTALL_DIR_SIZES[$i]="$(_info_measure_dir "${INSTALL_DIRS[$i]}")"
        done
    fi

    _info_cache_volume_sizes
}

_info_cache_volume_sizes() {
    local i vol name mp out mounts existing

    _NAMED_VOLUME_SIZES=()
    [ "${#NAMED_VOLUMES[@]}" -gt 0 ] || return 0

    existing=()
    for i in "${!NAMED_VOLUMES[@]}"; do
        vol="${NAMED_VOLUMES[$i]}"
        if _info_volume_exists "$vol"; then
            _NAMED_VOLUME_SIZES[$i]=""
            existing+=("$vol")
        else
            _NAMED_VOLUME_SIZES[$i]="$_INFO_ABSENT"
        fi
    done
    [ "${#existing[@]}" -gt 0 ] || return 0

    # One inspect for every existing volume at once. Only existing ones are
    # passed: `docker volume inspect` exits non-zero on a name it can't find,
    # and mixing one in would make the whole call's status unreliable.
    # `{{"\t"}}` rather than a literal \t — Go templates emit text outside
    # {{...}} verbatim, so "\t" in the format string would print as a
    # backslash and a t.
    mounts="$(docker volume inspect "${existing[@]}" \
        --format '{{.Name}}{{"\t"}}{{.Mountpoint}}' 2>/dev/null)"

    while IFS=$'\t' read -r name mp; do
        [ -n "$name" ] && [ -n "$mp" ] || continue
        out="$(du -sh "$mp" 2>/dev/null)"
        out="${out%%$'\t'*}"
        # Match back to the declared order by name. NAMED_VOLUMES is at most
        # a dozen entries, so this pure-bash scan is cheaper than any way of
        # indexing it would be under bash 3.2 (no associative arrays).
        for i in "${!NAMED_VOLUMES[@]}"; do
            if [ "${NAMED_VOLUMES[$i]}" = "$name" ]; then
                _NAMED_VOLUME_SIZES[$i]="$out"
                break
            fi
        done
    done <<VOLUME_MOUNTPOINTS
$mounts
VOLUME_MOUNTPOINTS
}

# Prints one "path  (size or not-yet-created)" + description row — the
# shared row format between the DATA_DIRS and INSTALL_DIRS sections below.
# $3 is the cached measurement (see _info_cache_sizes).
_info_print_dir_row() {
    local dir="$1" desc="$2" size="$3"
    if [ "$size" != "$_INFO_ABSENT" ]; then
        printf '   %s  ' "$(_color "$_C_CYAN" "$dir")"; _color "$_C_DIM" "($size)"; echo ""
    else
        printf '   %s  ' "$(_color "$_C_CYAN" "$dir")"; _color "$_C_DIM" "(not yet created)"; echo ""
    fi
    printf '     → %s\n' "$(_color "$_C_GREEN" "$desc")"
}

# The data-dirs/install-dirs/volumes portion — factored out so _info_html
# can reuse it in the <pre> block without also pulling in the web UIs
# section, which it renders as a separate HTML table instead.
_info_dirs_and_volumes_text() {
    _info_cache_sizes

    if [ "${#DATA_DIRS[@]}" -gt 0 ]; then
        _color "$_C_BOLD" "${DATA_DIRS_LABEL:-📁 Persistent Data Directories:}"; echo ""
        local i
        for i in "${!DATA_DIRS[@]}"; do
            _info_print_dir_row "${DATA_DIRS[$i]}" "${DATA_DESCRIPTIONS[$i]}" "${_DATA_DIR_SIZES[$i]}"
        done
        echo ""
    fi

    if [ "${#INSTALL_DIRS[@]}" -gt 0 ]; then
        _color "$_C_BOLD" "${INSTALL_DIRS_LABEL:-📂 Install Directories:}"; echo ""
        local i
        for i in "${!INSTALL_DIRS[@]}"; do
            _info_print_dir_row "${INSTALL_DIRS[$i]}" "${INSTALL_DESCRIPTIONS[$i]}" "${_INSTALL_DIR_SIZES[$i]}"
        done
        echo ""
    fi

    if [ "${#NAMED_VOLUMES[@]}" -gt 0 ]; then
        _color "$_C_BOLD" "🐳 Named Docker Volumes (managed by Docker):"; echo ""
        local i
        for i in "${!NAMED_VOLUMES[@]}"; do
            local vol="${NAMED_VOLUMES[$i]}"
            local SIZE="${_NAMED_VOLUME_SIZES[$i]}"
            if [ "$SIZE" != "$_INFO_ABSENT" ]; then
                printf '   docker volume: %s  ' "$(_color "$_C_CYAN" "$vol")"; _color "$_C_DIM" "($SIZE)"; echo ""
            else
                printf '   docker volume: %s  ' "$(_color "$_C_CYAN" "$vol")"; _color "$_C_DIM" "(not yet created)"; echo ""
            fi
            printf '     → %s\n' "$(_color "$_C_GREEN" "${NAMED_VOLUME_DESCRIPTIONS[$i]}")"
        done
        echo ""
    fi

    if [ "${#DATA_DIRS[@]}" -eq 0 ] && [ "${#INSTALL_DIRS[@]}" -eq 0 ] && [ "${#NAMED_VOLUMES[@]}" -eq 0 ]; then
        _color "$_C_BOLD" "📁 Persistent Data Directories:"; echo ""
        echo "   ${NO_DATA_MSG:-(none)}"
        echo ""
    fi
}

# Plain-text web UI list for the terminal — right-pads each URL to the
# longest one so the names line up in a column, the same way a manually
# hand-padded line would, just computed instead of guessed.
_info_web_uis_text() {
    if [ -n "${WEB_UI_NAMES+x}" ] && [ "${#WEB_UI_NAMES[@]}" -gt 0 ]; then
        _color "$_C_BOLD" "🌐 Web UIs:"; echo ""
        local i maxlen=0
        for i in "${!WEB_UI_URLS[@]}"; do
            [ "${#WEB_UI_URLS[$i]}" -gt "$maxlen" ] && maxlen="${#WEB_UI_URLS[$i]}"
        done
        for i in "${!WEB_UI_NAMES[@]}"; do
            # Pad the plain URL to column width first, then color the
            # already-padded string — coloring before padding would count
            # the invisible escape codes toward %-*s's width and misalign
            # the columns.
            local padded; padded=$(printf '%-*s' "$maxlen" "${WEB_UI_URLS[$i]}")
            printf '   %s   %s\n' "$(_color "$_C_CYAN" "$padded")" "${WEB_UI_NAMES[$i]}"
        done
        echo ""
    fi
}

# Active-configuration list for the terminal — same right-padded-label
# layout as the in-container "Active configuration:" blocks this mirrors
# (see e.g. kali-pentest/entrypoint.sh's show_info), just driven by
# ACTIVE_CONFIG_LABELS/ACTIVE_CONFIG_VALUES instead of hardcoded here.
_info_active_config_text() {
    if [ -n "${ACTIVE_CONFIG_LABELS+x}" ] && [ "${#ACTIVE_CONFIG_LABELS[@]}" -gt 0 ]; then
        _color "$_C_BOLD" "⚙️  Active Configuration:"; echo ""
        local i maxlen=0
        for i in "${!ACTIVE_CONFIG_LABELS[@]}"; do
            [ "${#ACTIVE_CONFIG_LABELS[$i]}" -gt "$maxlen" ] && maxlen="${#ACTIVE_CONFIG_LABELS[$i]}"
        done
        for i in "${!ACTIVE_CONFIG_LABELS[@]}"; do
            local padded; padded=$(printf '%-*s' "$maxlen" "${ACTIVE_CONFIG_LABELS[$i]}")
            printf '   %s   %s\n' "$padded" "$(_color "$_C_CYAN" "${ACTIVE_CONFIG_VALUES[$i]}")"
        done
        echo ""
    fi
}

# Dims a single "code"-mode line from USEFUL_COMMANDS — the command itself
# (everything before a 2+-space-then-"#" comment, the established alignment
# convention every environment's info.yaml already uses) is dimmed; the
# comment is left plain, since coloring both would fight for attention and
# the comment already reads fine as-is. Uses _color, so this is
# automatically a no-op under _INFO_PLAIN (the HTML-page render pass) or a
# non-terminal stdout — see _color's own doc comment.
_colorize_command_line() {
    local line="$1"
    if [[ "$line" =~ ^(.+[^\ ])[\ ]{2,}(#.*)$ ]]; then
        printf '%s  %s\n' "$(_color "$_C_DIM" "${BASH_REMATCH[1]}")" "${BASH_REMATCH[2]}"
    elif [ -n "$line" ]; then
        _color "$_C_DIM" "$line"; echo ""
    else
        echo ""
    fi
}

_info_useful_commands_text() {
    _color "$_C_BOLD" "💡 Useful Commands:"; echo ""
    # Reuses _tag_mixed_content's own code/prose classification (the same
    # indentation-sensitive rules the HTML page's rendering already
    # depends on) so only actual command lines get dimmed — a "📌 Notes:"
    # prose section's own bullet lines stay plain, matching how they
    # already read in the HTML page; only the "📌 Notes:" header itself is
    # bolded, same treatment as every other section header. Both
    # _colorize_command_line and the bolding below go through _color, so
    # this is automatically plain text again under _INFO_PLAIN (the HTML
    # pass below still re-tags this same output itself, from scratch, so
    # nothing here needs to special-case that pass beyond staying plain).
    printf '%s\n' "$USEFUL_COMMANDS" | _tag_mixed_content | while IFS=$'\t' read -r _mode _line; do
        if [ "$_mode" = "code" ]; then
            _colorize_command_line "$_line"
        elif [ "$_line" = "📌 Notes:" ]; then
            # Same bolded-header treatment every other section gets
            # (📁 Persistent Data Directories:, 💡 Useful Commands:, ...) —
            # _tag_mixed_content's own prose/code split (see its comment)
            # keys off this exact line, so the match has to stay in sync
            # with it if that sentinel text ever changes.
            _color "$_C_BOLD" "$_line"; echo ""
        else
            printf '%s\n' "$_line"
        fi
    done
    echo ""
}

_info_list() {
    echo ""
    _info_dirs_and_volumes_text
    _info_active_config_text
    _info_web_uis_text
    _info_useful_commands_text
}

_html_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Wraps bare http(s) URLs in already-escaped text with clickable <a> tags.
# Must run AFTER _html_escape — its regex assumes no literal "<"/">" survive
# inside a URL, only "&amp;" entities, which browsers resolve fine in an href.
_linkify() {
    sed -E 's#(https?://[^[:space:]<]+)#<a href="\1" target="_blank" rel="noopener">\1</a>#g'
}

# Wraps 'single-quoted' spans in already-escaped prose with <code>, for
# inline command/config fragments mentioned mid-sentence (e.g. 'pihole
# setpassword') — the quote marks are dropped since <code>'s styling is
# what sets it apart now. Only meant for prose; a code line's own quoting
# (e.g. wgpw 'pass') stays untouched since it's already inside a <pre>.
#
# The opening/closing quote must each be a word boundary (preceded/
# followed by a non-alphanumeric character or line start/end) — otherwise
# apostrophes in contractions and possessives ("it's", "stack's") get
# misread as quote marks, pairing across them and mangling everything
# between two unrelated words.
_inline_code() {
    sed -E "s/([^a-zA-Z0-9]|^)'([^']+)'([^a-zA-Z0-9]|\$)/\1<code>\2<\/code>\3/g"
}

# Splits raw (unescaped) text into runs, tagged "code" or "prose", using
# indentation as the signal — the same convention the source text already
# uses visually: a line with no leading whitespace starts a new top-level
# section (default: code, e.g. "Useful Commands"/"Backup named volumes");
# "📌 Notes:" specifically switches to prose, where only an extra-indented
# (8+ space) line — an embedded command snippet within a note — goes back
# to code. Output: "<mode>\t<original line>", one per input line.
_tag_mixed_content() {
    awk '
        BEGIN { mode = "code" }
        /^📌 Notes:$/ { mode = "prose" }
        !/^ / && $0 != "" && $0 != "📌 Notes:" { mode = "code" }
        {
            line_mode = mode
            if (mode == "prose" && $0 ~ /^        /) line_mode = "code"
            print line_mode "\t" $0
        }
    '
}

# Consumes _tag_mixed_content's output, grouping consecutive same-mode
# lines into one block each — a <pre> for "code", a plain (still
# wrapping) <div> for "prose", with 'single-quoted' fragments in prose
# promoted to <code>.
_render_mixed_content() {
    local mode content cur_mode="" buffer=""
    while IFS=$'\t' read -r mode content; do
        if [ -n "$buffer" ] && [ "$mode" != "$cur_mode" ]; then
            _emit_content_block "$cur_mode" "$buffer"
            buffer=""
        fi
        cur_mode="$mode"
        buffer+="${content}"$'\n'
    done
    [ -n "$buffer" ] && _emit_content_block "$cur_mode" "$buffer"
}

_emit_content_block() {
    local mode="$1" text="$2" escaped
    if [ "$mode" = "code" ]; then
        escaped=$(printf '%s' "$text" | _html_escape | _linkify)
        printf '<pre>%s</pre>\n' "$escaped"
    else
        escaped=$(printf '%s' "$text" | _html_escape | _linkify | _inline_code)
        printf '<div class="prose">%s</div>\n' "$escaped"
    fi
}

# Renders the same content as _info_list (data dirs, install dirs, volumes,
# web UIs, useful commands) as a self-contained HTML page. Data dirs/
# volumes and web UIs are wholly command/tabular listings, so each gets a
# single <pre> block; useful commands/notes/backup volumes are mixed
# (commands plus prose notes with occasional embedded command snippets),
# so that portion is split per-line via _tag_mixed_content instead.
_info_html() {
    local out_file="$1"
    local title; title="pi-bootstrap: $(basename "$SCRIPT_DIR")"
    {
        cat <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>${title}</title>
<style>
  body { margin: 1.5rem; }
  /* Viewed on both mobile and desktop, so text has to reflow to whatever
     width is actually available — pre-wrap wraps at whitespace like
     normal paragraph text, and overflow-wrap only breaks a token
     mid-word as a last resort (e.g. a URL wider than the whole
     viewport), not eagerly like word-break would. */
  pre, .prose { white-space: pre-wrap; overflow-wrap: break-word; }
  pre, code { background: #f6f8fa; }
  pre { padding: 0.75rem 1rem; border-radius: 6px; }
  code { padding: 0.1rem 0.3rem; border-radius: 4px; }
  footer { color: #666; font-size: 0.85rem; margin-top: 1.5rem; }
</style>
</head>
<body>
<h1>${title}</h1>
HTML
        local dirs_text; dirs_text="$(_info_dirs_and_volumes_text)"
        [ -n "$dirs_text" ] && printf '<pre>%s</pre>\n' "$(printf '%s' "$dirs_text" | _html_escape | _linkify)"

        local active_config_text; active_config_text="$(_info_active_config_text)"
        [ -n "$active_config_text" ] && printf '<pre>%s</pre>\n' "$(printf '%s' "$active_config_text" | _html_escape | _linkify)"

        local web_ui_text; web_ui_text="$(_info_web_uis_text)"
        [ -n "$web_ui_text" ] && printf '<pre>%s</pre>\n' "$(printf '%s' "$web_ui_text" | _html_escape | _linkify)"

        _info_useful_commands_text | _tag_mixed_content | _render_mixed_content
        cat <<HTML
<footer>Generated $(date '+%Y-%m-%d %H:%M:%S %Z') — re-run this environment's run.sh, or "INFO" from ./deploy.sh, to refresh.</footer>
</body>
</html>
HTML
    } > "$out_file"
}

_info_manifest() {
    local i
    for i in "${!DATA_DIRS[@]}"; do
        [ -d "${DATA_DIRS[$i]}" ] && echo "DIR:${DATA_DIRS[$i]}"
    done
    for i in "${!NAMED_VOLUMES[@]}"; do
        echo "VOL:${NAMED_VOLUMES[$i]}"
    done
}

# rm -rf's each existing dir in $@ — shared by the DATA_DIRS/INSTALL_DIRS/
# WIPE_PARENT_DIRS deletion passes below.
_info_rm_dirs() {
    local dir
    for dir in "$@"; do
        [ -d "$dir" ] && rm -rf "$dir" && echo "🗑️  Deleted: $dir"
    done
}

# Prints one confirmation row and marks DIRS_EXIST=true if the dir exists —
# shared by the DATA_DIRS/INSTALL_DIRS/WIPE_PARENT_DIRS sections below.
# Relies on bash's dynamic scoping: DIRS_EXIST is `local` in _info_delete,
# the only caller, so it's visible here without being passed explicitly.
_info_delete_dir_row() {
    local dir="$1" desc="$2" extra="${3:-}"
    if [ -d "$dir" ]; then
        local size; size=$(du -sh "$dir" 2>/dev/null | cut -f1)
        echo "   🗑️  $dir  ($size)$extra"
        [ -n "$desc" ] && echo "       → $desc"
        DIRS_EXIST=true
    else
        echo "   ⬜  $dir  (does not exist)"
    fi
}

_info_delete() {
    echo ""
    echo "⚠️  The following will be PERMANENTLY DELETED:"
    echo ""
    local DIRS_EXIST=false i

    for i in "${!DATA_DIRS[@]}"; do
        _info_delete_dir_row "${DATA_DIRS[$i]}" "${DATA_DESCRIPTIONS[$i]}"
    done

    if [ "${DELETE_INSTALL_DIRS:-false}" = "true" ] && [ "${#INSTALL_DIRS[@]}" -gt 0 ]; then
        for i in "${!INSTALL_DIRS[@]}"; do
            _info_delete_dir_row "${INSTALL_DIRS[$i]}" "${INSTALL_DESCRIPTIONS[$i]}"
        done
    fi

    if [ "${#NAMED_VOLUMES[@]}" -gt 0 ]; then
        echo ""
        echo "   Named Docker volumes will also be removed:"
        local vol
        for vol in "${NAMED_VOLUMES[@]}"; do
            if _info_volume_exists "$vol"; then
                echo "   🗑️  docker volume: $vol"
                DIRS_EXIST=true
            else
                echo "   ⬜  docker volume: $vol  (does not exist)"
            fi
        done
    fi

    if [ -n "${WIPE_PARENT_DIRS+x}" ] && [ "${#WIPE_PARENT_DIRS[@]}" -gt 0 ]; then
        local dir
        for dir in "${WIPE_PARENT_DIRS[@]}"; do
            _info_delete_dir_row "$dir" "" "  (including any remaining contents)"
        done
    fi

    echo ""
    if [ "$DIRS_EXIST" = "false" ]; then
        echo "ℹ️  Nothing to delete."
        exit 0
    fi

    local CONFIRM
    if command -v dialog &>/dev/null; then
        dialog --clear --title " ⚠️  Delete Persistent Data " \
            --yesno "\n${DELETE_CONFIRM_MSG:-This permanently deletes all listed directories and volumes.}\n\nAre you absolutely sure?" \
            10 62
        CONFIRM=$?; clear
    else
        local CONFIRM_TEXT
        read -rp "Type 'yes' to confirm permanent deletion: " CONFIRM_TEXT
        [ "$CONFIRM_TEXT" = "yes" ] && CONFIRM=0 || CONFIRM=1
    fi

    if [ "$CONFIRM" -eq 0 ]; then
        _info_rm_dirs "${DATA_DIRS[@]}"
        if [ "${DELETE_INSTALL_DIRS:-false}" = "true" ] && [ "${#INSTALL_DIRS[@]}" -gt 0 ]; then
            _info_rm_dirs "${INSTALL_DIRS[@]}"
        fi
        if [ "${#NAMED_VOLUMES[@]}" -gt 0 ]; then
            local vol
            for vol in "${NAMED_VOLUMES[@]}"; do
                # Same cached listing the confirmation screen above was
                # rendered from, deliberately: what gets removed is exactly
                # what the user was shown and agreed to, not a re-read taken
                # after they answered.
                _info_volume_exists "$vol" && docker volume rm "$vol" && echo "🗑️  Deleted volume: $vol"
            done
        fi
        if [ -n "${WIPE_PARENT_DIRS+x}" ] && [ "${#WIPE_PARENT_DIRS[@]}" -gt 0 ]; then
            _info_rm_dirs "${WIPE_PARENT_DIRS[@]}"
        fi
        echo "✅ Done."
    else
        echo "❌ Deletion cancelled."
    fi
}

# Populates every run_info variable from $env_dir/info.yaml EXCEPT calling
# run_info itself. Split out from run_info_yaml (below) so an environment
# whose info.sh needs real branching (nanoclaw's OS-dependent service
# commands, internet-pi's PIHOLE_ENABLE/MONITORING_ENABLE feature flags)
# can call this for the data, adjust a variable or two itself, and call
# run_info directly — see nanoclaw/info.sh and internet-pi/info.sh.
#
# $env_dir/info.yaml schema (all keys optional except where noted):
#   data_dirs: [{path, description}]        data_dirs_label
#   install_dirs: [{path, description}]     install_dirs_label
#   named_volumes: [{name, description}]
#   wipe_parent_dirs: [path, ...]
#   delete_install_dirs: true|false          (default false)
#   delete_confirm_msg / no_data_msg / no_delete_msg: "..."
#   web_uis: [{name, url}]
#   active_config: [{label, value}]
#   useful_commands: |                       block scalar
#     ...
#
# Any string value may contain ${VAR} / ${VAR:-default} markers, resolved
# by _yaml_expand against real bash variables in scope: .env is sourced
# first, then SCRIPT_DIR and HOST_IP (network-detected, same logic every
# info.sh used to duplicate) are set before any substitution runs.
_load_info_yaml() {
    local env_dir="$1" action="$2"
    SCRIPT_DIR="$env_dir"
    ACTION="$action"
    local yaml="$env_dir/info.yaml"

    _require_yq || return 1

    [ -f "$env_dir/.env" ] && { set -a; source "$env_dir/.env"; set +a; }

    # `ip` and `hostname -I` are both Linux-only (iproute2 / GNU coreutils —
    # neither exists on macOS's BSD userland). `|| true` on each absorbs
    # that failure so the pipeline's exit status is always awk's (which
    # never fails, even on empty input) — under a caller running with
    # `set -e`/`pipefail`, an unguarded failure here would otherwise abort
    # the whole script silently, before printing anything.
    HOST_IP=$( { ip route get 1.1.1.1 2>/dev/null || true; } | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
    [ -z "$HOST_IP" ] && HOST_IP=$( { hostname -I 2>/dev/null || true; } | awk '{print $1}')
    [ -z "$HOST_IP" ] && HOST_IP="localhost"

    _yaml_read_fields "$yaml" "$_INFO_YAML_FIELDS" _load_info_field
}

# Field map for the read above: "<name>|<yq expression>", one per line, in the
# order they should be evaluated. Names are arbitrary labels — they exist only
# to route each field's lines to the right variable in _load_info_field below.
_INFO_YAML_FIELDS='
data_dirs.path|.data_dirs[].path
data_dirs.description|.data_dirs[].description
install_dirs.path|.install_dirs[].path
install_dirs.description|.install_dirs[].description
named_volumes.name|.named_volumes[].name
named_volumes.description|.named_volumes[].description
wipe_parent_dirs|.wipe_parent_dirs[]
web_uis.name|.web_uis[].name
web_uis.url|.web_uis[].url
active_config.label|.active_config[].label
active_config.value|.active_config[].value
data_dirs_label|.data_dirs_label // ""
install_dirs_label|.install_dirs_label // ""
delete_install_dirs|.delete_install_dirs // "false"
delete_confirm_msg|.delete_confirm_msg // ""
no_data_msg|.no_data_msg // ""
no_delete_msg|.no_delete_msg // ""
useful_commands|.useful_commands // ""
'

# Routes one field's collected lines into the variable it belongs to. Called
# by _yaml_read_fields once per field, with the field name in $1 and the lines
# in the _YAML_FIELD_LINES array.
#
# The split between the two halves is exactly the array/scalar split: an array
# field takes one element per line, a scalar field takes the lines rejoined.
# Which fields get _yaml_expand applied, and which don't, is preserved
# verbatim from the 18 individual calls this replaces — descriptions, web UI
# names and active-config labels deliberately do NOT get expanded.
_load_info_field() {
    local i
    case "$1" in
        data_dirs.path)
            DATA_DIRS=()
            for i in "${!_YAML_FIELD_LINES[@]}"; do DATA_DIRS[i]="$(_yaml_expand "${_YAML_FIELD_LINES[$i]}")"; done ;;
        data_dirs.description)  DATA_DESCRIPTIONS=("${_YAML_FIELD_LINES[@]}") ;;
        install_dirs.path)
            INSTALL_DIRS=()
            for i in "${!_YAML_FIELD_LINES[@]}"; do INSTALL_DIRS[i]="$(_yaml_expand "${_YAML_FIELD_LINES[$i]}")"; done ;;
        install_dirs.description) INSTALL_DESCRIPTIONS=("${_YAML_FIELD_LINES[@]}") ;;
        named_volumes.name)
            NAMED_VOLUMES=()
            for i in "${!_YAML_FIELD_LINES[@]}"; do NAMED_VOLUMES[i]="$(_yaml_expand "${_YAML_FIELD_LINES[$i]}")"; done ;;
        named_volumes.description) NAMED_VOLUME_DESCRIPTIONS=("${_YAML_FIELD_LINES[@]}") ;;
        wipe_parent_dirs)
            WIPE_PARENT_DIRS=()
            for i in "${!_YAML_FIELD_LINES[@]}"; do WIPE_PARENT_DIRS[i]="$(_yaml_expand "${_YAML_FIELD_LINES[$i]}")"; done ;;
        web_uis.name)           WEB_UI_NAMES=("${_YAML_FIELD_LINES[@]}") ;;
        web_uis.url)
            WEB_UI_URLS=()
            for i in "${!_YAML_FIELD_LINES[@]}"; do WEB_UI_URLS[i]="$(_yaml_expand "${_YAML_FIELD_LINES[$i]}")"; done ;;
        active_config.label)    ACTIVE_CONFIG_LABELS=("${_YAML_FIELD_LINES[@]}") ;;
        active_config.value)
            ACTIVE_CONFIG_VALUES=()
            for i in "${!_YAML_FIELD_LINES[@]}"; do ACTIVE_CONFIG_VALUES[i]="$(_yaml_expand "${_YAML_FIELD_LINES[$i]}")"; done ;;

        data_dirs_label)        DATA_DIRS_LABEL="$(_yaml_expand "$(_yaml_field_scalar)")" ;;
        install_dirs_label)     INSTALL_DIRS_LABEL="$(_yaml_expand "$(_yaml_field_scalar)")" ;;
        delete_install_dirs)    DELETE_INSTALL_DIRS="$(_yaml_field_scalar)" ;;
        delete_confirm_msg)     DELETE_CONFIRM_MSG="$(_yaml_expand "$(_yaml_field_scalar)")" ;;
        no_data_msg)            NO_DATA_MSG="$(_yaml_expand "$(_yaml_field_scalar)")" ;;
        no_delete_msg)          NO_DELETE_MSG="$(_yaml_expand "$(_yaml_field_scalar)")" ;;
        useful_commands)        USEFUL_COMMANDS="$(_yaml_expand "$(_yaml_field_scalar)")" ;;
    esac
}

# Generic driver for environments with no info.sh logic beyond declaring
# data: loads info.yaml via _load_info_yaml above, then calls run_info.
run_info_yaml() {
    _load_info_yaml "$1" "$2" || return 1
    run_info
}

run_info() {
    if [ "$ACTION" = "list" ]; then
        # Measure the data dirs and volumes once, HERE, before either render
        # pass. Both passes below reach _info_dirs_and_volumes_text through a
        # subshell — _info_html captures it with command substitution, and
        # _info_list is the left side of a pipe into less — so a cache
        # populated lazily inside either one dies with that subshell and the
        # other pass pays full price again. Priming it in this shell is what
        # makes the second pass free.
        _info_cache_sizes

        # Regenerated on every "list" — post-deploy (run.sh already calls
        # this) and every time INFO is opened from the menu — so it's never
        # stale, without needing a separate action or menu entry.
        local html_file="${SCRIPT_DIR}/post-deploy-info.html"
        _INFO_PLAIN=1 _info_html "$html_file"

        # Pipe through less so long output (many data dirs/volumes/useful
        # commands) can be scrolled instead of flying past the terminal.
        # Falls back to plain output when there's no interactive terminal to
        # scroll in (e.g. a non-interactive `curl | bash` deploy) or `less`
        # isn't installed. No -F here (deliberately): -F exits less
        # immediately when content fits on one screen, which for short
        # output meant the screen was never actually shown before
        # returning to the menu. -X: don't clear the screen on exit, so the
        # info stays visible afterward. -r: pass through raw color escape
        # codes instead of showing them as literal control-character
        # garbage or stripping them.
        if [ -t 1 ] && command -v less &>/dev/null; then
            # _info_list's own stdout is the pipe into less, not this real
            # terminal — _INFO_FORCE_COLOR tells _color() (see its own
            # comment) that this `[ -t 1 ]` check right here, still in the
            # real terminal, already confirmed it's safe to color.
            _INFO_FORCE_COLOR=1 _info_list | less -Xr
        else
            _info_list
        fi
        echo "📄 HTML version with clickable links: $html_file"
    elif [ "$ACTION" = "delete" ]; then
        if [ "${#DATA_DIRS[@]}" -eq 0 ] && [ "${#NAMED_VOLUMES[@]}" -eq 0 ]; then
            echo ""
            echo "ℹ️  ${NO_DELETE_MSG:-No persistent data to delete.}"
            echo ""
        else
            _info_delete
        fi
    elif [ "$ACTION" = "manifest" ]; then
        # Machine-readable "DIR:<path>" / "VOL:<name>" lines for backup.sh —
        # deliberately not piped through less (that's for the human-facing
        # "list" action only).
        _info_manifest
    elif [ "$ACTION" = "list-dirs" ]; then
        # One absolute path per line, DATA_DIRS only — for deploy.sh's
        # generic docker-compose.yml/Dockerfile fallback path to pre-create
        # data directories (as the invoking user) before Docker ever
        # touches them as a bind-mount target. A plain subset of
        # _info_manifest's DIR: lines, without the VOL: ones or the "DIR:"
        # prefix, so the caller can mkdir -p each line directly.
        local i
        for i in "${!DATA_DIRS[@]}"; do
            echo "${DATA_DIRS[$i]}"
        done
    fi
}
