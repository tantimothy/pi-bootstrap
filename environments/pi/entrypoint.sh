#!/bin/bash
set -euo pipefail

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

CURRENT_UID="$(id -u pi)"
CURRENT_GID="$(id -g pi)"
[ "$PUID" = "$CURRENT_UID" ] || usermod -u "$PUID" pi

# macOS commonly uses GID 20 ("staff"). Debian already has a different group
# at that numeric GID, so `groupmod -g 20 pi` would fail with "GID already
# exists". Reuse an existing numeric group when present; otherwise renumber
# the private pi group as usual. This keeps the same image usable with
# Linux's common 1000:1000 and macOS's common 501:20 ownership.
if [ "$PGID" != "$CURRENT_GID" ]; then
    EXISTING_GROUP="$(getent group "$PGID" | cut -d: -f1 || true)"
    if [ -n "$EXISTING_GROUP" ]; then
        usermod -g "$EXISTING_GROUP" pi
    else
        groupmod -g "$PGID" pi
    fi
fi

# ~/.pi/agent is Pi's config root (PI_CODING_AGENT_DIR's default), and the
# whole ~/.pi tree is a named volume, so create the inner directory rather
# than assuming Pi will find one.
mkdir -p /home/pi/.pi/agent /home/pi/workspace /home/pi/.ssh

# The whole user home is persistent, so fix ownership for settings created
# under the image's original 1000:1000 identity. Explicitly prune the nested
# bind-mounted workspace: recursively changing a possibly large host repo is
# unnecessary on Linux and crosses the VM/host boundary on macOS.
find /home/pi -path /home/pi/workspace -prune \
    -o -exec chown "$PUID:$PGID" {} +
chown "$PUID:$PGID" /home/pi/workspace

ssh-keygen -A
if [ -f /run/host-authorized_keys ]; then
    cp /run/host-authorized_keys /home/pi/.ssh/authorized_keys
else
    echo "⚠️  No authorized_keys file found; SSH login is unavailable until the configured host file exists." >&2
    : > /home/pi/.ssh/authorized_keys
fi
chown -R "$PUID:$PGID" /home/pi/.ssh
chmod 700 /home/pi/.ssh
chmod 600 /home/pi/.ssh/authorized_keys

if [ -n "${GIT_USER_NAME:-}" ]; then
    runuser -u pi -- git config --global user.name "$GIT_USER_NAME"
fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then
    runuser -u pi -- git config --global user.email "$GIT_USER_EMAIL"
fi

if [ -n "${GH_TOKEN:-}" ]; then
    runuser -u pi -- env GH_TOKEN="$GH_TOKEN" gh auth setup-git
fi

# ─────────────────────────────────────────────────────────────────────────
# PI DOES NOT READ A .env FILE.
#
# Every other agent in this repo either reads one or has its own credential
# cache. Pi has neither: a provider key must ALREADY BE IN THE SHELL
# ENVIRONMENT when `pi` launches, or the provider simply is not available in
# /model and there is no error saying why.
#
# /etc/environment is how that happens here. PAM reads it into every SSH
# login, which is where the tmux session (and therefore Pi) is started from.
#
# Each value is DELETED FIRST and only then re-added, so clearing a variable
# in .env really clears it. An append-only version of this loop would leave a
# revoked key working until the volume was wiped.
# ─────────────────────────────────────────────────────────────────────────
for VAR in GH_TOKEN ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY \
           OPENROUTER_API_KEY PI_MODEL PI_THINKING PI_OFFLINE PI_TELEMETRY \
           PI_SKIP_VERSION_CHECK; do
    sed -i "/^${VAR}=/d" /etc/environment
    VALUE="$(printenv "$VAR" 2>/dev/null || true)"
    # `[ -n ... ] && printf` would be the last command in the loop body, so an
    # empty value would return 1 and `set -e` would kill the entrypoint.
    if [ -n "$VALUE" ]; then
        printf '%s=%s\n' "$VAR" "$VALUE" >> /etc/environment
    fi
done

# ─────────────────────────────────────────────────────────────────────────
# Gateway routing — models.json, NOT an OPENAI_API_BASE env var.
#
# Worth stating plainly because it differs from aider and claude-cli: Pi has
# no base-URL environment variable. A non-built-in provider is declared in
# ~/.pi/agent/models.json with a `baseUrl`, and that is the only route.
#
# SEEDED ONLY WHEN ABSENT. models.json is in a persistent volume and is a
# file the operator edits by hand (extra models, modelOverrides, headers). A
# deploy that rewrote it every time would silently discard that work, which
# is the same trap collie-client's .env handling avoids.
# ─────────────────────────────────────────────────────────────────────────
PI_MODELS_JSON="/home/pi/.pi/agent/models.json"
if [ -n "${PI_GATEWAY_BASE_URL:-}" ] && [ ! -e "$PI_MODELS_JSON" ]; then
    MODELS_LIST="${PI_GATEWAY_MODELS:-}"
    if [ -z "$MODELS_LIST" ]; then
        echo "ℹ️  PI_GATEWAY_BASE_URL is set but PI_GATEWAY_MODELS is empty — writing" >&2
        echo "   a gateway provider with no models. Add the model_name entries from" >&2
        echo "   llm-gateways' litellm-config.yaml to PI_GATEWAY_MODELS and redeploy," >&2
        echo "   or edit $PI_MODELS_JSON by hand (it is never overwritten)." >&2
    fi
    # Schema per Pi's docs/models.md: a top-level "providers" object, each
    # provider carrying baseUrl/api/apiKey and a models ARRAY of {id} objects.
    #
    # apiKey is not optional even when the endpoint ignores it: Pi treats a
    # model as requiring auth before it appears in /model at all, so a keyless
    # local server still needs a placeholder here or its models load and stay
    # invisible.
    {
        printf '{\n  "providers": {\n    "gateway": {\n'
        printf '      "baseUrl": "%s",\n' "$PI_GATEWAY_BASE_URL"
        printf '      "api": "openai-completions",\n'
        printf '      "apiKey": "%s",\n' "${PI_GATEWAY_API_KEY:-gateway}"
        printf '      "models": [\n'
        FIRST=1
        OLD_IFS="$IFS"; IFS=','
        for M in $MODELS_LIST; do
            M="$(printf '%s' "$M" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            if [ -n "$M" ]; then
                if [ "$FIRST" -eq 0 ]; then printf ',\n'; fi
                printf '        { "id": "%s" }' "$M"
                FIRST=0
            fi
        done
        IFS="$OLD_IFS"
        printf '\n      ]\n    }\n  }\n}\n'
    } > "$PI_MODELS_JSON"
    chown "$PUID:$PGID" "$PI_MODELS_JSON"
    echo "✅ Seeded $PI_MODELS_JSON pointing at $PI_GATEWAY_BASE_URL"
fi

exec /usr/sbin/sshd -D -e
