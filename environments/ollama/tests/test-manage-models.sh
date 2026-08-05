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
llama3.2:3b             abc123          2.0 GB    1 hour ago
nomic-embed-text:latest def456          274 MB    1 hour ago
OUT
        ;;
    ps)
        cat <<'OUT'
NAME          ID              SIZE      PROCESSOR    CONTEXT    UNTIL
llama3.2:3b   abc123          3.1 GB    100% CPU     4096       4 minutes
OUT
        ;;
esac
STUB

cat > "$TMP_DIR/dialog" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DIALOG_TEST_LOG"
case "$*" in
    *"Pull a Recommended Model"*) printf '%s\n' "hardware" >&2 ;;
    *"Choose Hardware Tier"*) printf '%s\n' "pi4" >&2 ;;
    *"Recommended for pi4"*) printf '%s\n' "qwen3:1.7b" >&2 ;;
esac
exit 0
STUB

cat > "$TMP_DIR/curl" <<'STUB'
#!/usr/bin/env bash
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
    "$TMP_DIR/uname" "$TMP_DIR/systemctl" "$TMP_DIR/sudo" "$TMP_DIR/brew"

export OLLAMA_CMD="$TMP_DIR/ollama"
export DIALOG_CMD="$TMP_DIR/dialog"
export OLLAMA_TEST_LOG="$OLLAMA_LOG"
export DIALOG_TEST_LOG="$DIALOG_LOG"
export OLLAMA_MANAGER_TOTAL_MIB=16384
export OLLAMA_MANAGER_AVAILABLE_MIB=12288

installed_output="$("$MANAGER" --list-installed)"
grep -q "Installed Ollama Models" <<< "$installed_output"
grep -q "llama3.2:3b" <<< "$installed_output"

running_output="$("$MANAGER" --list-running)"
grep -q "Models Loaded in RAM" <<< "$running_output"
grep -q "100% CPU" <<< "$running_output"

resource_output="$("$MANAGER" --resources)"
grep -q "RAM total: 16.0 GiB" <<< "$resource_output"
grep -q "Available: 12.0 GiB" <<< "$resource_output"

export OLLAMA_MANAGER_ASSUME_YES=true
"$MANAGER" --stop llama3.2:3b >/dev/null
"$MANAGER" --delete llama3.2:3b >/dev/null
"$MANAGER" --pull phi4-mini >/dev/null
"$MANAGER" --run llama3.2:3b >/dev/null
grep -q '^stop llama3.2:3b$' "$OLLAMA_LOG"
grep -q '^rm llama3.2:3b$' "$OLLAMA_LOG"
grep -q '^pull phi4-mini$' "$OLLAMA_LOG"
grep -q '^run llama3.2:3b$' "$OLLAMA_LOG"

if "$MANAGER" --run nomic-embed-text >/dev/null 2>&1; then
    echo "Expected the embedding-only model to be rejected by --run" >&2
    exit 1
fi

unset OLLAMA_MANAGER_ASSUME_YES
: > "$OLLAMA_LOG"
: > "$DIALOG_LOG"
"$MANAGER" --pull >/dev/null
grep -q '^pull qwen3:1.7b$' "$OLLAMA_LOG"
grep -q 'Host RAM available now: 12.0 GiB' "$DIALOG_LOG"
grep -q 'Assessment: FITS' "$DIALOG_LOG"

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

echo "✅ Ollama model manager tests passed"
