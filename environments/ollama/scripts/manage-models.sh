#!/usr/bin/env bash
#
# Interactive and command-line model management for the native Ollama host
# daemon. Kept separate from run.sh so deploy.sh can expose each operation as
# its own ACTION while direct callers can still use one script.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$ENV_DIR/../.." && pwd)"
CATALOG_FILE="${OLLAMA_MODEL_CATALOG:-$ENV_DIR/models.tsv}"
OLLAMA_CMD="${OLLAMA_CMD:-ollama}"
DIALOG_CMD="${DIALOG_CMD:-dialog}"

source "$REPO_DIR/lib/locale-lib.sh" || true

_require_ollama() {
    if ! command -v "$OLLAMA_CMD" >/dev/null 2>&1; then
        echo "❌ Ollama CLI not found. Run this environment's FAST setup first." >&2
        return 1
    fi
}

_require_dialog() {
    if ! command -v "$DIALOG_CMD" >/dev/null 2>&1; then
        echo "❌ dialog is required for interactive model selection." >&2
        return 1
    fi
}

_dialog_menu() {
    local title="$1"
    local prompt="$2"
    shift 2
    local output_file
    local status
    local choice
    output_file="$(mktemp)"
    # This helper is itself called inside command substitutions so its stdout
    # can return the selected tag. Redirecting dialog's stderr here would also
    # steal the terminal it uses to draw the UI (observed as an apparent hang
    # on macOS). Keep stderr attached to the caller's terminal and send only
    # dialog's result to fd 3.
    "$DIALOG_CMD" --clear --title " $title " \
        --output-fd 3 --menu "$prompt" 22 108 14 "$@" 3>"$output_file"
    status=$?
    choice="$(cat "$output_file")"
    rm -f "$output_file"
    [ "$status" -eq 0 ] && [ -n "$choice" ] || return 1
    printf '%s\n' "$choice"
}

_confirm() {
    local title="$1"
    local message="$2"
    if [ "${OLLAMA_MANAGER_ASSUME_YES:-false}" = "true" ]; then
        return 0
    fi
    _require_dialog || return 1
    "$DIALOG_CMD" --clear --title " $title " --yesno "$message" 22 92
}

_catalog_row() {
    local wanted="$1"
    awk -F '\t' -v wanted="$wanted" '
        $0 !~ /^#/ && $1 == wanted { print; exit }
    ' "$CATALOG_FILE"
}

_format_gib() {
    awk -v mib="$1" 'BEGIN { printf "%.1f GiB", mib / 1024 }'
}

_ram_values() {
    RAM_TOTAL_MIB="${OLLAMA_MANAGER_TOTAL_MIB:-}"
    RAM_AVAILABLE_MIB="${OLLAMA_MANAGER_AVAILABLE_MIB:-}"

    if [ -n "$RAM_TOTAL_MIB" ] && [ -n "$RAM_AVAILABLE_MIB" ]; then
        return 0
    fi

    case "$(uname -s)" in
        Darwin)
            RAM_TOTAL_MIB="$(sysctl -n hw.memsize 2>/dev/null | awk '{ printf "%.0f", $1 / 1048576 }')"
            local page_size
            page_size="$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)"
            RAM_AVAILABLE_MIB="$(vm_stat 2>/dev/null | awk -v page_size="$page_size" '
                /Pages free:|Pages inactive:|Pages speculative:|Pages purgeable:/ {
                    gsub(/\./, "", $3)
                    pages += $3
                }
                END {
                    if (pages > 0) printf "%.0f", pages * page_size / 1048576
                }
            ')"
            ;;
        Linux)
            if [ -r /proc/meminfo ]; then
                RAM_TOTAL_MIB="$(awk '/^MemTotal:/ { printf "%.0f", $2 / 1024 }' /proc/meminfo)"
                RAM_AVAILABLE_MIB="$(awk '/^MemAvailable:/ { printf "%.0f", $2 / 1024 }' /proc/meminfo)"
            fi
            ;;
    esac
}

_fit_status() {
    local ram_min="$1"
    local ram_max="$2"
    _ram_values
    if [ -z "${RAM_TOTAL_MIB:-}" ] || [ -z "${RAM_AVAILABLE_MIB:-}" ]; then
        printf '%s\n' "UNKNOWN — host RAM could not be measured"
    elif [ "$RAM_AVAILABLE_MIB" -ge "$ram_max" ]; then
        printf '%s\n' "FITS — available RAM meets the upper estimate"
    elif [ "$RAM_AVAILABLE_MIB" -ge "$ram_min" ]; then
        printf '%s\n' "CAUTION — it fits only near the low estimate; use a short context"
    else
        printf '%s\n' "EXCEEDS — available RAM is below the projected minimum"
    fi
}

show_resources() {
    _ram_values
    echo "🖥️  Host Resources"
    echo "   OS:        $(uname -s) $(uname -m)"
    if [ -n "${RAM_TOTAL_MIB:-}" ]; then
        echo "   RAM total: $(_format_gib "$RAM_TOTAL_MIB")"
    else
        echo "   RAM total: unavailable"
    fi
    if [ -n "${RAM_AVAILABLE_MIB:-}" ]; then
        echo "   Available: $(_format_gib "$RAM_AVAILABLE_MIB") (live estimate)"
    else
        echo "   Available: unavailable"
    fi
    echo "   CPU:       $(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo unknown) logical cores"
    echo ""
    echo "💽 Storage for Ollama models"
    if [ -d "$HOME/.ollama" ]; then
        df -h "$HOME/.ollama" | awk 'NR == 1 || NR == 2 { print "   " $0 }'
    else
        df -h "$HOME" | awk 'NR == 1 || NR == 2 { print "   " $0 }'
        echo "   (~/.ollama does not exist yet; models will normally be stored there.)"
    fi
    echo ""
    echo "🧠 Models currently loaded in RAM"
    if _require_ollama; then
        "$OLLAMA_CMD" ps || true
    fi
}

list_installed() {
    _require_ollama || return 1
    echo "📦 Installed Ollama Models"
    "$OLLAMA_CMD" list
}

list_running() {
    _require_ollama || return 1
    echo "🧠 Models Loaded in RAM"
    "$OLLAMA_CMD" ps
}

_installed_names() {
    "$OLLAMA_CMD" list 2>/dev/null | awk 'NR > 1 && NF { print $1 }'
}

_running_names() {
    "$OLLAMA_CMD" ps 2>/dev/null | awk 'NR > 1 && NF { print $1 }'
}

_select_from_command() {
    local title="$1"
    local prompt="$2"
    local source_kind="$3"
    local model
    local row
    local details
    local items=()

    if [ "$source_kind" = "running" ]; then
        while IFS= read -r model; do
            [ -n "$model" ] || continue
            items+=("$model" "Loaded in RAM")
        done < <(_running_names)
    else
        while IFS= read -r model; do
            [ -n "$model" ] || continue
            row="$(_catalog_row "$model")"
            if [ -n "$row" ]; then
                details="$(printf '%s' "$row" | awk -F '\t' '{ print $2 " — " $3 " download" }')"
            else
                details="Installed model"
            fi
            items+=("$model" "$details")
        done < <(_installed_names)
    fi

    if [ "${#items[@]}" -eq 0 ]; then
        echo "ℹ️  No $source_kind models found."
        return 1
    fi
    _require_dialog || return 1
    _dialog_menu "$title" "$prompt" "${items[@]}"
}

stop_model() {
    local model="${1:-}"
    _require_ollama || return 1
    if [ -z "$model" ]; then
        model="$(_select_from_command "Stop a Running Model" "Select a loaded model to unload from RAM:" "running")" || return 0
    fi
    _confirm "Stop Model" "Unload '$model' from RAM?\n\nThe model stays installed on disk and can be run again later." || return 0
    "$OLLAMA_CMD" stop "$model"
    echo "✅ Stopped $model"
}

delete_model() {
    local model="${1:-}"
    _require_ollama || return 1
    if [ -z "$model" ]; then
        model="$(_select_from_command "Delete an Installed Model" "Select a model to permanently remove from local storage:" "installed")" || return 0
    fi
    _confirm "Delete Model" "Permanently delete '$model' from local storage?\n\nYou will need to pull it again to use it later." || return 0
    "$OLLAMA_CMD" rm "$model"
    echo "✅ Deleted $model"
}

_catalog_menu_for_filter() {
    local filter_column="$1"
    local filter_value="$2"
    local title="$3"
    local prompt="$4"
    local model
    local display_name
    local disk_size
    local ram_min
    local ram_max
    local hardware
    local uses
    local notes
    local haystack
    local items=()

    while IFS=$'\t' read -r model display_name disk_size ram_min ram_max hardware uses notes; do
        [ -n "$model" ] || continue
        case "$model" in \#*) continue ;; esac
        if [ "$filter_column" = "hardware" ]; then
            haystack="$hardware"
        elif [ "$filter_column" = "uses" ]; then
            haystack="$uses"
        else
            haystack="$filter_value"
        fi
        case ",$haystack," in
            *",$filter_value,"*)
                items+=("$model" "$display_name | $disk_size download | $(_format_gib "$ram_min")–$(_format_gib "$ram_max") RAM | $notes")
                ;;
        esac
    done < "$CATALOG_FILE"

    if [ "${#items[@]}" -eq 0 ]; then
        echo "❌ No catalog entries matched '$filter_value'." >&2
        return 1
    fi
    _dialog_menu "$title" "$prompt" "${items[@]}"
}

_choose_pull_model() {
    local browse
    local category
    browse="$(_dialog_menu "Pull a Recommended Model" \
        "Browse the article-derived recommendations by hardware or suggested use:" \
        "hardware" "Hardware tier (RAM/device classification)" \
        "use" "Suggested use (wiki, general chat, coding, reasoning, etc.)" \
        "all" "All catalogued models")" || return 1

    case "$browse" in
        hardware)
            category="$(_dialog_menu "Choose Hardware Tier" \
                "Select the host class. RAM is checked live again before pull:" \
                "mac16" "Apple Silicon Mac — 16GB unified memory" \
                "mac8" "Apple Silicon Mac — 8GB unified memory" \
                "pi8" "Raspberry Pi 4/5 — 8GB RAM (CPU inference)" \
                "pi4" "Raspberry Pi 4/5 — 4GB RAM (small/stretch models only)")" || return 1
            _catalog_menu_for_filter "hardware" "$category" "Recommended for $category" \
                "Select a model. RAM ranges include weights, runtime overhead, and a modest context:"
            ;;
        use)
            category="$(_dialog_menu "Choose Suggested Use" \
                "Select how the supplied articles recommend using the model:" \
                "wiki" "Wiki Q&A / retrieval-augmented generation" \
                "embeddings" "Embeddings / Mnemon semantic recall" \
                "general" "General chat, writing, summaries, formatting" \
                "coding" "Code generation, reasoning, and fixes" \
                "reasoning" "Reasoning, mathematics, and logic" \
                "fast" "Fast/minimal resource use" \
                "multilingual" "Multilingual work" \
                "long-context" "Long-context document work")" || return 1
            _catalog_menu_for_filter "uses" "$category" "Models for $category" \
                "Select a model. RAM ranges include weights, runtime overhead, and a modest context:"
            ;;
        all)
            _catalog_menu_for_filter "all" "all" "All Recommended Models" \
                "Select a model. RAM ranges include weights, runtime overhead, and a modest context:"
            ;;
    esac
}

pull_model() {
    local model="${1:-}"
    local row
    local display_name
    local disk_size
    local ram_min
    local ram_max
    local hardware
    local uses
    local notes
    local fit
    local total_text="unavailable"
    local available_text="unavailable"

    _require_ollama || return 1
    if [ -z "$model" ]; then
        _require_dialog || return 1
        model="$(_choose_pull_model)" || return 0
    fi
    row="$(_catalog_row "$model")"
    if [ -z "$row" ]; then
        echo "❌ '$model' is not in $CATALOG_FILE." >&2
        return 1
    fi
    IFS=$'\t' read -r model display_name disk_size ram_min ram_max hardware uses notes <<< "$row"
    _ram_values
    [ -n "${RAM_TOTAL_MIB:-}" ] && total_text="$(_format_gib "$RAM_TOTAL_MIB")"
    [ -n "${RAM_AVAILABLE_MIB:-}" ] && available_text="$(_format_gib "$RAM_AVAILABLE_MIB")"
    fit="$(_fit_status "$ram_min" "$ram_max")"

    _confirm "Pull $display_name" \
"Model: $model
Use: $notes
Download: $disk_size
Projected working RAM: $(_format_gib "$ram_min")–$(_format_gib "$ram_max")

Host RAM total: $total_text
Host RAM available now: $available_text
Assessment: $fit

Pull this model? (Pulling downloads it but does not load it into RAM.)" || return 0

    "$OLLAMA_CMD" pull "$model"
    echo "✅ Pulled $model"
}

run_model() {
    local model="${1:-}"
    _require_ollama || return 1
    if [ -z "$model" ]; then
        model="$(_select_from_command "Run an Installed Model" "Select an installed model to start an interactive chat:" "installed")" || return 0
    fi
    if [ "$model" = "nomic-embed-text" ] || [ "$model" = "nomic-embed-text:latest" ]; then
        echo "❌ nomic-embed-text only creates embeddings; it cannot run an interactive chat." >&2
        return 1
    fi
    echo "🚀 Starting $model (use /exit or Ctrl+D to leave)..."
    "$OLLAMA_CMD" run "$model"
}

main_menu() {
    local action
    _require_dialog || return 1
    while true; do
        action="$(_dialog_menu "Ollama Model Manager" "Choose an action:" \
            "installed" "List models installed on disk" \
            "running" "List models currently loaded in RAM" \
            "resources" "Show host RAM, CPU, disk, and loaded models" \
            "stop" "Unload a running model from RAM" \
            "delete" "Delete an installed model from disk" \
            "pull" "Pull an article-recommended model" \
            "run" "Run an installed chat model")" || return 0
        case "$action" in
            installed) list_installed ;;
            running) list_running ;;
            resources) show_resources ;;
            stop) stop_model ;;
            delete) delete_model ;;
            pull) pull_model ;;
            run) run_model ;;
        esac
        echo ""
        read -rp "Press Enter to return to the Ollama model menu..."
    done
}

case "${1:-}" in
    --list-installed) list_installed ;;
    --list-running) list_running ;;
    --resources) show_resources ;;
    --stop) stop_model "${2:-}" ;;
    --delete) delete_model "${2:-}" ;;
    --pull) pull_model "${2:-}" ;;
    --run) run_model "${2:-}" ;;
    --help)
        echo "Usage: $0 [--list-installed|--list-running|--resources|--stop [MODEL]|--delete [MODEL]|--pull [MODEL]|--run [MODEL]]"
        ;;
    "") main_menu ;;
    *)
        echo "❌ Unknown option: $1" >&2
        exit 2
        ;;
esac
