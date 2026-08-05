#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$(cd "$TEST_DIR/.." && pwd)"
MANAGER="$ENV_DIR/scripts/manage-models.sh"
RUNNER="$ENV_DIR/run.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"; rm -f "$ENV_DIR/post-deploy-info.html"' EXIT

OLLAMA_LOG="$TMP_DIR/ollama.log"
DIALOG_LOG="$TMP_DIR/dialog.log"

cat > "$TMP_DIR/ollama" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$OLLAMA_TEST_LOG"
case "${1:-}" in
    list)
        cat <<'OUT'
NAME                    ID              SIZE      MODIFIED
llama3.2:latest         abc123          2.0 GB    1 hour ago
nomic-embed-text:latest def456          274 MB    1 hour ago
OUT
        ;;
    ps)
        cat <<'OUT'
NAME          ID              SIZE      PROCESSOR    CONTEXT    UNTIL
llama3.2:latest abc123          3.1 GB    100% CPU     4096       4 minutes
OUT
        ;;
esac
STUB

cat > "$TMP_DIR/dialog" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DIALOG_TEST_LOG"
[ "${DIALOG_TEST_UI_MARKER:-false}" = "true" ] && echo "DIALOG_UI:$*" >&2
if [ -n "${DIALOG_TEST_SEQUENCE_FILE:-}" ] && [ -s "$DIALOG_TEST_SEQUENCE_FILE" ]; then
    response="$(sed -n '1p' "$DIALOG_TEST_SEQUENCE_FILE")"
    sed '1d' "$DIALOG_TEST_SEQUENCE_FILE" > "$DIALOG_TEST_SEQUENCE_FILE.next"
    mv "$DIALOG_TEST_SEQUENCE_FILE.next" "$DIALOG_TEST_SEQUENCE_FILE"
    case "$response" in
        BACK) exit 1 ;;
        ESC) exit 255 ;;
        OK) exit 0 ;;
        *) printf '%s\n' "$response" >&3; exit 0 ;;
    esac
fi
case "$*" in
    *"Pull a Recommended Model"*) printf '%s\n' "hardware" >&3 ;;
    *"Choose Hardware Tier"*) printf '%s\n' "pi4" >&3 ;;
    *"Recommended for pi4"*) printf '%s\n' "qwen3:1.7b" >&3 ;;
    *"Stop a Running Model"*) printf '%s\n' '"llama3.2:latest"' >&3 ;;
    *"Delete an Installed Model"*) printf 'llama3.2:latest\r\n' >&3 ;;
    *"Run an Installed Model"*)
        if [ "${DIALOG_TEST_INVALID_RUN:-false}" = "true" ]; then
            printf '%s\n' "not-installed:latest" >&3
        else
            printf 'llama3.2:latest\r\n' >&3
        fi
        ;;
esac
exit 0
STUB

cat > "$TMP_DIR/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "${CURL_TEST_LOG:-/dev/null}"
case "$*" in
    *"https://ollama.com/install.sh"*) echo "exit 0"; exit 0 ;;
esac
[ "${FAKE_HEALTH_MODE:-always}" = "always" ] && exit 0
[ -f "$FAKE_HEALTH_FILE" ]
STUB

cat > "$TMP_DIR/uname" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    -s) printf '%s\n' "${FAKE_UNAME_S:-Linux}" ;;
    -m) printf '%s\n' "${FAKE_UNAME_M:-aarch64}" ;;
    *) printf '%s\n' "${FAKE_UNAME_S:-Linux}" ;;
esac
STUB

cat > "$TMP_DIR/memory_pressure" <<'STUB'
#!/usr/bin/env bash
echo "The system has 8589934592 bytes."
echo "System-wide memory free percentage: ${FAKE_PRESSURE_FREE_PERCENT:-43}%"
STUB

cat > "$TMP_DIR/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$PLATFORM_TEST_LOG"
case "${1:-}" in
    list-unit-files) echo "ollama.service enabled" ;;
    enable) touch "$FAKE_HEALTH_FILE" ;;
esac
STUB

cat > "$TMP_DIR/sudo" <<'STUB'
#!/usr/bin/env bash
"$@"
STUB

cat > "$TMP_DIR/pgrep" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB

cat > "$TMP_DIR/killall" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

cat > "$TMP_DIR/pkill" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

cat > "$TMP_DIR/rm" <<'STUB'
#!/usr/bin/env bash
echo "rm $*" >> "$PLATFORM_TEST_LOG"
exit 0
STUB

cat > "$TMP_DIR/brew" <<'STUB'
#!/usr/bin/env bash
echo "brew $*" >> "$PLATFORM_TEST_LOG"
case "${1:-}" in
    list) exit 0 ;;
    services) touch "$FAKE_HEALTH_FILE" ;;
esac
exit 0
STUB

chmod +x "$TMP_DIR/ollama" "$TMP_DIR/dialog" "$TMP_DIR/curl" \
    "$TMP_DIR/uname" "$TMP_DIR/systemctl" "$TMP_DIR/sudo" "$TMP_DIR/pgrep" \
    "$TMP_DIR/killall" "$TMP_DIR/pkill" "$TMP_DIR/rm" "$TMP_DIR/brew" \
    "$TMP_DIR/memory_pressure"

export OLLAMA_CMD="$TMP_DIR/ollama"
export DIALOG_CMD="$TMP_DIR/dialog"
export OLLAMA_TEST_LOG="$OLLAMA_LOG"
export DIALOG_TEST_LOG="$DIALOG_LOG"
export CURL_TEST_LOG="$TMP_DIR/curl.log"
export OLLAMA_MANAGER_TOTAL_MIB=16384
export OLLAMA_MANAGER_AVAILABLE_MIB=12288
export OLLAMA_MANAGER_PRESSURE_STATUS=low
export OLLAMA_MANAGER_PRESSURE_DETAIL="test pressure signal"
export OLLAMA_MANAGER_TTY_INPUT=/dev/null
export OLLAMA_MANAGER_TTY_OUTPUT="$TMP_DIR/dialog-ui.log"

_write_model_menu_selection() {
    local output_file="$1"
    local down_count="$2"
    local index=0
    : > "$output_file"
    while [ "$index" -lt "$down_count" ]; do
        printf '\033[B' >> "$output_file"
        index=$((index + 1))
    done
    printf '\n' >> "$output_file"
}

installed_output="$("$MANAGER" --list-installed)"
grep -q "Installed Ollama Models" <<< "$installed_output"
grep -q "llama3.2:latest" <<< "$installed_output"

running_output="$("$MANAGER" --list-running)"
grep -q "Models Loaded in RAM" <<< "$running_output"
grep -q "100% CPU" <<< "$running_output"

resource_output="$("$MANAGER" --resources)"
grep -q "RAM total: 16.0 GiB" <<< "$resource_output"
grep -q "Available: 12.0 GiB" <<< "$resource_output"
grep -q "Pressure:  LOW — test pressure signal" <<< "$resource_output"

export OLLAMA_MANAGER_ASSUME_YES=true
"$MANAGER" --stop llama3.2:latest >/dev/null
"$MANAGER" --delete llama3.2:latest >/dev/null
"$MANAGER" --pull phi4-mini >/dev/null
"$MANAGER" --run llama3.2:latest >/dev/null
grep -q '^stop llama3.2:latest$' "$OLLAMA_LOG"
grep -q '^rm llama3.2:latest$' "$OLLAMA_LOG"
grep -q '^pull phi4-mini$' "$OLLAMA_LOG"
grep -q '^run llama3.2:latest$' "$OLLAMA_LOG"

if "$MANAGER" --run nomic-embed-text >/dev/null 2>&1; then
    echo "Expected the embedding-only model to be rejected by --run" >&2
    exit 1
fi

unset OLLAMA_MANAGER_ASSUME_YES
: > "$OLLAMA_LOG"
: > "$DIALOG_LOG"
export DIALOG_TEST_UI_MARKER=true
: > "$OLLAMA_MANAGER_TTY_OUTPUT"
MODEL_MENU_INPUT="$TMP_DIR/model-menu-input"
_write_model_menu_selection "$MODEL_MENU_INPUT" 3
OLLAMA_MANAGER_TTY_INPUT="$MODEL_MENU_INPUT" "$MANAGER" --pull >/dev/null
grep -q '^pull qwen3:1.7b$' "$OLLAMA_LOG"
grep -q 'Host RAM available now: 12.0 GiB' "$DIALOG_LOG"
grep -q 'Host memory pressure: LOW — test pressure signal' "$DIALOG_LOG"
grep -q 'Assessment: FITS' "$DIALOG_LOG"
grep -q 'DIALOG_UI:.*Pull a Recommended Model' "$OLLAMA_MANAGER_TTY_OUTPUT"
grep -a -q 'qwen3:1.7b — Extremely fast small multilingual model' "$OLLAMA_MANAGER_TTY_OUTPUT"
grep -a -q '1.4 GB d/l | 2.0 GiB–3.0 GiB RAM' "$OLLAMA_MANAGER_TTY_OUTPUT"
! grep -a -q 'Qwen 3 1.7B' "$OLLAMA_MANAGER_TTY_OUTPUT"

# Every model recommended by the supplied wiki-model document is present in
# the rendered wiki-use menu. Escape then walks back through use -> browse.
: > "$OLLAMA_LOG"
: > "$OLLAMA_MANAGER_TTY_OUTPUT"
export DIALOG_TEST_SEQUENCE_FILE="$TMP_DIR/dialog-sequence"
printf '%s\n' use wiki BACK BACK > "$DIALOG_TEST_SEQUENCE_FILE"
printf '\033' > "$MODEL_MENU_INPUT"
OLLAMA_MANAGER_TTY_INPUT="$MODEL_MENU_INPUT" "$MANAGER" --pull >/dev/null
! grep -q '^pull ' "$OLLAMA_LOG"
[ ! -s "$DIALOG_TEST_SEQUENCE_FILE" ]
for wiki_model in phi4-mini gemma4:e4b qwen3.5:2b qwen3.5:4b llama3.2:3b; do
    grep -a -q "$wiki_model" "$OLLAMA_MANAGER_TTY_OUTPUT"
done
unset DIALOG_TEST_SEQUENCE_FILE

# Low pressure can soften a low-available-RAM result because macOS may still
# have reclaimable/compressible capacity. Elevated pressure cannot.
export OLLAMA_MANAGER_TOTAL_MIB=8192
export OLLAMA_MANAGER_AVAILABLE_MIB=1024
export OLLAMA_MANAGER_PRESSURE_STATUS=low
: > "$DIALOG_LOG"
"$MANAGER" --pull qwen3:1.7b >/dev/null
grep -q 'Assessment: CAUTION — available RAM is low, but low pressure indicates reclaimable/compressible capacity' "$DIALOG_LOG"

export OLLAMA_MANAGER_PRESSURE_STATUS=high
: > "$DIALOG_LOG"
"$MANAGER" --pull qwen3:1.7b >/dev/null
grep -q 'Assessment: EXCEEDS — available RAM is below the projected minimum and pressure is not low' "$DIALOG_LOG"

export OLLAMA_MANAGER_TOTAL_MIB=1024
export OLLAMA_MANAGER_PRESSURE_STATUS=low
: > "$DIALOG_LOG"
"$MANAGER" --pull qwen3:1.7b >/dev/null
grep -q 'Assessment: EXCEEDS — projected minimum is larger than physical RAM' "$DIALOG_LOG"

export OLLAMA_MANAGER_TOTAL_MIB=16384
export OLLAMA_MANAGER_AVAILABLE_MIB=12288
export OLLAMA_MANAGER_PRESSURE_STATUS=low

# Verify the native pressure collectors used on Mac and Pi/Linux.
unset OLLAMA_MANAGER_PRESSURE_STATUS
unset OLLAMA_MANAGER_PRESSURE_DETAIL
export FAKE_UNAME_S=Darwin
export FAKE_PRESSURE_FREE_PERCENT=43
resource_output="$(PATH="$TMP_DIR:$PATH" "$MANAGER" --resources)"
grep -q 'Pressure:  LOW — macOS reports 43% free memory capacity' <<< "$resource_output"

export FAKE_PRESSURE_FREE_PERCENT=15
resource_output="$(PATH="$TMP_DIR:$PATH" "$MANAGER" --resources)"
grep -q 'Pressure:  MODERATE — macOS reports 15% free memory capacity' <<< "$resource_output"

export FAKE_UNAME_S=Linux
export OLLAMA_MANAGER_PSI_FILE="$TMP_DIR/memory.pressure"
printf '%s\n' \
    'some avg10=12.50 avg60=4.00 avg300=1.00 total=100' \
    'full avg10=1.25 avg60=0.50 avg300=0.10 total=20' \
    > "$OLLAMA_MANAGER_PSI_FILE"
resource_output="$(PATH="$TMP_DIR:$PATH" "$MANAGER" --resources)"
grep -q 'Pressure:  HIGH — Linux PSI avg10: some=12.50%, full=1.25%' <<< "$resource_output"

export OLLAMA_MANAGER_PRESSURE_STATUS=low
export OLLAMA_MANAGER_PRESSURE_DETAIL="test pressure signal"
unset OLLAMA_MANAGER_PSI_FILE
unset FAKE_PRESSURE_FREE_PERCENT

: > "$OLLAMA_LOG"
"$MANAGER" --stop >/dev/null
"$MANAGER" --delete >/dev/null
"$MANAGER" --run >/dev/null
grep -q '^stop llama3.2:latest$' "$OLLAMA_LOG"
grep -q '^rm llama3.2:latest$' "$OLLAMA_LOG"
grep -q '^run llama3.2:latest$' "$OLLAMA_LOG"
grep -q 'DIALOG_UI:.*Stop a Running Model' "$OLLAMA_MANAGER_TTY_OUTPUT"
grep -q 'DIALOG_UI:.*Delete an Installed Model' "$OLLAMA_MANAGER_TTY_OUTPUT"
grep -q 'DIALOG_UI:.*Run an Installed Model' "$OLLAMA_MANAGER_TTY_OUTPUT"

# A cancellation at each Pull submenu must go back exactly one level:
# model -> hardware tier -> browse method, and confirmation -> model.
: > "$OLLAMA_LOG"
: > "$DIALOG_LOG"
export DIALOG_TEST_SEQUENCE_FILE="$TMP_DIR/dialog-sequence"
printf '%s\n' \
    hardware \
    pi4 \
    BACK \
    all \
    BACK \
    OK > "$DIALOG_TEST_SEQUENCE_FILE"
export OLLAMA_MANAGER_MODEL_MENU_SEQUENCE_FILE="$TMP_DIR/model-menu-sequence"
printf '%s\n' \
    BACK \
    qwen3:1.7b \
    qwen3:1.7b > "$OLLAMA_MANAGER_MODEL_MENU_SEQUENCE_FILE"
"$MANAGER" --pull >/dev/null
grep -q '^pull qwen3:1.7b$' "$OLLAMA_LOG"
[ ! -s "$DIALOG_TEST_SEQUENCE_FILE" ]
[ ! -s "$OLLAMA_MANAGER_MODEL_MENU_SEQUENCE_FILE" ]
[ "$(grep -c 'Choose Hardware Tier' "$DIALOG_LOG")" -eq 2 ]
[ "$(grep -c 'Pull Qwen' "$DIALOG_LOG")" -eq 2 ]
unset DIALOG_TEST_SEQUENCE_FILE
unset OLLAMA_MANAGER_MODEL_MENU_SEQUENCE_FILE

# The same Back status must remain inside the full manager rather than unwind
# the script: Pull -> hardware -> model -> hardware -> Pull -> main manager.
: > "$DIALOG_LOG"
export DIALOG_TEST_SEQUENCE_FILE="$TMP_DIR/dialog-sequence"
printf '%s\n' \
    pull \
    hardware \
    pi4 \
    BACK \
    BACK \
    ESC > "$DIALOG_TEST_SEQUENCE_FILE"
export OLLAMA_MANAGER_MODEL_MENU_SEQUENCE_FILE="$TMP_DIR/model-menu-sequence"
printf '%s\n' BACK > "$OLLAMA_MANAGER_MODEL_MENU_SEQUENCE_FILE"
"$MANAGER" >/dev/null
[ ! -s "$DIALOG_TEST_SEQUENCE_FILE" ]
[ ! -s "$OLLAMA_MANAGER_MODEL_MENU_SEQUENCE_FILE" ]
[ "$(grep -c 'Ollama Model Manager' "$DIALOG_LOG")" -eq 2 ]
[ "$(grep -c 'Pull a Recommended Model' "$DIALOG_LOG")" -eq 2 ]
unset DIALOG_TEST_SEQUENCE_FILE
unset OLLAMA_MANAGER_MODEL_MENU_SEQUENCE_FILE

# A literal Escape byte from the terminal backs out of the two-line catalog.
: > "$OLLAMA_LOG"
export DIALOG_TEST_SEQUENCE_FILE="$TMP_DIR/dialog-sequence"
printf '%s\n' hardware pi4 BACK BACK > "$DIALOG_TEST_SEQUENCE_FILE"
printf '\033' > "$MODEL_MENU_INPUT"
OLLAMA_MANAGER_TTY_INPUT="$MODEL_MENU_INPUT" "$MANAGER" --pull >/dev/null
! grep -q '^pull ' "$OLLAMA_LOG"
[ ! -s "$DIALOG_TEST_SEQUENCE_FILE" ]
unset DIALOG_TEST_SEQUENCE_FILE

# The 16GB Mac tier is deliberately the complete catalog. Its first page must
# make pagination obvious rather than making later models appear absent.
catalog_count="$(awk -F '\t' '$0 !~ /^#/ { count++ } END { print count + 0 }' "$ENV_DIR/models.tsv")"
mac16_count="$(awk -F '\t' '
    $0 !~ /^#/ && ("," $6 ",") ~ /,mac16,/ { count++ }
    END { print count + 0 }
' "$ENV_DIR/models.tsv")"
[ "$mac16_count" -eq "$catalog_count" ]
: > "$OLLAMA_LOG"
: > "$OLLAMA_MANAGER_TTY_OUTPUT"
export DIALOG_TEST_SEQUENCE_FILE="$TMP_DIR/dialog-sequence"
printf '%s\n' hardware mac16 BACK BACK > "$DIALOG_TEST_SEQUENCE_FILE"
printf '\033' > "$MODEL_MENU_INPUT"
OLLAMA_MANAGER_TTY_INPUT="$MODEL_MENU_INPUT" "$MANAGER" --pull >/dev/null
! grep -q '^pull ' "$OLLAMA_LOG"
grep -a -q "Showing 1–8 of $catalog_count.*↓ more below" "$OLLAMA_MANAGER_TTY_OUTPUT"
[ ! -s "$DIALOG_TEST_SEQUENCE_FILE" ]
unset DIALOG_TEST_SEQUENCE_FILE

: > "$OLLAMA_LOG"
export DIALOG_TEST_SEQUENCE_FILE="$TMP_DIR/dialog-sequence"
printf '%s\n' ESC > "$DIALOG_TEST_SEQUENCE_FILE"
"$MANAGER" --run >/dev/null
! grep -q '^run ' "$OLLAMA_LOG"
unset DIALOG_TEST_SEQUENCE_FILE

: > "$OLLAMA_LOG"
export DIALOG_TEST_INVALID_RUN=true
if "$MANAGER" --run >"$TMP_DIR/invalid-run.out" 2>&1; then
    echo "Expected a non-installed dialog selection to be rejected" >&2
    exit 1
fi
! grep -q '^run ' "$OLLAMA_LOG"
grep -q 'not an exact installed Ollama tag' "$TMP_DIR/invalid-run.out"
unset DIALOG_TEST_INVALID_RUN
unset DIALOG_TEST_UI_MARKER

export FAKE_HEALTH_MODE=state
export FAKE_HEALTH_FILE="$TMP_DIR/healthy"
export PLATFORM_TEST_LOG="$TMP_DIR/platform.log"

export FAKE_UNAME_S=Linux
export FAKE_UNAME_M=aarch64
runner_output="$(PATH="$TMP_DIR:$PATH" "$RUNNER")"
grep -q "Ollama is responsive" <<< "$runner_output"
grep -q '^systemctl enable --now ollama$' "$PLATFORM_TEST_LOG"

rm -f "$FAKE_HEALTH_FILE"
: > "$PLATFORM_TEST_LOG"
export FAKE_UNAME_S=Darwin
export FAKE_UNAME_M=arm64
runner_output="$(PATH="$TMP_DIR:$PATH" "$RUNNER")"
grep -q "Ollama is responsive" <<< "$runner_output"
grep -q '^brew services start ollama$' "$PLATFORM_TEST_LOG"

rm -f "$FAKE_HEALTH_FILE"
: > "$PLATFORM_TEST_LOG"
export FAKE_UNAME_S=Linux
REBUILD_POLICY=STOP PATH="$TMP_DIR:$PATH" "$RUNNER" >"$TMP_DIR/linux-stop.out"
grep -q '^systemctl stop ollama$' "$PLATFORM_TEST_LOG"
grep -q 'Downloaded models are unchanged' "$TMP_DIR/linux-stop.out"

: > "$PLATFORM_TEST_LOG"
OLLAMA_TEARDOWN_BIN=/usr/local/bin/ollama REBUILD_POLICY=TEARDOWN \
    PATH="$TMP_DIR:$PATH" "$RUNNER" >"$TMP_DIR/linux-teardown.out" 2>&1
grep -q '^systemctl disable ollama$' "$PLATFORM_TEST_LOG"
grep -q '^systemctl daemon-reload$' "$PLATFORM_TEST_LOG"
grep -q '^rm -f -- /usr/local/bin/ollama$' "$PLATFORM_TEST_LOG"
grep -q 'downloaded models were preserved' "$TMP_DIR/linux-teardown.out"

: > "$PLATFORM_TEST_LOG"
export FAKE_UNAME_S=Darwin
REBUILD_POLICY=TEARDOWN PATH="$TMP_DIR:$PATH" "$RUNNER" >"$TMP_DIR/mac-teardown.out"
grep -q '^brew services stop ollama$' "$PLATFORM_TEST_LOG"
grep -q '^brew uninstall ollama$' "$PLATFORM_TEST_LOG"
grep -q 'downloaded models were preserved' "$TMP_DIR/mac-teardown.out"

rm -f "$FAKE_HEALTH_FILE"
: > "$PLATFORM_TEST_LOG"
export FAKE_UNAME_S=Darwin
printf 'y\n' | OLLAMA_CMD=missing-ollama PATH="$TMP_DIR:$PATH" \
    /bin/bash "$RUNNER" >"$TMP_DIR/mac-install.out"
grep -q '^brew install ollama$' "$PLATFORM_TEST_LOG"
grep -q '^brew services start ollama$' "$PLATFORM_TEST_LOG"

rm -f "$FAKE_HEALTH_FILE"
: > "$PLATFORM_TEST_LOG"
: > "$CURL_TEST_LOG"
export FAKE_UNAME_S=Linux
export FAKE_UNAME_M=aarch64
printf 'y\n' | OLLAMA_CMD=missing-ollama PATH="$TMP_DIR:$PATH" \
    /bin/bash "$RUNNER" >"$TMP_DIR/linux-install.out"
grep -q 'https://ollama.com/install.sh' "$CURL_TEST_LOG"
grep -q '^systemctl enable --now ollama$' "$PLATFORM_TEST_LOG"

echo "✅ Ollama model manager tests passed"
