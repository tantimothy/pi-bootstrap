#!/bin/bash
set -euo pipefail

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

CURRENT_UID="$(id -u opencode)"
CURRENT_GID="$(id -g opencode)"
[ "$PUID" = "$CURRENT_UID" ] || usermod -u "$PUID" opencode

# macOS commonly uses GID 20 ("staff"). Debian already has a different group
# at that numeric GID, so `groupmod -g 20 opencode` would fail with "GID
# already exists". Reuse an existing numeric group when present; otherwise
# renumber the private opencode group as usual.
if [ "$PGID" != "$CURRENT_GID" ]; then
    EXISTING_GROUP="$(getent group "$PGID" | cut -d: -f1 || true)"
    if [ -n "$EXISTING_GROUP" ]; then
        usermod -g "$EXISTING_GROUP" opencode
    else
        groupmod -g "$PGID" opencode
    fi
fi

# Both of these are named-volume mount points, so create them rather than
# assuming OpenCode will find them.
mkdir -p /home/opencode/.config/opencode \
         /home/opencode/.local/share/opencode \
         /home/opencode/workspace \
         /home/opencode/.ssh

# The whole user home is persistent, so fix ownership for settings created
# under the image's original 1000:1000 identity. Explicitly prune the nested
# bind-mounted workspace: recursively changing a possibly large host repo is
# unnecessary on Linux and crosses the VM/host boundary on macOS.
find /home/opencode -path /home/opencode/workspace -prune \
    -o -exec chown "$PUID:$PGID" {} +
chown "$PUID:$PGID" /home/opencode/workspace

ssh-keygen -A
if [ -f /run/host-authorized_keys ]; then
    cp /run/host-authorized_keys /home/opencode/.ssh/authorized_keys
else
    echo "⚠️  No authorized_keys file found; SSH login is unavailable until the configured host file exists." >&2
    : > /home/opencode/.ssh/authorized_keys
fi
chown -R "$PUID:$PGID" /home/opencode/.ssh
chmod 700 /home/opencode/.ssh
chmod 600 /home/opencode/.ssh/authorized_keys

if [ -n "${GIT_USER_NAME:-}" ]; then
    runuser -u opencode -- git config --global user.name "$GIT_USER_NAME"
fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then
    runuser -u opencode -- git config --global user.email "$GIT_USER_EMAIL"
fi

if [ -n "${GH_TOKEN:-}" ]; then
    runuser -u opencode -- env GH_TOKEN="$GH_TOKEN" gh auth setup-git
fi

# PAM reads /etc/environment into every SSH login, which is where the tmux
# session — and therefore OpenCode — is started. OpenCode can also hold
# credentials itself in ~/.local/share/opencode/auth.json via `opencode auth
# login`; these variables are the alternative for a plain API key.
#
# Each value is DELETED FIRST and only then re-added, so clearing a variable
# in .env really clears it rather than leaving a revoked key working until
# the volume is wiped.
for VAR in GH_TOKEN ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY \
           OPENROUTER_API_KEY OPENCODE_MODEL OPENCODE_AGENT \
           OPENCODE_AUTO_APPROVE; do
    sed -i "/^${VAR}=/d" /etc/environment
    VALUE="$(printenv "$VAR" 2>/dev/null || true)"
    # `[ -n ... ] && printf` would be the last command in the loop body, so
    # an empty value would return 1 and `set -e` would kill the entrypoint.
    if [ -n "$VALUE" ]; then
        printf '%s=%s\n' "$VAR" "$VALUE" >> /etc/environment
    fi
done

# ─────────────────────────────────────────────────────────────────────────
# Gateway routing — a provider baseURL in opencode.json.
#
# SEEDED ONLY WHEN ABSENT, for the same reason pi's models.json is: this
# file lives in a persistent volume and is the file the operator edits by
# hand (agents, permissions, MCP servers, formatters). A deploy that rewrote
# it every time would silently discard that work.
#
# OpenCode does offer OPENCODE_CONFIG_CONTENT, an inline runtime override
# with the HIGHEST precedence of any config source. That is deliberately not
# used here: it would silently win over whatever the operator later writes
# into opencode.json, which is the same failure in a less visible form.
# ─────────────────────────────────────────────────────────────────────────
OC_CONFIG="/home/opencode/.config/opencode/opencode.json"
if [ -n "${OPENCODE_GATEWAY_BASE_URL:-}" ] && [ ! -e "$OC_CONFIG" ]; then
    cat > "$OC_CONFIG" <<JSON
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "openai": {
      "options": {
        "baseURL": "${OPENCODE_GATEWAY_BASE_URL}"
      }
    }
  }
}
JSON
    chown "$PUID:$PGID" "$OC_CONFIG"
    echo "✅ Seeded $OC_CONFIG pointing the openai provider at $OPENCODE_GATEWAY_BASE_URL"
    if [ -z "${OPENCODE_GATEWAY_API_KEY:-}" ]; then
        echo "ℹ️  OPENCODE_GATEWAY_API_KEY is unset. The gateway's own key goes in" >&2
        echo "   OPENAI_API_KEY (that is the provider being redirected), or run" >&2
        echo "   'opencode auth login' once inside the container." >&2
    fi
fi
# The gateway key belongs to the provider whose baseURL was redirected, so it
# is OPENAI_API_KEY as far as OpenCode is concerned. Set separately from
# OPENAI_API_KEY so that pointing at the gateway does not require overloading
# a variable that means something else when the gateway is not in use.
if [ -n "${OPENCODE_GATEWAY_API_KEY:-}" ]; then
    sed -i '/^OPENAI_API_KEY=/d' /etc/environment
    printf 'OPENAI_API_KEY=%s\n' "$OPENCODE_GATEWAY_API_KEY" >> /etc/environment
fi

exec /usr/sbin/sshd -D -e
