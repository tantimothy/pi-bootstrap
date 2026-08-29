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
TTY_INPUT="${OLLAMA_MANAGER_TTY_INPUT:-/dev/tty}"
TTY_OUTPUT="${OLLAMA_MANAGER_TTY_OUTPUT:-/dev/tty}"

source "$REPO_DIR/lib/locale-lib.sh" || true

# Menu helpers return choices through these globals. In particular, never run
# dialog inside $(...) — command substitution gives it a pipe instead of the
# real terminal on macOS, which makes the screen appear frozen until Enter.
DIALOG_CHOICE=""
SELECTED_MODEL=""
NORMALIZED_MODEL=""
MENU_BACK_STATUS=2

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

_dialog_menu_impl() {
    local item_help="$1"
    shift
    local title="$1"
    local prompt="$2"
    shift 2
    local output_file
    local status
    local choice
    local options=(--clear)
    [ "$item_help" = "true" ] && options+=(--item-help)
    output_file="$(mktemp)"
    # Keep stderr attached to the caller's terminal so dialog can draw its UI.
    # Only the selected tag goes to fd 3; the function returns it through the
    # DIALOG_CHOICE global, never through a command substitution.
    "$DIALOG_CMD" "${options[@]}" --title " $title " \
        --cancel-label "Back" \
        --output-fd 3 --menu "$prompt" 22 108 14 "$@" \
        3>"$output_file" <"$TTY_INPUT" 2>>"$TTY_OUTPUT"
    status=$?
    choice="$(cat "$output_file")"
    rm -f "$output_file"
    case "$status" in
        1|255) return "$MENU_BACK_STATUS" ;;
        0) ;;
        *) return "$status" ;;
    esac
    [ -n "$choice" ] || return 1
    DIALOG_CHOICE="$choice"
}

_dialog_menu() {
    _dialog_menu_impl false "$@"
}

_dialog_menu_with_help() {
    _dialog_menu_impl true "$@"
}

_confirm() {
    local title="$1"
    local message="$2"
    if [ "${OLLAMA_MANAGER_ASSUME_YES:-false}" = "true" ]; then
        return 0
    fi
    _require_dialog || return 1
    "$DIALOG_CMD" --clear --title " $title " --no-label "Back" \
        --yesno "$message" 22 92 <"$TTY_INPUT" 2>>"$TTY_OUTPUT"
    local status=$?
    case "$status" in
        1|255) return "$MENU_BACK_STATUS" ;;
        *) return "$status" ;;
    esac
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

_memory_pressure_values() {
    MEMORY_PRESSURE_STATUS="${OLLAMA_MANAGER_PRESSURE_STATUS:-}"
    MEMORY_PRESSURE_DETAIL="${OLLAMA_MANAGER_PRESSURE_DETAIL:-}"
    [ -n "$MEMORY_PRESSURE_STATUS" ] && return 0

    local free_percent
    local some_avg10
    local full_avg10
    local psi_file="${OLLAMA_MANAGER_PSI_FILE:-/proc/pressure/memory}"
    case "$(uname -s)" in
        Darwin)
            if command -v memory_pressure >/dev/null 2>&1; then
                # memory_pressure -Q accounts for macOS reclaimable/compressed
                # capacity. These are conservative planning bands, not claims
                # to reproduce Activity Monitor's private color thresholds.
                free_percent="$(memory_pressure -Q 2>/dev/null |
                    awk -F ': ' '/System-wide memory free percentage:/ {
                        gsub(/%/, "", $2)
                        print $2
                        exit
                    }')"
                if [[ "$free_percent" =~ ^[0-9]+$ ]]; then
                    if [ "$free_percent" -ge 20 ]; then
                        MEMORY_PRESSURE_STATUS="low"
                    elif [ "$free_percent" -ge 10 ]; then
                        MEMORY_PRESSURE_STATUS="moderate"
                    else
                        MEMORY_PRESSURE_STATUS="high"
                    fi
                    MEMORY_PRESSURE_DETAIL="macOS reports ${free_percent}% free memory capacity"
                fi
            fi
            ;;
        Linux)
            if [ -r "$psi_file" ]; then
                some_avg10="$(awk '
                    /^some / {
                        for (i = 1; i <= NF; i++) {
                            if ($i ~ /^avg10=/) {
                                sub(/^avg10=/, "", $i)
                                print $i
                                exit
                            }
                        }
                    }
                ' "$psi_file")"
                full_avg10="$(awk '
                    /^full / {
                        for (i = 1; i <= NF; i++) {
                            if ($i ~ /^avg10=/) {
                                sub(/^avg10=/, "", $i)
                                print $i
                                exit
                            }
                        }
                    }
                ' "$psi_file")"
                if [ -n "$some_avg10" ] && [ -n "$full_avg10" ]; then
                    # PSI measures recent task stalls. Treat sustained full
                    # stalls or double-digit partial stalls as high pressure.
                    if awk -v some="$some_avg10" -v full="$full_avg10" \
                        'BEGIN { exit ! (full >= 1.0 || some >= 10.0) }'; then
                        MEMORY_PRESSURE_STATUS="high"
                    elif awk -v some="$some_avg10" -v full="$full_avg10" \
                        'BEGIN { exit ! (full > 0.0 || some >= 1.0) }'; then
                        MEMORY_PRESSURE_STATUS="moderate"
                    else
                        MEMORY_PRESSURE_STATUS="low"
                    fi
                    MEMORY_PRESSURE_DETAIL="Linux PSI avg10: some=${some_avg10}%, full=${full_avg10}%"
                fi
            fi
            ;;
    esac

    if [ -z "$MEMORY_PRESSURE_STATUS" ]; then
        MEMORY_PRESSURE_STATUS="unknown"
        MEMORY_PRESSURE_DETAIL="pressure signal unavailable"
    fi
}

_pressure_summary() {
    _memory_pressure_values
    case "$MEMORY_PRESSURE_STATUS" in
        low) printf 'LOW — %s\n' "$MEMORY_PRESSURE_DETAIL" ;;
        moderate) printf 'MODERATE — %s\n' "$MEMORY_PRESSURE_DETAIL" ;;
        high) printf 'HIGH — %s\n' "$MEMORY_PRESSURE_DETAIL" ;;
        *) printf 'UNKNOWN — %s\n' "$MEMORY_PRESSURE_DETAIL" ;;
    esac
}

_fit_status() {
    local ram_min="$1"
    local ram_max="$2"
    _ram_values
    _memory_pressure_values
    if [ -z "${RAM_TOTAL_MIB:-}" ] || [ -z "${RAM_AVAILABLE_MIB:-}" ]; then
        printf '%s\n' "UNKNOWN — host RAM could not be measured"
    elif [ "$RAM_TOTAL_MIB" -lt "$ram_min" ]; then
        printf '%s\n' "EXCEEDS — projected minimum is larger than physical RAM"
    elif [ "$RAM_AVAILABLE_MIB" -lt "$ram_min" ] && [ "$MEMORY_PRESSURE_STATUS" = "low" ]; then
        printf '%s\n' "CAUTION — available RAM is low, but low pressure indicates reclaimable/compressible capacity"
    elif [ "$RAM_AVAILABLE_MIB" -lt "$ram_min" ]; then
        printf '%s\n' "EXCEEDS — available RAM is below the projected minimum and pressure is not low"
    elif [ "$MEMORY_PRESSURE_STATUS" = "high" ]; then
        printf '%s\n' "CAUTION — memory pressure is already high; stop other workloads first"
    elif [ "$RAM_AVAILABLE_MIB" -ge "$ram_max" ]; then
        if [ "$MEMORY_PRESSURE_STATUS" = "moderate" ]; then
            printf '%s\n' "CAUTION — capacity fits, but memory pressure is already moderate"
        elif [ "$MEMORY_PRESSURE_STATUS" = "low" ]; then
            printf '%s\n' "FITS — available RAM meets the upper estimate and pressure is low"
        else
            printf '%s\n' "FITS — available RAM meets the upper estimate; pressure is unavailable"
        fi
    elif [ "$RAM_AVAILABLE_MIB" -ge "$ram_min" ]; then
        printf '%s\n' "CAUTION — it fits only near the low estimate; use a short context"
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
    echo "   Pressure:  $(_pressure_summary)"
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

# dialog/terminal combinations can leave a carriage return, control byte, or
# optional pair of quotes around the selected tag. They are invisible in a
# normal echo but make Ollama reject an otherwise-valid name. Normalize only
# transport artifacts; punctuation used by real model names stays untouched.
_normalize_model_name() {
    NORMALIZED_MODEL="$(printf '%s' "$1" |
        LC_ALL=C tr -d '\000-\037\177' |
        sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "$NORMALIZED_MODEL" in
        \"*\")
            NORMALIZED_MODEL="${NORMALIZED_MODEL#\"}"
            NORMALIZED_MODEL="${NORMALIZED_MODEL%\"}"
            ;;
        \'*\')
            NORMALIZED_MODEL="${NORMALIZED_MODEL#\'}"
            NORMALIZED_MODEL="${NORMALIZED_MODEL%\'}"
            ;;
    esac
}

_installed_model_exists() {
    local wanted="$1"
    local candidate
    while IFS= read -r candidate; do
        _normalize_model_name "$candidate"
        [ "$NORMALIZED_MODEL" = "$wanted" ] && return 0
    done < <(_installed_names)
    return 1
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
                details="$(printf '%s' "$row" | awk -F '\t' '{ print $8 " | " $3 " d/l" }')"
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
    local status=$?
    [ "$status" -eq 0 ] || return "$status"
    _normalize_model_name "$DIALOG_CHOICE"
    SELECTED_MODEL="$NORMALIZED_MODEL"
}

stop_model() {
    local model="${1:-}"
    local status
    local interactive=false
    _require_ollama || return 1
    if [ -z "$model" ]; then
        interactive=true
    else
        _normalize_model_name "$model"
        model="$NORMALIZED_MODEL"
    fi
    while true; do
        if [ "$interactive" = "true" ]; then
            _select_from_command "Stop a Running Model" "Select a loaded model to unload from RAM:" "running"
            status=$?
            [ "$status" -eq 0 ] || return "$status"
            model="$SELECTED_MODEL"
        fi
        _confirm "Stop Model" "Unload '$model' from RAM?\n\nThe model stays installed on disk and can be run again later."
        status=$?
        if [ "$status" -eq "$MENU_BACK_STATUS" ]; then
            [ "$interactive" = "true" ] && continue
            return 0
        fi
        [ "$status" -eq 0 ] || return "$status"
        "$OLLAMA_CMD" stop "$model"
        echo "✅ Stopped $model"
        return 0
    done
}

delete_model() {
    local model="${1:-}"
    local status
    local interactive=false
    _require_ollama || return 1
    if [ -z "$model" ]; then
        interactive=true
    else
        _normalize_model_name "$model"
        model="$NORMALIZED_MODEL"
    fi
    while true; do
        if [ "$interactive" = "true" ]; then
            _select_from_command "Delete an Installed Model" "Select a model to permanently remove from local storage:" "installed"
            status=$?
            [ "$status" -eq 0 ] || return "$status"
            model="$SELECTED_MODEL"
        fi
        _confirm "Delete Model" "Permanently delete '$model' from local storage?\n\nYou will need to pull it again to use it later."
        status=$?
        if [ "$status" -eq "$MENU_BACK_STATUS" ]; then
            [ "$interactive" = "true" ] && continue
            return 0
        fi
        [ "$status" -eq 0 ] || return "$status"
        "$OLLAMA_CMD" rm "$model"
        echo "✅ Deleted $model"
        return 0
    done
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
    local fit
    local fit_label
    local priority
    local summary
    local use_summary
    local sorted_rows=()
    local items=()

    _ram_values
    _memory_pressure_values
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
                fit="$(_fit_status "$ram_min" "$ram_max")"
                fit_label="${fit%% *}"
                case "$fit_label" in
                    FITS) priority=1 ;;
                    CAUTION) priority=2 ;;
                    EXCEEDS) priority=3 ;;
                    *) priority=4 ;;
                esac
                use_summary="${uses//,/ · }"
                summary="[$fit_label] $use_summary | RAM $(_format_gib "$ram_min")–$(_format_gib "$ram_max")"
                sorted_rows+=("$priority"$'\t'"$ram_min"$'\t'"$model"$'\t'"$summary"$'\t'"$notes")
                ;;
        esac
    done < "$CATALOG_FILE"

    if [ "${#sorted_rows[@]}" -eq 0 ]; then
        echo "❌ No catalog entries matched '$filter_value'." >&2
        return 1
    fi

    while IFS=$'\t' read -r priority ram_min model summary notes; do
        items+=("$model" "$summary" "$notes")
    done < <(printf '%s\n' "${sorted_rows[@]}" |
        LC_ALL=C sort -t $'\t' -k1,1n -k2,2n -k3,3)

    _require_dialog || return 1
    _dialog_menu_with_help "$title" \
        "$prompt Highlight a model to see its description below; full model and host details appear after selection." \
        "${items[@]}"
    local status=$?
    [ "$status" -eq 0 ] || return "$status"
    _normalize_model_name "$DIALOG_CHOICE"
    SELECTED_MODEL="$NORMALIZED_MODEL"
}

_pull_selected_model() {
    local model="$1"
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
    local pressure_text
    local status

    row="$(_catalog_row "$model")"
    if [ -z "$row" ]; then
        echo "❌ '$model' is not in $CATALOG_FILE." >&2
        return 1
    fi
    IFS=$'\t' read -r model display_name disk_size ram_min ram_max hardware uses notes <<< "$row"
    _ram_values
    [ -n "${RAM_TOTAL_MIB:-}" ] && total_text="$(_format_gib "$RAM_TOTAL_MIB")"
    [ -n "${RAM_AVAILABLE_MIB:-}" ] && available_text="$(_format_gib "$RAM_AVAILABLE_MIB")"
    pressure_text="$(_pressure_summary)"
    fit="$(_fit_status "$ram_min" "$ram_max")"

    _confirm "Pull $display_name" \
"Model: $model
Use: $notes
Download: $disk_size
Projected working RAM: $(_format_gib "$ram_min")–$(_format_gib "$ram_max")

Host RAM total: $total_text
Host RAM available now: $available_text
Host memory pressure: $pressure_text
Assessment: $fit

Pull this model? (Pulling downloads it but does not load it into RAM.)"
    status=$?
    [ "$status" -eq 0 ] || return "$status"

    "$OLLAMA_CMD" pull "$model"
    echo "✅ Pulled $model"
}

_choose_and_pull_model() {
    local browse
    local category
    local status

    while true; do
        _dialog_menu "Pull a Recommended Model" \
            "Browse the article-derived recommendations by hardware or suggested use:" \
            "hardware" "Hardware tier (RAM/device classification)" \
            "use" "Suggested use (wiki, general chat, coding, reasoning, etc.)" \
            "all" "All catalogued models"
        status=$?
        [ "$status" -eq 0 ] || return "$status"
        browse="$DIALOG_CHOICE"

        case "$browse" in
            hardware)
                while true; do
                    _dialog_menu "Choose Hardware Tier" \
                        "Select the host class. RAM is checked live again before pull:" \
                        "mac32" "Apple Silicon Mac — 32GB+ (all catalog models; scroll for more)" \
                        "mac16" "Apple Silicon Mac — 16GB unified memory" \
                        "mac8" "Apple Silicon Mac — 8GB unified memory" \
                        "pi8" "Raspberry Pi 4/5 — 8GB RAM (CPU inference)" \
                        "pi4" "Raspberry Pi 4/5 — 4GB RAM (small/stretch models only)"
                    status=$?
                    [ "$status" -eq "$MENU_BACK_STATUS" ] && break
                    [ "$status" -eq 0 ] || return "$status"
                    category="$DIALOG_CHOICE"
                    while true; do
                        _catalog_menu_for_filter "hardware" "$category" "Recommended for $category" \
                            "Select a model. RAM ranges include weights, runtime overhead, and a modest context:"
                        status=$?
                        [ "$status" -eq "$MENU_BACK_STATUS" ] && break
                        [ "$status" -eq 0 ] || return "$status"
                        _pull_selected_model "$SELECTED_MODEL"
                        status=$?
                        [ "$status" -eq "$MENU_BACK_STATUS" ] && continue
                        return "$status"
                    done
                done
                ;;
            use)
                while true; do
                    _dialog_menu "Choose Suggested Use" \
                        "Select how the supplied articles recommend using the model:" \
                        "wiki" "Wiki Q&A / retrieval-augmented generation" \
                        "embeddings" "Embeddings / Mnemon semantic recall" \
                        "general" "General chat, writing, summaries, formatting" \
                        "coding" "Code generation, reasoning, and fixes" \
                        "reasoning" "Reasoning, mathematics, and logic" \
                        "fast" "Fast/minimal resource use" \
                        "multilingual" "Multilingual work" \
                        "long-context" "Long-context document work" \
                        "vision" "Image input — screenshots, photos, scanned pages"
                    status=$?
                    [ "$status" -eq "$MENU_BACK_STATUS" ] && break
                    [ "$status" -eq 0 ] || return "$status"
                    category="$DIALOG_CHOICE"
                    while true; do
                        _catalog_menu_for_filter "uses" "$category" "Models for $category" \
                            "Select a model. RAM ranges include weights, runtime overhead, and a modest context:"
                        status=$?
                        [ "$status" -eq "$MENU_BACK_STATUS" ] && break
                        [ "$status" -eq 0 ] || return "$status"
                        _pull_selected_model "$SELECTED_MODEL"
                        status=$?
                        [ "$status" -eq "$MENU_BACK_STATUS" ] && continue
                        return "$status"
                    done
                done
                ;;
            all)
                while true; do
                    _catalog_menu_for_filter "all" "all" "All Recommended Models" \
                        "Select a model. RAM ranges include weights, runtime overhead, and a modest context:"
                    status=$?
                    [ "$status" -eq "$MENU_BACK_STATUS" ] && break
                    [ "$status" -eq 0 ] || return "$status"
                    _pull_selected_model "$SELECTED_MODEL"
                    status=$?
                    [ "$status" -eq "$MENU_BACK_STATUS" ] && continue
                    return "$status"
                done
                ;;
        esac
    done
}

pull_model() {
    local model="${1:-}"
    local status

    _require_ollama || return 1
    if [ -z "$model" ]; then
        _require_dialog || return 1
        _choose_and_pull_model
        return $?
    else
        _normalize_model_name "$model"
        model="$NORMALIZED_MODEL"
    fi
    _pull_selected_model "$model"
    status=$?
    [ "$status" -eq "$MENU_BACK_STATUS" ] && return 0
    return "$status"
}

run_model() {
    local model="${1:-}"
    local selected_interactively=false
    _require_ollama || return 1
    if [ -z "$model" ]; then
        _select_from_command "Run an Installed Model" "Select an installed model to start an interactive chat:" "installed"
        local status=$?
        [ "$status" -eq 0 ] || return "$status"
        model="$SELECTED_MODEL"
        selected_interactively=true
    else
        _normalize_model_name "$model"
        model="$NORMALIZED_MODEL"
    fi
    if [ "$model" = "nomic-embed-text" ] || [ "$model" = "nomic-embed-text:latest" ]; then
        echo "❌ nomic-embed-text only creates embeddings; it cannot run an interactive chat." >&2
        return 1
    fi
    if [ "$selected_interactively" = "true" ] && ! _installed_model_exists "$model"; then
        printf "❌ Selected model is not an exact installed Ollama tag: %q\n" "$model" >&2
        echo "   Refresh the installed-model list and try again." >&2
        return 1
    fi
    echo "🚀 Starting $model (use /exit or Ctrl+D to leave)..."
    "$OLLAMA_CMD" run "$model"
}

main_menu() {
    local action
    local status
    _require_dialog || return 1
    while true; do
        _dialog_menu "Ollama Model Manager" "Choose an action:" \
            "installed" "List models installed on disk" \
            "running" "List models currently loaded in RAM" \
            "resources" "Show host RAM, CPU, disk, and loaded models" \
            "stop" "Unload a running model from RAM" \
            "delete" "Delete an installed model from disk" \
            "pull" "Pull an article-recommended model" \
            "run" "Run an installed chat model"
        status=$?
        [ "$status" -eq "$MENU_BACK_STATUS" ] && return 0
        [ "$status" -eq 0 ] || return "$status"
        action="$DIALOG_CHOICE"
        case "$action" in
            installed) list_installed; status=$? ;;
            running) list_running; status=$? ;;
            resources) show_resources; status=$? ;;
            stop) stop_model; status=$? ;;
            delete) delete_model; status=$? ;;
            pull) pull_model; status=$? ;;
            run) run_model; status=$? ;;
        esac
        [ "$status" -eq "$MENU_BACK_STATUS" ] && continue
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
status=$?
[ "$status" -eq "$MENU_BACK_STATUS" ] && exit 0
exit "$status"
