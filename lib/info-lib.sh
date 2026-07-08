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

# Renders the same content as _info_list (data dirs, install dirs, volumes,
# useful commands) as a self-contained HTML page. Web UIs get their own
# table (clickable, not squeezed into the preformatted block); everything
# else stays in a <pre> block with bare URLs still turned into links, so
# it's still useful for environments with no WEB_UI_NAMES at all.
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
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
         max-width: 850px; margin: 2rem auto; padding: 0 1.25rem;
         background: #0d1117; color: #c9d1d9; }
  h1 { font-size: 1.35rem; border-bottom: 1px solid #30363d; padding-bottom: 0.6rem; }
  h2 { font-size: 1.05rem; margin-top: 1.75rem; }
  table { border-collapse: collapse; width: 100%; background: #161b22; border-radius: 8px; overflow: hidden; }
  th, td { text-align: left; padding: 0.55rem 0.9rem; border-bottom: 1px solid #21262d; }
  th { color: #8b949e; font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.03em; }
  tr:last-child td { border-bottom: none; }
  /* Preformatted terminal-style text keeps its original alignment (no
     wrapping); a horizontal scrollbar handles any line too long for the
     viewport instead of the browser reflowing (and thereby mangling) the
     hand-padded columns in the source text. */
  pre { white-space: pre; overflow-x: auto; background: #161b22;
        padding: 1rem 1.25rem; border-radius: 8px; line-height: 1.55;
        font-size: 0.92rem; }
  a { color: #58a6ff; text-decoration: none; }
  a:hover { text-decoration: underline; }
  footer { color: #6e7681; font-size: 0.8rem; margin-top: 1.5rem; }
</style>
</head>
<body>
<h1>${title}</h1>
HTML
        if [ -n "${WEB_UI_NAMES+x}" ] && [ "${#WEB_UI_NAMES[@]}" -gt 0 ]; then
            cat <<HTML
<h2>🌐 Web UIs</h2>
<table>
<tbody>
HTML
            local i esc_name esc_url
            for i in "${!WEB_UI_NAMES[@]}"; do
                esc_name=$(printf '%s' "${WEB_UI_NAMES[$i]}" | _html_escape)
                esc_url=$(printf '%s' "${WEB_UI_URLS[$i]}" | _html_escape)
                printf '<tr><td>%s</td><td><a href="%s" target="_blank" rel="noopener">%s</a></td></tr>\n' \
                    "$esc_name" "$esc_url" "$esc_url"
            done
            cat <<HTML
</tbody>
</table>
HTML
        fi
        cat <<HTML
<pre>
HTML
        { _info_dirs_and_volumes_text; _info_useful_commands_text; } | _html_escape | _linkify
        cat <<HTML
</pre>
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
    fi
}
