# Vendored and fixed from cmiles74/docker-sheepshaver
# (https://github.com/cmiles74/docker-sheepshaver). SheepShaver needs GCC 4.6
# to build cleanly (newer GCCs hit ABI/compile errors against this old
# codebase) — the only realistic way to get that toolchain today is an EOL
# Debian release, so this deliberately stays on Wheezy rather than porting
# forward.
FROM debian:wheezy

ENV DEBIAN_FRONTEND=noninteractive
ENV GIT_SSL_NO_VERIFY=true

# Wheezy went EOL in 2016 and was pulled from the regular Debian mirrors —
# deb.debian.org 404s on it. archive.debian.org keeps EOL releases forever,
# but its Release files carry a Valid-Until timestamp from back when the
# suite was current, which apt refuses by default as "expired" — disabling
# that check is the standard, well-documented fix for building against any
# archived Debian/Ubuntu suite (jessie, wheezy, squeeze, ...), not something
# specific to SheepShaver.
RUN printf 'deb http://archive.debian.org/debian wheezy main\ndeb http://archive.debian.org/debian-security wheezy/updates main\n' > /etc/apt/sources.list \
    && echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until

RUN apt-get -y update
RUN apt-get -y install build-essential gcc-4.6 g++-4.6 \
    autotools-dev automake
RUN apt-get -y install --no-install-recommends x11-common \
    xserver-xorg-core xserver-xorg-input-all xserver-xorg-video-fbdev \
    libsdl1.2-dev pulseaudio pulseaudio-utils libgtk2.0-dev vim git ssh

# GCC 4.6 is required — see the FROM comment above.
RUN rm /usr/bin/gcc /usr/bin/gcov /usr/bin/gcc-ar /usr/bin/gcc-ranlib /usr/bin/gcc-nm /usr/bin/g++
RUN ln -s /usr/bin/gcc-4.6 /usr/bin/gcc \
    && ln -s /usr/bin/gcov-4.6 /usr/bin/gcov \
    && ln -s /usr/bin/g++-4.6 /usr/bin/g++

# Non-root user the emulator actually runs as
WORKDIR /root
RUN groupadd -r developer -g 1000 \
    && useradd -u 1000 -r -g developer -d /developer -c "Software Developer" developer \
    && usermod -a -G audio developer
COPY developer /developer
RUN chmod +x /developer/bin/* \
    && chown -R developer:developer /developer

# Mount point for ROM/disk/config — populated at `docker run` time by run.sh
VOLUME ["/data"]
COPY data /data
WORKDIR /data

USER developer

# Pin to a known-good macemu revision by default rather than tracking
# master unpinned (upstream's own Dockerfile clones master with no pin at
# all) — override MACEMU_REF at build time for a newer commit.
ARG MACEMU_REF=master
RUN mkdir -p /developer/src \
    && cd /developer/src \
    && git clone https://github.com/cebix/macemu.git \
    && cd macemu \
    && git checkout "${MACEMU_REF}"

RUN cd /developer/src/macemu/SheepShaver \
    && make links \
    && cd src/Unix \
    && NO_CONFIGURE=1 ./autogen.sh \
    && ./configure --enable-sdl-video --enable-sdl-audio --disable-vosf \
    && make \
    && strip SheepShaver

USER root
RUN cp /developer/src/macemu/SheepShaver/src/Unix/SheepShaver /usr/bin

USER developer
ENTRYPOINT ["/developer/bin/start-sheepshaver"]
