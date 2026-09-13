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

# ─────────────────────────────────────────────────────────────────────────
# pi-sandbox — wire it in ONLY if it can actually sandbox.
#
# Pi has no permission prompts and no sandbox of its own. pi-sandbox adds
# allow/deny lists in front of read/write/edit and an OS-level sandbox in
# front of bash, via bubblewrap.
#
# BUBBLEWRAP NEEDS UNPRIVILEGED USER NAMESPACES, and whether a container gets
# them is decided by the runtime, not by this image. So this PROVES it with a
# real bwrap invocation instead of assuming. A security feature that silently
# does not work is worse than none — that is the whole reason for the check.
#
# On failure the container still comes up, Pi still runs, and the message says
# plainly that it is unsandboxed. Refusing to boot would trade a documented
# weakness for an outage.
# ─────────────────────────────────────────────────────────────────────────
PI_SANDBOX_DIR="/usr/local/lib/node_modules/pi-sandbox"
PI_SETTINGS_JSON="/home/pi/.pi/agent/settings.json"
PI_SANDBOX_JSON="/home/pi/.pi/agent/sandbox.json"

_pi_sandbox_usable() {
    [ -d "$PI_SANDBOX_DIR" ] || { echo "   not installed at $PI_SANDBOX_DIR"; return 1; }
    command -v bwrap >/dev/null 2>&1 || { echo "   bwrap not found"; return 1; }
    # The real test: an actual namespace. --unshare-net is what the sandbox
    # relies on and is the part a restrictive runtime blocks first.
    local err
    err="$(bwrap --ro-bind / / --unshare-net --dev /dev true 2>&1)" && return 0
    echo "   bwrap failed: ${err:-unknown error}"
    return 1
}

if [ "${PI_SANDBOX_ENABLED:-1}" = "0" ]; then
    echo "ℹ️  pi-sandbox disabled by PI_SANDBOX_ENABLED=0 — Pi runs unsandboxed."
elif SANDBOX_WHY="$(_pi_sandbox_usable)"; then
    # Seed the policy, never overwrite it. pi-sandbox writes to this same file
    # when you answer "allow permanently" at a prompt, so clobbering it on
    # every deploy would silently discard every decision you had made.
    #
    # The shipped defaults are written for a laptop: they denyRead /home
    # wholesale and allow ".". In this container the workspace IS under
    # /home, so the paths are spelled out explicitly instead of relying on
    # how those two interact.
    if [ ! -e "$PI_SANDBOX_JSON" ]; then
        cat > "$PI_SANDBOX_JSON" <<'SANDBOXJSON'
{
  "enabled": true,
  "filesystem": {
    "allowRead": ["/home/pi/workspace", "/home/pi/.pi", "/tmp"],
    "allowWrite": ["/home/pi/workspace", "/tmp"],
    "denyRead": ["/etc/environment", "/home/pi/.ssh"],
    "denyWrite": [".env", ".env.*", "*.pem", "*.key", "/home/pi/.ssh"]
  }
}
SANDBOXJSON
        chown "$PUID:$PGID" "$PI_SANDBOX_JSON"
        echo "   🧩 Seeded $PI_SANDBOX_JSON"
    fi

    # Register the extension in settings.json by ABSOLUTE PATH, which is what
    # pi's `extensions` setting takes. Doing it here rather than with `pi -e`
    # on the tmux line covers EVERY pi invocation in this container, not only
    # the auto-started session — a sandbox you can step around by typing `pi`
    # in a second window is not one.
    #
    # Merged with node rather than rewritten: settings.json is yours, and it
    # already holds defaultProjectTrust, defaultTools, model choices and more.
    # node is guaranteed present (this is a node base image); jq is not.
    node -e '
      const fs = require("fs");
      const [file, dir] = [process.argv[1], process.argv[2]];
      let cfg = {};
      if (fs.existsSync(file)) {
        try { cfg = JSON.parse(fs.readFileSync(file, "utf8")); }
        catch (e) {
          console.error("   ⚠️  " + file + " is not valid JSON — leaving it alone.");
          console.error("      pi-sandbox is NOT registered. Fix the file and redeploy.");
          process.exit(3);
        }
      }
      if (!Array.isArray(cfg.extensions)) cfg.extensions = [];
      if (!cfg.extensions.includes(dir)) {
        cfg.extensions.push(dir);
        fs.writeFileSync(file, JSON.stringify(cfg, null, 2) + "\n");
        console.log("   🧩 Registered pi-sandbox in " + file);
      }
    ' "$PI_SETTINGS_JSON" "$PI_SANDBOX_DIR" && chown "$PUID:$PGID" "$PI_SETTINGS_JSON" 2>/dev/null || true

    echo "✅ pi-sandbox active (bubblewrap verified)."
else
    echo ""
    echo "⚠️  ───────────────────────────────────────────────────────────────" >&2
    echo "⚠️   pi-sandbox is NOT active. Pi is running UNSANDBOXED." >&2
    echo "⚠️" >&2
    echo "⚠️   $SANDBOX_WHY" >&2
    echo "⚠️" >&2
    echo "⚠️   bubblewrap needs unprivileged user namespaces, which the" >&2
    echo "⚠️   container runtime grants or withholds — this image cannot" >&2
    echo "⚠️   fix it. Pi still works; it just has no permission layer, so" >&2
    echo "⚠️   the container boundary and a scoped GH_TOKEN are again the" >&2
    echo "⚠️   only things limiting it." >&2
    echo "⚠️ ───────────────────────────────────────────────────────────────" >&2
    echo ""
fi

exec /usr/sbin/sshd -D -e
