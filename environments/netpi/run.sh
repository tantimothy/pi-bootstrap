#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status, 
# if an undefined variable is referenced, or if a piped command fails.
set -euo pipefail

# Define paths relative to the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
ENV_EXAMPLE="${SCRIPT_DIR}/.env.example"

echo "========================================================"
# Friendly name for your unified Pi-hole + WireGuard setup
echo "🚀 Initializing Pipin Stack Infrastructure..." 
echo "========================================================"

# ------------------------------------------------------------------------------
# 1. Dependency & Configuration Guard Clauses
# ------------------------------------------------------------------------------

# Ensure the .env file exists. If missing, it means the TUI script hasn't run.
if [ ! -f "$ENV_FILE" ]; then
	echo "❌ Error: Active '.env' file not found at ${ENV_FILE}." >&2
	echo "💡 Please execute your TUI setup configuration script first." >&2
	exit 1
fi

# Load variables into the shell context for validation checks
# (The xargs export trick safely exports standard env keys)
export $(grep -v '^#' "$ENV_FILE" | xargs)

# Validate that critical parameters are not blank strings
MISSING_VARS=()
[ -z "${FTLCONF_webserver_api_password:-}" ] && MISSING_VARS+=("FTLCONF_webserver_api_password")
[ -z "${WG_HOST:-}" ]                         && MISSING_VARS+=("WG_HOST")
[ -z "${PASSWORD_HASH:-}" ]                  && MISSING_VARS+=("PASSWORD_HASH")

if [ ${#MISSING_VARS[@]} -ne 0 ]; then
	echo "❌ Error: The following mandatory variables are empty in your .env file:" >&2
	for var in "${MISSING_VARS[@]}"; do
		echo "   - $var" >&2
	done
	echo "💡 Please re-run your setup script or populate these fields manually." >&2
	exit 1
fi

# ------------------------------------------------------------------------------
# 2. Host-Level Environment Pre-Checks
# ------------------------------------------------------------------------------

echo "🔍 Running system runtime pre-checks..."

# Check if port 53 is being hogged by a host resolver (like systemd-resolved)
if lsof -i :53 >/dev/null 2>&1; then
	echo "⚠️ Warning: Local port 53 is already occupied." >&2
	echo "   If this is systemd-resolved, ensure you have disabled the DNSStubListener." >&2
	# Optional: exit 1 here if you want to explicitly block deployment on bind failures
fi

# Ensure Wireguard kernel module is present or accessible if system demands it
if ! lsmod | grep -q wireguard && [ ! -d /lib/modules ]; then
	echo "ℹ