REPO_DIR="$PWD/fake"
OLLAMA_SERVE_HOST=""
_OLLAMA_ENV_FILE="$REPO_DIR/environments/ollama/.env"
if [ -z "$OLLAMA_SERVE_HOST" ] && [ -f "$_OLLAMA_ENV_FILE" ]; then
    OLLAMA_SERVE_HOST="$(grep -E '^[[:space:]]*OLLAMA_SERVE_HOST=' "$_OLLAMA_ENV_FILE" 2>/dev/null \
        | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
fi
echo "quoted value  -> [$OLLAMA_SERVE_HOST]"
printf 'OLLAMA_SERVE_HOST=1.2.3.4:11434\n' > "$_OLLAMA_ENV_FILE"
OLLAMA_SERVE_HOST=""
OLLAMA_SERVE_HOST="$(grep -E '^[[:space:]]*OLLAMA_SERVE_HOST=' "$_OLLAMA_ENV_FILE" | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
echo "unquoted      -> [$OLLAMA_SERVE_HOST]"
printf '#OLLAMA_SERVE_HOST=0.0.0.0:11434\n' > "$_OLLAMA_ENV_FILE"
OLLAMA_SERVE_HOST=""
OLLAMA_SERVE_HOST="$(grep -E '^[[:space:]]*OLLAMA_SERVE_HOST=' "$_OLLAMA_ENV_FILE" | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
echo "commented out -> [${OLLAMA_SERVE_HOST}]  (must be empty)"
