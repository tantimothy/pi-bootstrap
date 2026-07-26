# Basilisk II (Mac OS 7/8, 68k) and SheepShaver (Mac OS 9, PowerPC) — the
# same emulator source and pinned revision this repo's own macintoshpi
# environment uses (github.com/kanjitalk755/macemu), but built against
# Debian's ordinary system SDL2 instead of macintoshpi's own custom-built
# one. macintoshpi's SDL2 is deliberately compiled with
# --disable-video-x11/--disable-video-wayland and only
# --enable-video-kmsdrm (full-screen, no window manager, by design — see
# that environment's own README) — nothing built against it can ever open
# an X display, so VNC access was never possible there without
# recompiling SDL2 itself. Debian's stock libsdl2-dev supports X11 out of
# the box, so pairing it with a headless Xvfb + x11vnc gets real VNC
# access with no emulator patching needed.
#
# Audio is disabled in both .cfg templates entrypoint.sh generates — VNC
# doesn't carry audio regardless, so there's nothing to gain from wiring
# up ALSA/device passthrough here.
#
# UNVERIFIED: this Dockerfile hasn't been build-tested against a real
# Docker daemon (none available in this development session) — flagged
# honestly rather than claimed working, per this repo's own documented
# convention for shipping an unverified assumption. The emulator source,
# pinned revision, ROM/HDD-image URLs, and .cfg shape below are all taken
# directly from macintoshpi's own build scripts, which ARE confirmed
# working on real Raspberry Pi hardware — only "build against system SDL2
# instead of a custom KMS-only one, and run headless under Xvfb" is new.
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential git autoconf automake libtool pkg-config \
        bison flex \
        libsdl2-dev libmpfr-dev libreadline-dev libasound2-dev \
        xvfb x11vnc \
        curl ca-certificates unzip gzip \
    && rm -rf /var/lib/apt/lists/*

# Same fork + pinned revision macintoshpi's own run.sh clones — confirmed
# working there on real Pi hardware; only how it's built differs here.
ARG MACEMU_REPO=https://github.com/kanjitalk755/macemu
ARG MACEMU_REVISION=44bf57e79151d11af6f2c30997f507313e8751cf
RUN git clone "$MACEMU_REPO" /usr/src/macemu \
    && cd /usr/src/macemu \
    && git checkout "$MACEMU_REVISION"

# Basilisk II — Mac OS 7/8 (68k).
RUN cd /usr/src/macemu/BasiliskII/src/Unix \
    && NO_CONFIGURE=1 ./autogen.sh \
    && ./configure --enable-sdl-audio --enable-sdl-framework \
                    --enable-sdl-video --disable-vosf \
                    --without-mon --without-esd --without-gtk \
    && make -j"$(nproc)" \
    && make install

# SheepShaver — Mac OS 9 (PowerPC). Same natmem-offset patch
# macintoshpi's own build applies for ARM hosts (SheepShaver's runtime
# NATMEM_OFFSET auto-detection doesn't behave correctly there) — fetched
# directly from macintoshpi's repo rather than duplicated here, so it
# stays in sync with upstream's own fix rather than drifting.
RUN cd /usr/src/macemu \
    && curl -fsSL -o /tmp/SheepShaver-RPi-fix-natmem-offset.patch \
       https://raw.githubusercontent.com/jaromaz/MacintoshPi/master/assets/SheepShaver-RPi-fix-natmem-offset.patch \
    && cd SheepShaver \
    && make links \
    && cd src/Unix \
    && patch -p4 < /tmp/SheepShaver-RPi-fix-natmem-offset.patch \
    && NO_CONFIGURE=1 ./autogen.sh \
    && ./configure --enable-sdl-audio --enable-sdl-video \
                    --enable-sdl-framework --without-gtk \
                    --without-mon --without-esd \
                    --enable-addressing=direct,0x10000000 \
    && make -j"$(nproc)" \
    && make install

RUN rm -rf /usr/src/macemu /tmp/SheepShaver-RPi-fix-natmem-offset.patch

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
