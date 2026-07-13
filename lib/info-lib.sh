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

# The data-dirs/install-dirs/volumes portion — factored out so _info_html
# can reuse it in the <pre> block without also pulling in the web UIs
# section, which it renders as a separate HTML table instead.
_info_dirs_and_volumes_text() {
    if [ "${#DATA_DIRS[@]}" -gt 0 ]; then
        echo "${DATA_DIRS_LABEL:-📁 Persistent Data Directories:}"
        local i
        for i in "${!DATA_DIRS[@]}"; do
            local dir="${DATA_DIRS[$i]}"
            if [ -d "$dir" ]; then
                local size; size=$(du -sh "$dir" 2>/dev/null | cut -f1)
                echo "   $dir  ($size)"
            else
                echo "   $dir  (not yet created)"
            fi
            echo "     → ${DATA_DESCRIPTIONS[$i]}"
        done
        echo ""
    fi

    if [ "${#INSTALL_DIRS[@]}" -gt 0 ]; then
        echo "${INSTALL_DIRS_LABEL:-📂 Install Directories:}"
        local i
        for i in "${!INSTALL_DIRS[@]}"; do
            local dir="${INSTALL_DIRS[$i]}"
            if [ -d "$dir" ]; then
                local size; size=$(du -sh "$dir" 2>/dev/null | cut -f1)
                echo "   $dir  ($size)"
            else
                echo "   $dir  (not yet created)"
            fi
            echo "     → ${INSTALL_DESCRIPTIONS[$i]}"
        done
        echo ""
    fi

    if [ "${#NAMED_VOLUMES[@]}" -gt 0 ]; then
        echo "🐳 Named Docker Volumes (managed by Docker):"
        local i
        for i in "${!NAMED_VOLUMES[@]}"; do
            local vol="${NAMED_VOLUMES[$i]}"
            local SIZE EXISTS
            SIZE=$(docker volume inspect "$vol" --format '{{.Mountpoint}}' 2>/dev/null \
                | xargs -I{} du -sh {} 2>/dev/null | cut -f1 || echo "unknown")
            EXISTS=$(docker volume ls -q --filter name="^${vol}$" 2>/dev/null)
            if [ -n "$EXISTS" ]; then
                echo "   docker volume: $vol  ($SIZE)"
            else
                echo "   docker volume: $vol  (not yet created)"
            fi
            echo "     → ${NAMED_VOLUME_DESCRIPTIONS[$i]}"
        done
        echo ""
    fi

    if [ "${#DATA_DIRS[@]}" -eq 0 ] && [ "${#INSTALL_DIRS[@]}" -eq 0 ] && [ "${#NAMED_VOLUMES[@]}" -eq 0 ]; then
        echo "📁 Persistent Data Directories:"
        echo "   ${NO_DATA_MSG:-(none)}"
        echo ""
    fi
}

# Plain-text web UI list for the terminal — right-pads each URL to the
# longest one so the names line up in a column, the same way a manually
# hand-padded line would, just computed instead of guessed.
_info_web_uis_text() {
    if [ -n "${WEB_UI_NAMES+x}" ] && [ "${#WEB_UI_NAMES[@]}" -gt 0 ]; then
        echo "🌐 Web UIs:"
        local i maxlen=0
        for i in "${!WEB_UI_URLS[@]}"; do
            [ "${#WEB_UI_URLS[$i]}" -gt "$maxlen" ] && maxlen="${#WEB_UI_URLS[$i]}"
        done
        for i in "${!WEB_UI_NAMES[@]}"; do
            printf '   %-*s   %s\n' "$maxlen" "${WEB_UI_URLS[$i]}" "${WEB_UI_NAMES[$i]}"
        done
        echo ""
    fi
}

_info_useful_commands_text() {
    echo "💡 Useful Commands:"
    echo "$USEFUL_COMMANDS"
    echo ""
}

_info_list() {
    echo ""
    _info_dirs_and_volumes_text
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

_info_delete() {
    echo ""
    echo "⚠️  The following will be PERMANENTLY DELETED:"
    echo ""
    local DIRS_EXIST=false i

    for i in "${!DATA_DIRS[@]}"; do
        local dir="${DATA_DIRS[$i]}"
        if [ -d "$dir" ]; then
            local size; size=$(du -sh "$dir" 2>/dev/null | cut -f1)
            echo "   🗑️  $dir  ($size)"
            echo "       → ${DATA_DESCRIPTIONS[$i]}"
            DIRS_EXIST=true
        else
            echo "   ⬜  $dir  (does not exist)"
        fi
    done

    if [ "${DELETE_INSTALL_DIRS:-false}" = "true" ] && [ "${#INSTALL_DIRS[@]}" -gt 0 ]; then
        for i in "${!INSTALL_DIRS[@]}"; do
            local dir="${INSTALL_DIRS[$i]}"
            if [ -d "$dir" ]; then
                local size; size=$(du -sh "$dir" 2>/dev/null | cut -f1)
                echo "   🗑️  $dir  ($size)"
                echo "       → ${INSTALL_DESCRIPTIONS[$i]}"
                DIRS_EXIST=true
            else
                echo "   ⬜  $dir  (does not exist)"
            fi
        done
    fi

    if [ "${#NAMED_VOLUMES[@]}" -gt 0 ]; then
        echo ""
        echo "   Named Docker volumes will also be removed:"
        local vol
        for vol in "${NAMED_VOLUMES[@]}"; do
            local EXISTS; EXISTS=$(docker volume ls -q --filter name="^${vol}$" 2>/dev/null)
            if [ -n "$EXISTS" ]; then
                echo "   🗑️  docker volume: $vol"
                DIRS_EXIST=true
            else
                echo "   ⬜  docker volume: $vol  (does not exist)"
            fi
        done
    fi

    if [ -n "${WIPE_PARENT_DIRS+x}" ] && [ "${#WIPE_PARENT_DIRS[@]}" -gt 0 ]; then
        for dir in "${WIPE_PARENT_DIRS[@]}"; do
            if [ -d "$dir" ]; then
                local size; size=$(du -sh "$dir" 2>/dev/null | cut -f1)
                echo "   🗑️  $dir  ($size)  (including any remaining contents)"
                DIRS_EXIST=true
            else
                echo "   ⬜  $dir  (does not exist)"
            fi
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
        local dir
        for dir in "${DATA_DIRS[@]}"; do
            [ -d "$dir" ] && rm -rf "$dir" && echo "🗑️  Deleted: $dir"
        done
        if [ "${DELETE_INSTALL_DIRS:-false}" = "true" ] && [ "${#INSTALL_DIRS[@]}" -gt 0 ]; then
            for dir in "${INSTALL_DIRS[@]}"; do
                [ -d "$dir" ] && rm -rf "$dir" && echo "🗑️  Deleted: $dir"
            done
        fi
        if [ "${#NAMED_VOLUMES[@]}" -gt 0 ]; then
            local vol
            for vol in "${NAMED_VOLUMES[@]}"; do
                local EXISTS; EXISTS=$(docker volume ls -q --filter name="^${vol}$" 2>/dev/null)
                [ -n "$EXISTS" ] && docker volume rm "$vol" && echo "🗑️  Deleted volume: $vol"
            done
        fi
        if [ -n "${WIPE_PARENT_DIRS+x}" ] && [ "${#WIPE_PARENT_DIRS[@]}" -gt 0 ]; then
            for dir in "${WIPE_PARENT_DIRS[@]}"; do
                [ -d "$dir" ] && rm -rf "$dir" && echo "🗑️  Deleted: $dir"
            done
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

    local i _raw

    _read_lines < <(_yq '.data_dirs[].path' "$yaml"); _raw=("${_LINES[@]}")
    DATA_DIRS=()
    for i in "${!_raw[@]}"; do DATA_DIRS[i]="$(_yaml_expand "${_raw[$i]}")"; done
    _read_lines < <(_yq '.data_dirs[].description' "$yaml"); DATA_DESCRIPTIONS=("${_LINES[@]}")

    _read_lines < <(_yq '.install_dirs[].path' "$yaml"); _raw=("${_LINES[@]}")
    INSTALL_DIRS=()
    for i in "${!_raw[@]}"; do INSTALL_DIRS[i]="$(_yaml_expand "${_raw[$i]}")"; done
    _read_lines < <(_yq '.install_dirs[].description' "$yaml"); INSTALL_DESCRIPTIONS=("${_LINES[@]}")

    _read_lines < <(_yq '.named_volumes[].name' "$yaml"); NAMED_VOLUMES=("${_LINES[@]}")
    _read_lines < <(_yq '.named_volumes[].description' "$yaml"); NAMED_VOLUME_DESCRIPTIONS=("${_LINES[@]}")

    _read_lines < <(_yq '.wipe_parent_dirs[]' "$yaml"); _raw=("${_LINES[@]}")
    WIPE_PARENT_DIRS=()
    for i in "${!_raw[@]}"; do WIPE_PARENT_DIRS[i]="$(_yaml_expand "${_raw[$i]}")"; done

    _read_lines < <(_yq '.web_uis[].name' "$yaml"); WEB_UI_NAMES=("${_LINES[@]}")
    _read_lines < <(_yq '.web_uis[].url' "$yaml"); _raw=("${_LINES[@]}")
    WEB_UI_URLS=()
    for i in "${!_raw[@]}"; do WEB_UI_URLS[i]="$(_yaml_expand "${_raw[$i]}")"; done

    DATA_DIRS_LABEL="$(_yaml_expand "$(_yq '.data_dirs_label // ""' "$yaml")")"
    INSTALL_DIRS_LABEL="$(_yaml_expand "$(_yq '.install_dirs_label // ""' "$yaml")")"
    DELETE_INSTALL_DIRS="$(_yq '.delete_install_dirs // "false"' "$yaml")"
    DELETE_CONFIRM_MSG="$(_yaml_expand "$(_yq '.delete_confirm_msg // ""' "$yaml")")"
    NO_DATA_MSG="$(_yaml_expand "$(_yq '.no_data_msg // ""' "$yaml")")"
    NO_DELETE_MSG="$(_yaml_expand "$(_yq '.no_delete_msg // ""' "$yaml")")"

    USEFUL_COMMANDS="$(_yaml_expand "$(_yq '.useful_commands // ""' "$yaml")")"
}

# Generic driver for environments with no info.sh logic beyond declaring
# data: loads info.yaml via _load_info_yaml above, then calls run_info.
run_info_yaml() {
    _load_info_yaml "$1" "$2" || return 1
    run_info
}

run_info() {
    if [ "$ACTION" = "list" ]; then
        # Regenerated on every "list" — post-deploy (run.sh already calls
        # this) and every time INFO is opened from the menu — so it's never
        # stale, without needing a separate action or menu entry.
        local html_file="${SCRIPT_DIR}/post-deploy-info.html"
        _info_html "$html_file"

        # Pipe through less so long output (many data dirs/volumes/useful
        # commands) can be scrolled instead of flying past the terminal.
        # Falls back to plain output when there's no interactive terminal to
        # scroll in (e.g. a non-interactive `curl | bash` deploy) or `less`
        # isn't installed. -F: exit immediately if content fits on one
        # screen (behaves like plain output for short lists). -X: don't
        # clear the screen on exit, so the info stays visible afterward.
        if [ -t 1 ] && command -v less &>/dev/null; then
            _info_list | less -FX
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
