#!/usr/bin/env bash
# Shared list/delete logic for all environment info.sh scripts.
#
# The calling info.sh must set before sourcing this file:
#   SCRIPT_DIR   — absolute path to the environment directory
#   ACTION       — "list", "delete", or "manifest" (the last is used by the
#                  repo root's backup.sh — see run_info()'s manifest branch)
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
#
# Optional scalars (library provides defaults):
#   DATA_DIRS_LABEL      — heading for the data dirs section
#   INSTALL_DIRS_LABEL   — heading for the install dirs section
#   NO_DATA_MSG          — shown in list when DATA_DIRS is empty
#   NO_DELETE_MSG        — shown in delete when there is nothing to remove
#   DELETE_CONFIRM_MSG   — text shown in the deletion confirmation prompt
#   DELETE_INSTALL_DIRS  — "true" to include INSTALL_DIRS in the wipe (default: false)
#   USEFUL_COMMANDS      — multiline string of commands to display (bash-interpolated in info.sh)

_info_list() {
    echo ""

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

    echo "💡 Useful Commands:"
    echo "$USEFUL_COMMANDS"
    echo ""
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
