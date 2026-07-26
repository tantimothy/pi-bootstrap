#!/bin/bash
set -eo pipefail

# --- CONFIGURATION ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ -f "${SCRIPT_DIR}/.env" ]; then
    set -a
    source "${SCRIPT_DIR}/.env"
    set +a
fi

# Upstream (jaromaz/MacintoshPi) is a native host installer, not a Docker
# project — it compiles emulators, kernel modules and a launcher directly
# onto the running Raspberry Pi OS. There's nothing to containerize: SDL2
# needs direct framebuffer/KMS access, the NetDriver and CDEmu's vhba are
# real kernel modules built against the running kernel, and the launcher
# itself reboots the Pi to switch screen resolutions. So this is a run.sh
# environment on purpose, matching pi-barebones' "host-level provisioning,
# no container" pattern rather than dragonos-sdr/kali-pentest's Docker one.
MACINTOSHPI_REPO="${MACINTOSHPI_REPO:-https://github.com/jaromaz/MacintoshPi}"
MACINTOSHPI_REF="${MACINTOSHPI_REF:-}"
SRC_DIR="${SCRIPT_DIR}/src/MacintoshPi"
# Hardcoded inside upstream's assets/func.sh (BASE_DIR/CONF_DIR) — not
# something run.sh can redirect without patching upstream's own scripts,
# so info.yaml's install_dirs point at these same fixed paths.
BASE_DIR="/usr/share/macintoshpi"
CONF_DIR="/etc/macintoshpi"
# Marks that the ~2 hour build_all.sh has completed successfully at least
# once. Re-running build_all.sh unconditionally would re-download and
# overwrite every Mac OS hard disk image (see MacOS_version() in upstream's
# assets/func.sh — it does `rm -rf $MACOS_DIR` before every install), so
# FAST must not repeat it once deployed. Mirrors dragonos-sdr's own
# DEPLOYED_MARKER convention for a non-long-running, non-Docker environment.
DEPLOYED_MARKER="${SCRIPT_DIR}/.deployed"

POLICY="${REBUILD_POLICY:-FAST}"
echo "[POLICY] ${POLICY}"

if [ "$(uname -s)" != "Linux" ]; then
    echo "❌ MacintoshPi only runs on Raspberry Pi OS (Linux) — SDL2/KMS, systemd and apt are all required." >&2
    exit 1
fi

if [ "${POLICY}" = "STOP" ]; then
    echo "🛑 [STOP] Stopping the virtual modem service (Mac OS/BasiliskII/SheepShaver sessions are interactive foreground processes — nothing else runs in the background)..."
    sudo systemctl stop vmodem 2>/dev/null || true
    echo "✅ Virtual modem stopped. Run FAST or 'mac os9' (etc.) to resume."
    exit 0
fi

if [ "${POLICY}" = "TEARDOWN" ]; then
    echo "🗑️  [TEARDOWN] Stopping and disabling the virtual modem service..."
    sudo systemctl disable --now vmodem 2>/dev/null || true
    rm -f "${DEPLOYED_MARKER}"
    echo "✅ Stopped. Installed files under ${BASE_DIR} and ${CONF_DIR} are left in place — use WIPE to remove them."
    echo "   Run FAST to reinstall/re-verify everything from scratch."
    exit 0
fi

if [ "${POLICY}" = "FAST" ] && [ -f "${DEPLOYED_MARKER}" ]; then
    echo "✅ Already deployed (${DEPLOYED_MARKER} exists) — skipping the ~2 hour build_all.sh to avoid re-downloading and overwriting your Mac OS hard disk images."
    echo "   Use a custom action below to reinstall a single component, or CLEAN to rebuild everything from scratch (this WILL overwrite your Mac OS disks)."
    bash "$REPO_DIR/lib/run-install-desktop.sh" "$SCRIPT_DIR" >/dev/null 2>&1 || true
    bash "$REPO_DIR/lib/run-info.sh" "$SCRIPT_DIR" list
    exit 0
fi

if [ "${POLICY}" = "CLEAN" ]; then
    echo "⚠️  [CLEAN] This re-runs build_all.sh from scratch, which re-downloads and OVERWRITES every Mac OS hard disk image (macos7/8/9) under ${BASE_DIR}."
    echo "    Any software you installed inside those emulated systems will be lost. Back up first if you need it (INFO lists the paths)."
    rm -f "${DEPLOYED_MARKER}"
    rm -rf "${SRC_DIR}"
fi

if [ "${POLICY}" != "FAST" ] && [ "${POLICY}" != "CLEAN" ]; then
    echo "❌ [FATAL] Unknown policy: ${POLICY}" >&2
    exit 1
fi

echo ""
echo "⏳ This installs MacintoshPi (Basilisk II, SheepShaver, VICE, CDEmu, Virtual Modem, SyncTERM)."
echo "   Compiling everything from source takes roughly TWO HOURS on a Raspberry Pi and needs a"
echo "   stable internet connection plus a few hundred MB of downloads. Best run over SSH with"
echo "   'tmux' so it survives a dropped connection (see pi-barebones for a tmux setup)."
echo "   Officially supported boards: Pi Zero 2 W, 2, 2B, 3, 3A+, 3B, 3B+ (NOT Pi 4/5)."
echo ""

mkdir -p "$(dirname "${SRC_DIR}")"
# This point is only reached with no completed deploy yet (a fresh install,
# or after CLEAN/TEARDOWN wiped the marker) — always a clean shallow clone
# rather than trying to fast-forward an existing checkout in place, since
# there's no in-progress host state worth preserving across an interrupted
# run either way.
rm -rf "${SRC_DIR}"
echo "📥 Cloning ${MACINTOSHPI_REPO}..."
if [ -n "${MACINTOSHPI_REF}" ]; then
    git clone "${MACINTOSHPI_REPO}" "${SRC_DIR}"
    git -C "${SRC_DIR}" checkout "${MACINTOSHPI_REF}"
else
    git clone --depth 1 "${MACINTOSHPI_REPO}" "${SRC_DIR}"
fi

# Upstream's own scripts are what actually install packages/compile
# sources/write systemd units — this run.sh only orchestrates fetching them
# and tracking deploy state, never duplicates their logic. build_all.sh
# expects to run from inside the checkout (relative `cd ${APP}` and
# `source ../assets/func.sh` paths), and reads stdin directly for its own
# "update now?" prompt — run.sh is intentionally never wrapped in a `script`
# pty (see lib/deploy-lib.sh's deploy_environment), so that still works here.
cd "${SRC_DIR}"
chmod +x build_all.sh
find . -maxdepth 2 -name '*.sh' -exec chmod +x {} \;

echo "🚀 Running build_all.sh..."
./build_all.sh

touch "${DEPLOYED_MARKER}"
echo "✅ MacintoshPi installed. Launch a system with: mac os9   (or: mac os8 / mac os7)"

bash "$REPO_DIR/lib/run-install-desktop.sh" "$SCRIPT_DIR" >/dev/null 2>&1 || true
bash "$REPO_DIR/lib/run-info.sh" "$SCRIPT_DIR" list
