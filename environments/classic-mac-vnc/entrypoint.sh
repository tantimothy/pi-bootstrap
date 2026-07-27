#!/bin/bash
# Fetches (once, cached under the bind-mounted /data) the ROM + hard-disk
# image for the selected classic Mac OS version, starts a headless X
# server + VNC server, then execs the matching emulator (Basilisk II for
# OS 7/8, 68k; SheepShaver for OS 9, PowerPC) as this container's own
# PID 1 — so if the emulator itself ever crashes, the container exits and
# docker-compose.yml's own restart: unless-stopped policy brings
# everything back fresh, Xvfb/x11vnc included, rather than the crash
# going unnoticed. (Backgrounding the critical process and leaving
# something harmless as PID 1 instead is the exact mistake behind a real,
# documented multi-day outage elsewhere in this repo — see
# docs/lessons-learned/nanoclaw-mnemon.md's entrypoint.sh entry — so this
# is deliberately built the other way around from the start.)
set -euo pipefail

MAC_OS_VERSION="${MAC_OS_VERSION:-8}"
SCREEN_WIDTH="${SCREEN_WIDTH:-800}"
SCREEN_HEIGHT="${SCREEN_HEIGHT:-600}"
DATA_DIR="/data/macos${MAC_OS_VERSION}"
mkdir -p "$DATA_DIR"

# ROM/model settings and which emulator binary handles this OS version —
# Basilisk II is a 68k emulator (Mac OS 7/8 only ran on 68k Macs);
# SheepShaver is PowerPC-only (Mac OS 9's minimum). Same ROM files and
# per-OS model settings macintoshpi's own macos7.sh/macos8.sh/macos9.sh
# use — confirmed working there on real hardware.
case "$MAC_OS_VERSION" in
    7)
        EMULATOR=BasiliskII
        ROM_URL="https://github.com/macmade/Macintosh-ROMs/raw/18e1d0a9756f8ae3b9c005a976d292d7cf0a6f14/Performa-630.ROM"
        ROM_FILE="Performa-630.ROM"
        RAMSIZE=67108864
        MODEL_LINES=$'modelid 5\ncpu 4\nfpu true'
        ;;
    8)
        EMULATOR=BasiliskII
        ROM_URL="https://github.com/macmade/Macintosh-ROMs/raw/main/Quadra-650.ROM"
        ROM_FILE="Quadra-650.ROM"
        RAMSIZE=67108864
        MODEL_LINES=$'modelid 5\ncpu 4\nfpu true'
        ;;
    9)
        EMULATOR=SheepShaver
        ROM_URL="https://smb4.s3.us-west-2.amazonaws.com/sheepshaver/apple_roms/newworld86.rom.zip"
        ROM_FILE="newworld86.rom"
        RAMSIZE=134217728
        MODEL_LINES=""
        ;;
    *)
        echo "❌ MAC_OS_VERSION must be 7, 8, or 9 (got '$MAC_OS_VERSION')." >&2
        exit 1
        ;;
esac

# ROM + hard-disk image — same sources macintoshpi's own build scripts
# use, fetched once here and cached under /data so a container
# recreate/redeploy doesn't re-download or reset disk state. Per-OS-
# version subdirectory (macos7/macos8/macos9) so switching
# MAC_OS_VERSION doesn't clobber another version's saved disk.
if [ ! -f "$DATA_DIR/$ROM_FILE" ]; then
    echo "📥 Fetching ROM for Mac OS $MAC_OS_VERSION..."
    if [ "$MAC_OS_VERSION" = "9" ]; then
        curl -fsSL --retry 3 -o "$DATA_DIR/newworld86.rom.zip" "$ROM_URL"
        unzip -o "$DATA_DIR/newworld86.rom.zip" -d "$DATA_DIR"
        rm -f "$DATA_DIR/newworld86.rom.zip"
    else
        # --insecure matches macintoshpi's own `wget --no-check-certificate`
        # for this exact ROM host.
        curl -fsSL --retry 3 --insecure -o "$DATA_DIR/$ROM_FILE" "$ROM_URL"
    fi
fi

if [ ! -f "$DATA_DIR/hdd.dsk" ]; then
    echo "📥 Fetching hard disk image for Mac OS $MAC_OS_VERSION (this can take a while)..."
    curl -fsSL --retry 3 -o "$DATA_DIR/hdd.dsk.gz" "https://homer-retro.space/appfiles/${MAC_OS_VERSION}/hdd.dsk.gz"
    gzip -d "$DATA_DIR/hdd.dsk.gz"
fi

# Same shape macintoshpi's own .cfg templates use, minus the KMS-specific
# "screen" mode (here it's a plain windowed X display sized to exactly
# fill the Xvfb screen below) and with sound/CD-ROM off — VNC carries no
# audio regardless, and there's no CDEmu here to back a virtual drive.
CFG="$DATA_DIR/macos${MAC_OS_VERSION}.cfg"
cat > "$CFG" <<EOF
rom    $DATA_DIR/$ROM_FILE
disk   $DATA_DIR/hdd.dsk
frameskip 2
ramsize $RAMSIZE
ether slirp
$MODEL_LINES
nosound true
nocdrom true
nogui false
jit false
jitfpu false
mousewheelmode 1
mousewheellines 3
ignoresegv true
idlewait true
screen win/${SCREEN_WIDTH}/${SCREEN_HEIGHT}
EOF

export DISPLAY=:99
export SDL_VIDEODRIVER=x11
echo "🖥️  Starting Xvfb on $DISPLAY (${SCREEN_WIDTH}x${SCREEN_HEIGHT})..."
Xvfb "$DISPLAY" -screen 0 "${SCREEN_WIDTH}x${SCREEN_HEIGHT}x24" &
for _ in $(seq 1 20); do
    [ -e "/tmp/.X11-unix/X99" ] && break
    sleep 0.5
done

if [ -n "${VNC_PASSWORD:-}" ]; then
    X11VNC_AUTH=(-passwd "$VNC_PASSWORD")
else
    echo "⚠️  VNC_PASSWORD is unset — this VNC server has NO password and is" >&2
    echo "   reachable by anyone who can reach VNC_PORT. Set VNC_PASSWORD in" >&2
    echo "   .env unless you've deliberately restricted access some other way." >&2
    X11VNC_AUTH=(-nopw)
fi

echo "🔌 Starting x11vnc..."
mkdir -p /data
x11vnc -display "$DISPLAY" -forever -shared "${X11VNC_AUTH[@]}" -rfbport 5900 -bg -o /data/x11vnc.log
for _ in $(seq 1 20); do
    grep -q "PORT=5900" /data/x11vnc.log 2>/dev/null && break
    sleep 0.5
done

echo "🍎 Starting $EMULATOR for Mac OS $MAC_OS_VERSION..."
exec "$EMULATOR" --config "$CFG"
