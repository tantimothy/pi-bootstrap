#!/usr/bin/env bash
# Interactive operator menu for the credentials in NanoClaw's OneCLI vault.
#
# OneCLI is the gateway agent traffic goes through: it injects a stored
# credential into requests to a matching host, and blocks hosts it has none
# for (the agent is then handed a dashboard link). This is the terminal
# equivalent of that dashboard's "connections" page, using the `onecli` CLI
# that NanoClaw installs inside the orchestrator container.
#
# Flags used (`secrets create|update|delete|list`, `agents grants ...`) were
# read from github.com/onecli/onecli-cli at main, not from the exact version
# installed here — the CLI is young and still changing (its README marks
# several older commands RETIRED). A rejected command's own error is printed
# verbatim rather than interpreted.
#
# Secret values never appear in this script's argv or in shell history: they
# are read with `read -s` and piped over stdin into the container.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
[ -f "$ENV_DIR/.env" ] && { set -a; source "$ENV_DIR/.env"; set +a; }

INSTALL_PATH="${NANOCLAW_INSTALL_PATH:-$HOME/nanoclaw-mnemon}"
CONTAINER_NAME="${CONTAINER_NAME:-nanoclaw-mnemon}"
DOCKER="${DOCKER_CMD:-docker}"

require_container() {
    if ! "$DOCKER" ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
        echo "❌ $CONTAINER_NAME is not running. Deploy the environment first." >&2
        exit 1
    fi
    if ! "$DOCKER" exec "$CONTAINER_NAME" bash -lc 'onecli version >/dev/null 2>&1'; then
        echo "❌ The onecli CLI isn't available (or isn't authenticated) inside $CONTAINER_NAME." >&2
        echo "   A fresh install installs it during NanoClaw's first-run wizard; after a CLEAN," >&2
        echo "   'Manage Codex Provider' → Install / refresh restores it." >&2
        exit 1
    fi
}

# Runs a snippet inside the container. Arguments become $1.. in the snippet,
# so user input is never spliced into shell text. Stdin passes through.
run_in() {
    local snippet="$1"; shift
    "$DOCKER" exec -i "$CONTAINER_NAME" bash -lc "$snippet" _ "$@"
}

valid() { # valid <regex> <value> <what>
    if ! [[ "$2" =~ $1 ]]; then
        echo "❌ Invalid $3: '$2'" >&2
        return 1
    fi
}

list_secrets() {
    echo ""
    run_in 'onecli secrets list --max 200 | jq -r "
        (.data // .) as \$s
        | if (\$s | length) == 0 then \"(no credentials stored)\"
          else \$s[] | \"\(.id)  \(.name // \"-\")  [\(.type // \"-\")]  \(.hostPattern // \"-\")\(.pathPattern // \"\")\"
          end"'
    echo ""
}

read_secret_value() {
    local v=""
    read -rsp "Secret value (input hidden): " v; echo "" >&2
    if [ -z "$v" ]; then echo "❌ Empty value." >&2; return 1; fi
    printf '%s' "$v"
}

add_credential() { # $1 = header | param
    local mode="$1" name host path inj_name fmt
    echo ""
    echo "⚠️  The stored value is sent to the destination host on every matching request."
    echo "   Only add a credential for a host you trust with it — a third-party mirror or"
    echo "   proxy of a service is NOT the service."
    echo ""
    read -rp "Name (display label): " name
    valid '^[A-Za-z0-9 ._-]+$' "$name" "name" || return 1
    read -rp "Host pattern (e.g. api.example.com, *.example.com): " host
    valid '^[A-Za-z0-9*.-]+$' "$host" "host pattern" || return 1
    read -rp "Path pattern [/*]: " path; path="${path:-/*}"
    valid '^/[A-Za-z0-9*._/~%-]*$' "$path" "path pattern" || return 1
    if [ "$mode" = header ]; then
        read -rp "Header name [Authorization]: " inj_name; inj_name="${inj_name:-Authorization}"
        valid '^[A-Za-z0-9-]+$' "$inj_name" "header name" || return 1
        echo "Value format: how the stored value is written into the header. {value} is the secret."
        echo "  e.g. 'Bearer {value}' for Authorization, 'reddit_session={value}' for Cookie."
        read -rp "Value format [{value}]: " fmt; fmt="${fmt:-{value\}}"
    else
        read -rp "Query parameter name (e.g. key): " inj_name
        valid '^[A-Za-z0-9_.-]+$' "$inj_name" "parameter name" || return 1
        read -rp "Param format [{value}]: " fmt; fmt="${fmt:-{value\}}"
    fi
    case "$fmt" in *'{value}'*) ;; *) echo "❌ Format must contain {value}." >&2; return 1 ;; esac
    local value; value="$(read_secret_value)" || return 1

    # The value goes in via stdin to a 0600 temp file inside the container and is
    # passed with --file, so it is never on a command line.
    printf '%s' "$value" | run_in '
        set -e
        umask 077; f=$(mktemp); trap "rm -f \"$f\"" EXIT; cat > "$f"
        if [ "$1" = header ]; then
            onecli secrets create --type generic --name "$2" --host-pattern "$3" --path-pattern "$4" \
                --header-name "$5" --value-format "$6" --file "$f"
        else
            onecli secrets create --type generic --name "$2" --host-pattern "$3" --path-pattern "$4" \
                --param-name "$5" --param-format "$6" --file "$f"
        fi' "$mode" "$name" "$host" "$path" "$inj_name" "$fmt"
    unset value
    echo ""
    echo "✅ Stored. Depending on the OneCLI version, an agent may also need to be granted"
    echo "   this credential — see the 'Agent access' items in this menu if requests are still blocked."
}

pick_id() { # prints chosen id
    list_secrets >&2
    local id
    read -rp "Credential ID: " id
    valid '^[A-Za-z0-9._:-]+$' "$id" "ID" || return 1
    printf '%s' "$id"
}

update_value() {
    local id; id="$(pick_id)" || return 1
    local value; value="$(read_secret_value)" || return 1
    printf '%s' "$value" | run_in 'onecli secrets update --id "$1" --value "$(cat)"' "$id"
    unset value
    echo "✅ Updated."
}

update_match() {
    local id host path
    id="$(pick_id)" || return 1
    read -rp "New host pattern (blank = unchanged): " host
    read -rp "New path pattern (blank = unchanged): " path
    [ -n "$host" ] && { valid '^[A-Za-z0-9*.-]+$' "$host" "host pattern" || return 1; }
    [ -n "$path" ] && { valid '^/[A-Za-z0-9*._/~%-]*$' "$path" "path pattern" || return 1; }
    [ -z "$host$path" ] && { echo "Nothing to change."; return 0; }
    run_in '
        args=(--id "$1"); [ -n "$2" ] && args+=(--host-pattern "$2"); [ -n "$3" ] && args+=(--path-pattern "$3")
        onecli secrets update "${args[@]}"' "$id" "$host" "$path"
}

delete_credential() {
    local id ans; id="$(pick_id)" || return 1
    read -rp "Delete credential $id? Agents lose access to that host. [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "Cancelled."; return 0; }
    run_in 'onecli secrets delete --id "$1"' "$id"
}

agent_access() {
    echo ""
    run_in 'onecli agents list --with-grants'
    echo ""
}

attach_to_agent() {
    agent_access
    local agent secret
    read -rp "Agent ID: " agent
    valid '^[A-Za-z0-9._:-]+$' "$agent" "agent ID" || return 1
    secret="$(pick_id)" || return 1
    run_in 'onecli agents grants attach-secret --id "$1" --secret-id "$2"' "$agent" "$secret"
}

show_dashboard() {
    local url=""
    if [ -f "$INSTALL_PATH/.env" ]; then
        url=$(sed -n 's/^ONECLI_URL=//p' "$INSTALL_PATH/.env" | tail -1)
        url="${url#\'}"; url="${url%\'}"; url="${url#\"}"; url="${url%\"}"
    fi
    echo "OneCLI dashboard: ${url:-unknown (no ONECLI_URL in $INSTALL_PATH/.env)}"
    echo "(When an agent is blocked on an unknown host it is handed a deep link to this"
    echo " dashboard; opening that link works too.)"
}

require_container

echo "Manage OneCLI credentials (NanoClaw vault)"
echo "=========================================="
echo "  1) List credentials"
echo "  2) Add credential — injected as a header   (API key, Bearer token, Cookie)"
echo "  3) Add credential — injected as a query parameter"
echo "  4) Update a credential's value"
echo "  5) Change a credential's host / path pattern"
echo "  6) Delete a credential"
echo "  7) Agent access: show agents and their grants"
echo "  8) Agent access: attach a credential to an agent"
echo "  9) Show dashboard URL"
read -rp "Number: " ACTION

case "$ACTION" in
    1) list_secrets ;;
    2) add_credential header ;;
    3) add_credential param ;;
    4) update_value ;;
    5) update_match ;;
    6) delete_credential ;;
    7) agent_access ;;
    8) attach_to_agent ;;
    9) show_dashboard ;;
    *) echo "❌ Not a valid choice: $ACTION" >&2; exit 1 ;;
esac
