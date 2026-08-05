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
    "$TMP_DIR/killall" "$TMP_DIR/pkill" "$TMP_DIR/rm" "$TMP_DIR/brew"

export OLLAMA_CMD="$TMP_DIR/ollama"
export DIALOG_CMD="$TMP_DIR/dialog"
export OLLAMA_TEST_LOG="$OLLAMA_LOG"
export DIALOG_TEST_LOG="$DIALOG_LOG"
export CURL_TEST_LOG="$TMP_DIR/curl.log"
export OLLAMA_MANAGER_TOTAL_MIB=16384
export OLLAMA_MANAGER_AVAILABLE_MIB=12288
export OLLAMA_MANAGER_TTY_INPUT=/dev/null
export OLLAMA_MANAGER_TTY_OUTPUT="$TMP_DIR/dialog-ui.log"

installed_output="$("$MANAGER" --list-installed)"
grep -q "Installed Ollama Models" <<< "$installed_output"
grep -q "llama3.2:latest" <<< "$installed_output"

running_output="$("$MANAGER" --list-running)"
grep -q "Models Loaded in RAM" <<< "$running_output"
grep -q "100% CPU" <<< "$running_output"

resource_output="$("$MANAGER" --resources)"
grep -q "RAM total: 16.0 GiB" <<< "$resource_output"
grep -q "Available: 12.0 GiB" <<< "$resource_output"

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
"$MANAGER" --pull >/dev/null
grep -q '^pull qwen3:1.7b$' "$OLLAMA_LOG"
grep -q 'Host RAM available now: 12.0 GiB' "$DIALOG_LOG"
grep -q 'Assessment: FITS' "$DIALOG_LOG"
grep -q 'DIALOG_UI:.*Pull a Recommended Model' "$OLLAMA_MANAGER_TTY_OUTPUT"
recommended_line="$(grep 'Recommended for pi4' "$DIALOG_LOG")"
[[ "$recommended_line" == *"Extremely fast small multilingual model"* ]]
[[ "$recommended_line" != *"Qwen 3 1.7B"* ]]

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
    ESC \
    BACK \
    all \
    qwen3:1.7b \
    BACK \
    qwen3:1.7b \
    OK > "$DIALOG_TEST_SEQUENCE_FILE"
"$MANAGER" --pull >/dev/null
grep -q '^pull qwen3:1.7b$' "$OLLAMA_LOG"
[ ! -s "$DIALOG_TEST_SEQUENCE_FILE" ]
[ "$(grep -c 'Choose Hardware Tier' "$DIALOG_LOG")" -eq 2 ]
[ "$(grep -c 'All Recommended Models' "$DIALOG_LOG")" -eq 2 ]
[ "$(grep -c 'Pull Qwen' "$DIALOG_LOG")" -eq 2 ]
unset DIALOG_TEST_SEQUENCE_FILE

# The same Back status must remain inside the full manager rather than unwind
# the script: Pull -> hardware -> model -> hardware -> Pull -> main manager.
: > "$DIALOG_LOG"
export DIALOG_TEST_SEQUENCE_FILE="$TMP_DIR/dialog-sequence"
printf '%s\n' \
    pull \
    hardware \
    pi4 \
    ESC \
    BACK \
    BACK \
    ESC > "$DIALOG_TEST_SEQUENCE_FILE"
"$MANAGER" >/dev/null
[ ! -s "$DIALOG_TEST_SEQUENCE_FILE" ]
[ "$(grep -c 'Ollama Model Manager' "$DIALOG_LOG")" -eq 2 ]
[ "$(grep -c 'Pull a Recommended Model' "$DIALOG_LOG")" -eq 2 ]
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
