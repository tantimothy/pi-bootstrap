#!/usr/bin/env bash
# Run by lib/deploy-lib.sh's shared compose dispatch before `docker compose`
# ever touches anything (FAST/CLEAN only), with cwd already this
# environment's own directory.
#
# Two jobs, both of which have to happen BEFORE the container starts.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
fi

# ── 1. The data directory has to exist, owned by the right user ──────────
#
# Docker will happily create a missing bind-mount source, but it creates it
# ROOT-OWNED. The image remaps its internal hermes user to HERMES_UID/GID and
# then drops to that user, so a root-owned /opt/data means the agent cannot
# write its own memories, skills or config — and the failure surfaces much
# later, as Hermes behaving oddly rather than as a mount error.
#
# Unlike claude-cli's pre-deploy.sh this is a DIRECTORY, not a single file,
# so none of the OrbStack file-vs-directory trouble applies. It is here for
# ownership.
HERMES_DATA_PATH="${HERMES_DATA_PATH:-$HOME/.hermes}"
# Expand a leading ~ the way .env readers do not.
case "$HERMES_DATA_PATH" in
    "~/"*) HERMES_DATA_PATH="$HOME/${HERMES_DATA_PATH#\~/}" ;;
    "~")   HERMES_DATA_PATH="$HOME" ;;
esac

if [ ! -d "$HERMES_DATA_PATH" ]; then
    echo "   📁 Creating $HERMES_DATA_PATH"
    mkdir -p "$HERMES_DATA_PATH"
fi

# ── 2. Refuse to publish an unauthenticated dashboard ────────────────────
#
# This is not defensive over-engineering. Upstream removed its own
# `--insecure` escape hatch after an unauthenticated public dashboard was
# the entry point for the June 2026 MCP-config persistence campaign:
# internet scanners reached exposed dashboards and drove the agent into
# planting an SSH-key backdoor.
#
# Hermes itself now fails closed on a non-loopback bind with no auth
# provider — but it fails closed INSIDE the container, as a dashboard that
# silently never comes up. Checking here turns that into a deploy-time
# message naming the missing variable.
#
# The dashboard always binds 0.0.0.0 inside the container (it must, or a
# published port would be unreachable), so the container-side bind never
# counts as loopback and an auth provider is always required.
if [ "${HERMES_DASHBOARD:-}" = "1" ] || [ "${HERMES_DASHBOARD:-}" = "true" ] || [ "${HERMES_DASHBOARD:-}" = "yes" ]; then
    HAVE_AUTH=0
    if [ -n "${HERMES_DASHBOARD_BASIC_AUTH_USERNAME:-}" ] && [ -n "${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD:-}" ]; then
        HAVE_AUTH=1
    fi
    [ -n "${HERMES_DASHBOARD_OAUTH_CLIENT_ID:-}" ] && HAVE_AUTH=1
    if [ -n "${HERMES_DASHBOARD_OIDC_ISSUER:-}" ] && [ -n "${HERMES_DASHBOARD_OIDC_CLIENT_ID:-}" ]; then
        HAVE_AUTH=1
    fi

    if [ "$HAVE_AUTH" -eq 0 ]; then
        echo "❌ HERMES_DASHBOARD is on, but no dashboard auth provider is configured." >&2
        echo "" >&2
        echo "   The dashboard drives a real agent — it can read every credential in" >&2
        echo "   the data directory and run commands. Upstream removed its own" >&2
        echo "   --insecure flag after an unauthenticated public dashboard was the" >&2
        echo "   entry point for a real compromise campaign." >&2
        echo "" >&2
        echo "   Pick ONE in this environment's .env:" >&2
        echo "     HERMES_DASHBOARD_BASIC_AUTH_USERNAME + _PASSWORD   (trusted LAN/VPN)" >&2
        echo "     HERMES_DASHBOARD_OAUTH_CLIENT_ID                   (Nous Portal)" >&2
        echo "     HERMES_DASHBOARD_OIDC_ISSUER + _CLIENT_ID          (your own IdP)" >&2
        echo "" >&2
        echo "   Or leave HERMES_DASHBOARD unset and reach it over an SSH tunnel:" >&2
        echo "     ssh -L 9119:localhost:9119 <host>" >&2
        exit 1
    fi

    if [ "${HERMES_BIND_ADDRESS:-127.0.0.1}" != "127.0.0.1" ] \
       && [ -z "${HERMES_DASHBOARD_OAUTH_CLIENT_ID:-}" ] \
       && [ -z "${HERMES_DASHBOARD_OIDC_ISSUER:-}" ]; then
        echo "   ⚠️  HERMES_BIND_ADDRESS=${HERMES_BIND_ADDRESS} publishes the dashboard beyond" >&2
        echo "      this host's loopback, with username/password auth. Upstream is" >&2
        echo "      explicit that the basic provider is 'not suitable for direct" >&2
        echo "      public-internet exposure' — trusted LAN or VPN only." >&2
    fi

    if [ -z "${HERMES_DASHBOARD_BASIC_AUTH_SECRET:-}" ] \
       && [ -n "${HERMES_DASHBOARD_BASIC_AUTH_USERNAME:-}" ]; then
        echo "   ℹ️  HERMES_DASHBOARD_BASIC_AUTH_SECRET is unset — dashboard sessions"
        echo "      will not survive a container restart. Generate one with:"
        echo "        openssl rand -hex 32"
    fi
fi

# ── 3. First run needs the setup wizard, which this cannot do for you ────
#
# `hermes setup` is interactive and writes API keys into the data
# directory's own .env. Saying so here beats a container that starts,
# supervises a gateway with no provider configured, and looks fine.
if [ ! -f "$HERMES_DATA_PATH/.env" ] && [ ! -f "$HERMES_DATA_PATH/config.yaml" ]; then
    echo ""
    echo "   ℹ️  $HERMES_DATA_PATH has no .env or config.yaml yet."
    echo "      Hermes needs its interactive setup wizard once before the gateway"
    echo "      has anything to do. After this deploy, run:"
    echo ""
    echo "        docker run -it --rm -v \"$HERMES_DATA_PATH:/opt/data\" \\"
    echo "          nousresearch/hermes-agent:${HERMES_IMAGE_TAG:-latest} setup"
    echo ""
fi
