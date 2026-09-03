# Using a stable, slim Debian base appropriate for Raspberry Pi (ARM64)
FROM debian:bookworm-slim

# Avoid prompts during installation
ENV DEBIAN_FRONTEND=noninteractive

# dialog/ncurses must know that the terminal is UTF-8. Without this, the
# box-drawing branches and em dashes in the launcher are rendered as their
# individual high-bit bytes (for example, "~T~T" and "~@~T") under the
# default POSIX locale. Debian bookworm supplies C.UTF-8 in glibc, so this
# does not require generating or installing an additional locale.
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# Update and install core SDR tools, utilities, libraries, and dialog
RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake \
    git \
    build-essential \
    curl \
    wget \
    pkg-config \
    # Core SDR Drivers and Software
    rtl-sdr \
    librtlsdr-dev \
    hackrf \
    libhackrf-dev \
    soapysdr-tools \
    libsoapysdr-dev \
    gnuradio \
    gqrx-sdr \
    # ADS-B Aircraft Tracking (readsb is compiled from source below)
    dump1090-mutability \
    # Multi-protocol RF Decoder (433/868/915 MHz sensors, remotes)
    rtl-433 \
    # Terrestrial radio audio & digital mode decoding
    alsa-utils \
    sox \
    multimon-ng \
    # APRS / packet radio TNC
    direwolf \
    # Extra utilities & Dialog
    usbutils \
    procps \
    ca-certificates \
    pulseaudio-utils \
    dialog \
    less \
    # Build-time dependencies for the from-source block below (readsb,
    # libacars, acarsdec). cmake, git, build-essential, pkg-config and
    # librtlsdr-dev are already in the list above and cover the rest.
    libusb-1.0-0-dev \
    libncurses-dev \
    zlib1g-dev \
    libzstd-dev \
    libxml2-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# SoapySDR is only an abstraction layer: `SoapySDRUtil --find` reports "No
# devices found!" — even with a working RTL-SDR attached — unless a
# per-hardware module is installed beside it, and soapysdr-tools alone ships
# none. Confirmed live on a Pi with a dongle the other tools could see.
#
# The names are tried rather than pinned. Debian ABI-versions these packages
# (soapysdr0.8-module-rtlsdr under bookworm) and the unversioned alias is not
# guaranteed to exist in every suite, and could not be checked from the
# session that added this — packages.debian.org is unreachable behind its
# egress proxy. A hardcoded name that turned out not to exist would fail the
# entire image build, exactly as `readsb` and `acarsdec` originally did, so
# the fallback chain ends in a warning instead: a missing module costs menu
# tag I its output, not the image.
RUN apt-get update \
    && ( apt-get install -y --no-install-recommends soapysdr0.8-module-rtlsdr soapysdr0.8-module-hackrf \
         || apt-get install -y --no-install-recommends soapysdr-module-rtlsdr soapysdr-module-hackrf \
         || echo "WARNING: no SoapySDR hardware modules installed — 'SoapySDRUtil --find' (menu tag I) will report no devices. Every other tool talks to the hardware directly and is unaffected." ) \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# --- Tools with no Debian package: compiled from pinned upstream sources ---
# Neither readsb nor acarsdec is in the Debian bookworm archive, and naming
# them in the apt-get above failed the whole build with "Unable to locate
# package" (apt reports every missing name at once, then exits 100 — nothing
# after that line in the image ever gets built). Both are therefore built
# here instead. Each is pinned to an exact upstream ref: an unpinned clone
# would mean two builds of the same commit of this repo can produce
# different images, and there is no lockfile anywhere else to notice that.
# Sources are removed in the same layer they are built in, so only the
# installed binaries survive into the image.

# wiedehopf/readsb — the actively maintained dump1090 fork (MLAT, better
# decode performance). Its Makefile has no `install` target, so the two
# binaries `make` produces are copied by hand; `viewadsb` is a copy of
# `readsb` that starts in the terminal aircraft-table view.
ARG READSB_VERSION=v3.16.16
RUN git clone --depth 1 --branch "${READSB_VERSION}" https://github.com/wiedehopf/readsb.git /tmp/readsb \
    && make -C /tmp/readsb -j"$(nproc)" RTLSDR=yes \
    && install -m 0755 /tmp/readsb/readsb /tmp/readsb/viewadsb /usr/local/bin/ \
    && rm -rf /tmp/readsb

# libacars is optional for acarsdec, but without it acarsdec only prints the
# raw ACARS text — the ATS/CPDLC/ADS-C payloads carried inside those messages
# stay undecoded. acarsdec's CMakeLists finds it through pkg-config
# (libacars-2 >= 2.0.0), which is why it is installed, and `ldconfig` run,
# before acarsdec is configured below.
ARG LIBACARS_VERSION=v2.2.1
RUN git clone --depth 1 --branch "${LIBACARS_VERSION}" https://github.com/szpajder/libacars.git /tmp/libacars \
    && cmake -S /tmp/libacars -B /tmp/libacars/build -DCMAKE_INSTALL_PREFIX=/usr/local \
    && cmake --build /tmp/libacars/build -j"$(nproc)" \
    && cmake --install /tmp/libacars/build \
    && ldconfig \
    && rm -rf /tmp/libacars

# TLeconte/acarsdec. Pinned to a commit rather than a tag on purpose: the
# newest tag (acarsdec-3.7, 2022) predates the CMake build system this uses,
# and upstream then ended development at the commit below ("The End",
# 2025-07-31), so this pin is the project's final state, not a moving branch
# head. -Drtl=ON is what pulls in rtl.c/librtlsdr; with no SDR option set at
# all the build silently produces a binary that can only read from a file.
# Note that upstream's CMakeLists hardcodes `-Ofast -march=native`, so this
# one binary is tuned for whatever CPU built the image. That is exactly right
# for this repo (run.sh builds on the Pi that then runs it) but means the
# image is not safely copyable to an older/different CPU.
ARG ACARSDEC_COMMIT=339f63eb91a890cfe5b199ad70814cfe86702d1e
RUN git clone https://github.com/TLeconte/acarsdec.git /tmp/acarsdec \
    && git -C /tmp/acarsdec checkout --quiet "${ACARSDEC_COMMIT}" \
    && cmake -S /tmp/acarsdec -B /tmp/acarsdec/build -Drtl=ON -DCMAKE_INSTALL_PREFIX=/usr/local \
    && cmake --build /tmp/acarsdec/build -j"$(nproc)" \
    && cmake --install /tmp/acarsdec/build \
    && rm -rf /tmp/acarsdec

# Fix RTL-SDR Kernel Driver Conflict inside the container just in case
RUN echo "blacklist dvb_usb_rtl28xxu" > /etc/modprobe.d/blacklist-rtl.conf

# Inject a hybrid Entrypoint wrapper using a clean, unescaped Heredoc deployment strategy
RUN cat << 'EOF' > /usr/local/bin/sdr-menu.sh
#!/bin/bash

# Escape (0x1b) is also the first byte of every arrow/function-key
# sequence, so ncurses — which dialog is built on — waits ESCDELAY
# milliseconds after a lone Escape byte to see whether more of a sequence
# is still arriving. That default is a full 1000, which is why Esc in this
# menu would otherwise feel broken while Ctrl-C (an unambiguous single
# byte, turned into SIGINT by the tty itself) feels instant. Same guard as
# lib/locale-lib.sh applies on the host side and kali-pentest's
# entrypoint.sh in its own container, restated here rather than sourced:
# nothing under lib/ is copied into this image, and the host's environment
# does not cross the container boundary. 25ms rather than 0 so a "\e[A"
# whose bytes split across reads is still read as an arrow key and not as
# Escape followed by a literal "[A".
export ESCDELAY=${ESCDELAY:-25}

BOLD=$'\033[1m'
CYAN=$'\033[36m'
DIM=$'\033[2m'
RESET=$'\033[0m'

# --- RTL-SDR device selection ---------------------------------------------
#
# Every RTL-SDR tool below defaults to "device 0" when told nothing, and
# device 0 is a coin flip as soon as more than one dongle is attached: USB
# enumeration order is not stable across a reboot or a replug. That matters
# because the dongles are not interchangeable — a FlightAware Pro Stick Plus
# has a 1090 MHz SAW filter in front of its tuner, so it physically cannot
# hear ACARS, APRS or 433 MHz traffic, while an RTL-SDR Blog V3 has no LNA
# and wants a much higher gain on 1090 MHz than the FlightAware does. So the
# dongle is picked once per menu session and then passed explicitly to
# everything that opens one.
#
# Session state, not image state: nothing here is baked into the image or
# written to disk, so swapping dongles needs a new menu session (or tag H),
# never a rebuild.
SDR_DEV_INDEX=""
SDR_DEV_SERIAL=""
SDR_DEV_LABEL=""

# Lists attached dongles as "index|description" lines WITHOUT opening any of
# them. librtlsdr's verbose_device_search() prints the full device list
# before it tries to match its argument, so a string that cannot match any
# index, serial or name gets us the listing and then an exit before
# rtlsdr_open() is ever reached. Plain `rtl_test` with no -d would instead
# open device 0 and start sampling it, which fails outright whenever another
# tool already holds the dongle.
list_rtl_devices() {
  rtl_test -d __pi_bootstrap_device_list__ 2>&1 \
    | sed -n 's/^  \([0-9][0-9]*\):  \(.*\)$/\1|\2/p'
}

# Picks the dongle for this session. Pass "force" to always show the picker;
# without it a single attached dongle is selected silently, since there is
# nothing to choose between.
select_sdr_device() {
  force="${1:-}"
  devices=$(list_rtl_devices)

  count=0
  while IFS='|' read -r idx desc; do
    [ -n "$idx" ] || continue
    count=$((count + 1))
  done < <(printf '%s\n' "$devices")

  if [ "$count" -eq 0 ]; then
    dialog --title " No RTL-SDR device found " --msgbox \
      "No RTL-SDR dongle is visible inside this container.\n\nCheck that it is plugged in, that the host has dvb_usb_rtl28xxu blacklisted (see this environment's README), and that the container was started with --privileged and the USB bus mounted.\n\nHackRF tools and the GUI receivers do their own device selection and are unaffected." 15 74
    return 1
  fi

  if [ "$count" -eq 1 ] && [ "$force" != "force" ]; then
    choice=$(printf '%s\n' "$devices" | sed -n '1s/|.*$//p')
  else
    # Rebuilt into positional parameters rather than an array: this repo
    # targets bash 3.2 (macOS's shipped default), where "${arr[@]}" is fine
    # but the surrounding idioms are not, so "$@" keeps one convention.
    set --
    while IFS='|' read -r idx desc; do
      [ -n "$idx" ] || continue
      set -- "$@" "$idx" "$desc"
    done < <(printf '%s\n' "$devices")

    choice=$(dialog --clear --title " Select RTL-SDR device " \
                    --menu "Which dongle should the RTL-SDR tools use this session?" \
                    15 78 6 "$@" 3>&1 1>&2 2>&3) || return 1
    [ -n "$choice" ] || return 1
  fi

  SDR_DEV_INDEX="$choice"
  SDR_DEV_SERIAL=""
  SDR_DEV_LABEL="device $choice"
  while IFS='|' read -r idx desc; do
    [ "$idx" = "$choice" ] || continue
    SDR_DEV_LABEL="$idx: $desc"
    case "$desc" in *"SN: "*) SDR_DEV_SERIAL="${desc##*SN: }" ;; esac
  done < <(printf '%s\n' "$devices")

  # Address the dongle by serial wherever the tool accepts one: a serial
  # survives an unplug/replug within a session, an index does not. That only
  # holds if the serial is actually unique, and it often isn't — both an
  # RTL-SDR Blog V3 and a FlightAware Pro Stick leave the factory as
  # "00000001", so with two unprogrammed dongles attached a serial match
  # would quietly resolve to whichever one enumerated first. Fall back to the
  # index when the chosen serial is blank or shared. `rtl_eeprom -d <n> -s
  # <name>`, run once on the host, fixes it permanently.
  if [ -n "$SDR_DEV_SERIAL" ]; then
    same=0
    while IFS='|' read -r idx desc; do
      case "$desc" in
        *"SN: "*) [ "${desc##*SN: }" = "$SDR_DEV_SERIAL" ] && same=$((same + 1)) ;;
      esac
    done < <(printf '%s\n' "$devices")
    [ "$same" -gt 1 ] && SDR_DEV_SERIAL=""
  fi

  return 0
}

# Called by every tool that opens a dongle, so selection happens lazily on
# first use rather than at startup — the info, lsusb and shell entries need
# no radio at all, and GQRX and GNU Radio have their own device pickers.
require_sdr_device() {
  [ -n "$SDR_DEV_INDEX" ] && return 0
  select_sdr_device || return 1
  clear
  return 0
}

# The device argument for tools that take either form (all the rtl_* tools,
# readsb, acarsdec): the serial when we have a unique one, the index if not.
sdr_dev_arg() {
  if [ -n "$SDR_DEV_SERIAL" ]; then
    printf '%s' "$SDR_DEV_SERIAL"
  else
    printf '%s' "$SDR_DEV_INDEX"
  fi
}

# rtl_433 spells the same thing differently — a bare number is an index, a
# serial has to be prefixed with a colon.
sdr_dev_arg_rtl433() {
  if [ -n "$SDR_DEV_SERIAL" ]; then
    printf ':%s' "$SDR_DEV_SERIAL"
  else
    printf '%s' "$SDR_DEV_INDEX"
  fi
}

# --- Graphical (X11) tools -------------------------------------------------
#
# GQRX and GNU Radio Companion are the only X11 applications in this menu, and
# when they cannot reach a display they print their reason to stderr and exit
# straight away. Every other entry here pauses before returning to the menu;
# these two did not, so the loop's own `clear` wiped that reason off the screen
# before it could be read and the menu simply reappeared, looking like nothing
# had happened at all. Keep the output on screen, and dump the state that
# actually decides whether an X client in a container can reach the host's
# server — mounting the socket is only half of it, since the server also
# demands the session's MIT-MAGIC-COOKIE.
launch_gui_app() {
  binary="$1"
  label="$2"

  echo "Launching ${label} (DISPLAY=${DISPLAY:-<unset>})..."
  echo ""
  "$binary"
  rc=$?
  [ "$rc" -eq 0 ] && return 0

  echo ""
  echo "${BOLD}${label} exited with status ${rc}.${RESET}"
  echo "If the message above mentions a display, an X server, or a Qt 'xcb'"
  echo "platform plugin, this container cannot reach the host's X server."
  echo ""
  echo "${BOLD}Inside this container:${RESET}"
  printf '  DISPLAY      = %s\n' "${DISPLAY:-<unset>}"
  printf '  XAUTHORITY   = %s\n' "${XAUTHORITY:-<unset>}"
  if [ -d /tmp/.X11-unix ]; then
    printf '  X11 sockets  = %s\n' "$(ls /tmp/.X11-unix 2>/dev/null | tr '\n' ' ')"
  else
    printf '  X11 sockets  = /tmp/.X11-unix is not mounted\n'
  fi
  if [ -s /root/.Xauthority ]; then
    printf '  cookie file  = /root/.Xauthority present\n'
  else
    printf '  cookie file  = /root/.Xauthority missing or empty\n'
  fi
  echo ""
  echo "${BOLD}On the HOST, in the desktop session that owns that display:${RESET}"
  echo '  xhost +local:              # let local clients (this container) connect'
  echo '  echo "$DISPLAY $XAUTHORITY" # should match what is listed above'
  echo ""
  echo "Full walkthrough: 'Graphical tools' in environments/dragonos-sdr/README.md"
}

# Check if standard input is attached to an active terminal socket
if [ ! -t 0 ]; then
  echo "[DAEMON] Running in non-interactive pipeline context. Initializing background core engines safely..."
  exec tail -f /dev/null
fi

while true; do
  # Single flattened dialog --menu with manual tree-branch indentation
  # (├──/└──) baked into each leaf's item text, instead of --treeview —
  # same reasoning and pattern as kali-pentest's own menu (see that
  # environment's entrypoint.sh for the full explanation): --treeview's
  # rendering depends on the installed dialog build actually supporting
  # it, and a build that doesn't can silently fall back to something
  # resembling a checklist, with every row — including category headers —
  # showing a selectable "( )" marker that looks like multi-select even
  # though only one row is ever actually chosen (confirmed directly against
  # a real kali-rolling-based image). A plain --menu never renders a
  # per-row selector glyph at all, for any dialog build.
  #
  # Category header tags are the bare category word (info, recv, rtlsdr,
  # ...) — no "hdr_" prefix; the case statement below lists them
  # explicitly. dialog --menu has no "label-only, non-selectable" row type
  # either, so these stay selectable, but choosing one is a silent no-op
  # that just redraws (no popup).
  #
  # Leaf tags run 1-9, then continue A, B, C, ... rather than 10, 11, 12 —
  # every tag stays a single keystroke for dialog's own type-ahead.
  #
  # --default-item re-highlights whatever was last selected instead of
  # always resetting to the top of the list on redraw.
  CHOICE=$(dialog --clear --backtitle "DragonOS Pi - SDR Launcher Menu   |   RTL-SDR: ${SDR_DEV_LABEL:-none selected yet}" \
                  --title " Select an SDR Tool " \
                  --visit-items \
                  --default-item "${DEFAULT_ITEM:-1}" \
                  --menu "Choose a tool to launch (Cancel/Esc redraws this menu, it doesn't exit):" 32 82 22 \
                  info     "[Info]" \
                  1        " └── Environment info: data dirs, useful commands" \
                  recv     "[SDR Receivers]" \
                  2        " ├── GQRX — Graphical spectrum analyzer / FM/AM/SSB receiver" \
                  3        " └── GNU Radio — Visual signal processing flowgraph editor" \
                  rtlsdr   "[RTL-SDR Utilities]" \
                  4        " ├── rtl_test — Benchmark & verify RTL-SDR dongle" \
                  5        " ├── rtl_fm — FM/AM/SSB demodulator to audio via aplay" \
                  6        " ├── rtl_tcp — Network SDR server (connect from GQRX/SDR# remotely)" \
                  7        " └── rtl_power — Wideband spectrum power scan across a frequency range" \
                  hackrf   "[HackRF Utilities]" \
                  8        " ├── hackrf_info — Read HackRF firmware version & hardware registers" \
                  9        " ├── hackrf_sweep — Fast full-spectrum scan (1 MHz - 6 GHz)" \
                  A        " └── hackrf_transfer — Receive or transmit raw IQ data to/from file" \
                  adsb     "[ADS-B Aircraft Tracking]" \
                  B        " ├── dump1090 — ADS-B aircraft tracker (1090 MHz, interactive table)" \
                  C        " └── readsb — ADS-B decoder with MLAT & Beast/SBS network output" \
                  decoders "[Signal Decoders]" \
                  D        " ├── rtl_433 — Decode 433/868/915 MHz sensors, remotes & meters" \
                  E        " ├── multimon-ng — Decode pagers, EAS weather alerts & DTMF from FM" \
                  F        " ├── direwolf — APRS packet radio decoder / TNC (144.390/144.800 MHz)" \
                  G        " └── acarsdec — ACARS aircraft data-link messages (130-131.5 MHz)" \
                  sysutil  "[System Utilities]" \
                  H        " ├── Select RTL-SDR device — which dongle the tools above use" \
                  I        " ├── SoapySDRUtil — Probe all connected SDR hardware (any vendor)" \
                  J        " └── lsusb — List physical USB connections on the host" \
                  session  "[Session]" \
                  K        " ├── Bash Shell — Drop to a raw terminal inside the container" \
                  L        " └── Exit" \
                  3>&1 1>&2 2>&3)

  if [ $? -ne 0 ] || [ -z "$CHOICE" ]; then
    # Cancel/ESC on this, the top-level menu, has nowhere else to bounce
    # back to — same as picking "Exit" (tag K) explicitly, so treat it
    # the same way, matching how a nested dialog's own Cancel returns to
    # its caller (here, that caller is the host).
    clear
    echo "🚪 Detached (Cancel/Esc). Container remains running headlessly in the background."
    exit 0
  fi

  # Re-highlight whatever was just picked (header or leaf) on the next
  # redraw, instead of always resetting to the top of the list.
  DEFAULT_ITEM="$CHOICE"

  clear
  case "$CHOICE" in
    info|recv|rtlsdr|hackrf|adsb|decoders|sysutil|session)
      # A category header row — dialog --menu has no non-selectable row
      # type, so this is reachable; silently redraw.
      continue ;;
    1)
      cat <<INFOEOF | less -r
${BOLD}📡 DragonOS SDR — Environment Info${RESET}

${BOLD}RTL-SDR device in use this session${RESET}:
  ${CYAN}${SDR_DEV_LABEL:-none selected yet — chosen on first use, or from menu tag H}${RESET}

${BOLD}Data directories${RESET} (persisted on the host):
  ${CYAN}/workspace/captures${RESET}   ${DIM}—${RESET} SDR captures, signal recordings, analysis outputs
  ${CYAN}/workspace/msf_data${RESET}   ${DIM}—${RESET} Metasploit Framework data — workspace, loot, credentials

${BOLD}Useful commands${RESET} (run these on the HOST, not in this container):
  ${DIM}docker exec -it ${CONTAINER_NAME:-sdr-dragonos-core} /usr/local/bin/sdr-menu.sh${RESET}
  ${DIM}docker exec -it ${CONTAINER_NAME:-sdr-dragonos-core} bash${RESET}
  ${DIM}docker logs ${CONTAINER_NAME:-sdr-dragonos-core}${RESET}

Full tool reference and deployment policies (FAST/CLEAN/etc.):
  environments/dragonos-sdr/README.md in the pi-bootstrap repo.
INFOEOF
      ;;
    2)
      launch_gui_app gqrx "GQRX"
      read -p "Press Enter to return to menu..." ;;
    3)
      launch_gui_app gnuradio-companion "GNU Radio Companion"
      read -p "Press Enter to return to menu..." ;;
    4)
      require_sdr_device || continue
      # NOT -t. That flag is specifically the Elonics E4000 tuner benchmark,
      # and on any other tuner rtl_test prints "No E4000 tuner found,
      # aborting." and quits — which is every dongle this environment
      # realistically sees (R820T, R820T2, R828D). The two tests that do apply
      # are rtl_test's default sample-loss check and its -p PPM measurement.
      dialog --title "rtl_test" --menu "Which test?" 11 74 2 \
          "loss" "Dropped-sample check — is the USB link keeping up?" \
          "ppm"  "Oscillator error measurement in PPM (takes minutes)" 2>/tmp/rtl_test_mode
      rtl_test_mode=$(cat /tmp/rtl_test_mode 2>/dev/null)
      clear
      case "$rtl_test_mode" in
        loss)
          echo "Streaming the dongle's test pattern and reporting anything dropped."
          echo "No output means no lost samples. Ctrl+C to stop."
          rtl_test -d "$(sdr_dev_arg)"
          ;;
        ppm)
          echo "Measuring the oscillator's frequency error — one report every 10s."
          echo "Give it a few minutes to settle. Ctrl+C to stop."
          rtl_test -d "$(sdr_dev_arg)" -p
          ;;
        *)
          continue ;;
      esac
      echo ""
      read -p "Press Enter to return to menu..." ;;
    5)
      require_sdr_device || continue
      read -p "Center frequency (e.g. 100.1M for 100.1 MHz FM): " freq
      echo "Demodulating $freq — piping audio to aplay. Press Ctrl+C to stop."
      rtl_fm -d "$(sdr_dev_arg)" -f "$freq" -M wbfm -s 200000 -r 48000 - 2>/dev/null | aplay -r 48000 -f S16_LE 2>/dev/null
      read -p "Press Enter to return to menu..." ;;
    6)
      require_sdr_device || continue
      read -p "Listen port [default 1234]: " port
      port=${port:-1234}
      echo "Starting RTL-TCP server on 0.0.0.0:$port"
      echo "Point GQRX or SDR# at this host:$port — press Ctrl+C to stop."
      rtl_tcp -d "$(sdr_dev_arg)" -a 0.0.0.0 -p "$port" ;;
    7)
      require_sdr_device || continue
      read -p "Start frequency (e.g. 88M): " start_freq
      read -p "End  frequency  (e.g. 108M): " end_freq
      echo "Scanning $start_freq:$end_freq — Ctrl+C to stop."
      rtl_power -d "$(sdr_dev_arg)" -f "$start_freq:$end_freq:100k" -g 50 -i 1 -1 /tmp/power_scan.csv
      head -30 /tmp/power_scan.csv
      read -p "Press Enter to return to menu..." ;;
    8)
      echo "Reading HackRF hardware info..."
      hackrf_info
      echo ""
      read -p "Press Enter to return to menu..." ;;
    9)
      read -p "Min frequency in MHz [default 100]: " min_f
      min_f=${min_f:-100}
      read -p "Max frequency in MHz [default 500]: " max_f
      max_f=${max_f:-500}
      echo "Sweeping ${min_f}M–${max_f}M — Ctrl+C to stop."
      hackrf_sweep -f "${min_f}:${max_f}" -g 20 -l 32 2>&1 | head -50
      read -p "Press Enter to return to menu..." ;;
    A)
      dialog --title "HackRF Transfer" --menu "Mode:" 10 55 2 \
          "rx" "Receive IQ samples from RF to file" \
          "tx" "Transmit IQ samples from file to RF" 2>/tmp/hrf_mode
      hrf_mode=$(cat /tmp/hrf_mode 2>/dev/null)
      clear
      # hackrf_transfer wants plain Hz for -f and -s, and parses them with
      # strtod(), which stops at the first non-numeric character instead of
      # rejecting it: "433.92M" is read as 433 Hz and "2M" as 2 samples/sec,
      # with no error and no hint that anything is wrong. (The rtl_* tools do
      # understand k/M/G suffixes — that asymmetry is what made this look
      # right.) So prompt in MHz, which is what anyone actually has in mind,
      # and convert here.
      if [ "$hrf_mode" = "rx" ] || [ "$hrf_mode" = "tx" ]; then
          [ "$hrf_mode" = "tx" ] && read -p "Path to IQ file to transmit: " iqfile
          read -p "Center frequency in MHz (e.g. 433.92): " freq_mhz
          read -p "Sample rate in MHz (e.g. 2):           " srate_mhz
          freq=$(awk -v v="$freq_mhz" 'BEGIN { printf "%.0f", v * 1000000 }')
          srate=$(awk -v v="$srate_mhz" 'BEGIN { printf "%.0f", v * 1000000 }')
      fi
      if [ "$hrf_mode" = "rx" ]; then
          outfile="/workspace/capture_$(date +%Y%m%d_%H%M%S).iq"
          echo "Recording to $outfile at ${freq} Hz — Ctrl+C to stop."
          hackrf_transfer -r "$outfile" -f "$freq" -s "$srate" -l 32 -g 16
      elif [ "$hrf_mode" = "tx" ]; then
          echo "Transmitting $iqfile at ${freq} Hz — Ctrl+C to stop."
          hackrf_transfer -t "$iqfile" -f "$freq" -s "$srate" -x 47
      fi
      read -p "Press Enter to return to menu..." ;;
    B)
      require_sdr_device || continue
      # Debian's dump1090-mutability package installs its binary under that
      # full name (debian/rules renames it on install so the forks can
      # coexist), not as a plain "dump1090" — check both rather than assume.
      dump1090_bin=$(command -v dump1090-mutability || command -v dump1090)
      if [ -z "$dump1090_bin" ]; then
        echo "No dump1090 binary found in this image."
        read -p "Press Enter to return to menu..."
        continue
      fi
      echo "Starting dump1090 ADS-B receiver (interactive table view)..."
      echo "Listening on 1090 MHz for aircraft position broadcasts."
      # No --net-http-port and no --net-beast-output-port here, both learned
      # the hard way from a live run. Debian compiles dump1090-mutability
      # without ENABLE_WEBSERVER, so --net-http-port is parsed, warned about
      # and discarded — this build serves no map at all; Debian ships the
      # map's HTML at /usr/share/dump1090-mutability/html for a real web
      # server to serve instead. And the Beast output flag is --net-bo-port,
      # not --net-beast-output-port, which this build rejects outright with
      # "Unknown or not enough arguments". Plain --net already opens every
      # port named below on its default number, so neither needs restating.
      echo "Network output: Beast :30005, SBS/BaseStation :30003, raw :30002."
      echo "The container runs with --net=host, so those are the host's ports already."
      echo "This build has no built-in map — see the README's ADS-B section for one."
      echo "Ctrl+C to stop."
      # --device-index, not a serial: dump1090-mutability only understands
      # an index (readsb below takes either).
      "$dump1090_bin" --device-index "$SDR_DEV_INDEX" --interactive --net
      read -p "Press Enter to return to menu..." ;;
    C)
      require_sdr_device || continue
      # --device-type is not optional here: readsb deliberately ships no
      # default SDR (sdr.c leaves it SDR_NONE), so without it readsb starts
      # up perfectly happily and simply never looks at the dongle.
      #
      # readsb also has no built-in web server, unlike dump1090-mutability
      # above — a map means pointing tar1090 (or similar) at its --write-json
      # output. What it does offer straight away is the interactive table
      # plus network output for other tools to consume.
      read -p "Your latitude  (optional, enables range/distance stats): " lat
      read -p "Your longitude (optional, enables range/distance stats): " lon
      # --device has to come after --device-type: readsb parses SDR-specific
      # options against whichever type was named before them.
      args="--device-type rtlsdr --device $(sdr_dev_arg) --net --interactive"
      [ -n "$lat" ] && args="$args --lat $lat"
      [ -n "$lon" ] && args="$args --lon $lon"
      echo "Starting readsb — Beast output on :30005, SBS on :30003 — Ctrl+C to stop."
      readsb $args
      read -p "Press Enter to return to menu..." ;;
    D)
      require_sdr_device || continue
      echo "Starting rtl_433 — decoding 433/868/915 MHz sensors, remotes, meters..."
      echo "Ctrl+C to stop."
      rtl_433 -d "$(sdr_dev_arg_rtl433)"
      read -p "Press Enter to return to menu..." ;;
    E)
      require_sdr_device || continue
      echo "Common frequencies: 152.240M (POCSAG pager), 162.400M (NOAA Weather/EAS)"
      read -p "Frequency to monitor: " freq
      # multimon-ng has no "ALL" demodulator — passing one makes it print
      # `invalid mode "ALL"` followed by its usage and exit. Demodulators are
      # added one -a at a time, from the list it prints; these are the ones
      # this entry advertises. (-t raw is right: rtl_fm -s 22050 emits exactly
      # the 22050 Hz signed 16-bit mono stream multimon-ng expects.)
      echo "Decoding POCSAG, FLEX, EAS and DTMF from $freq — Ctrl+C to stop."
      rtl_fm -d "$(sdr_dev_arg)" -f "$freq" -s 22050 - 2>/dev/null \
        | multimon-ng -t raw -a POCSAG512 -a POCSAG1200 -a POCSAG2400 -a FLEX -a EAS -a DTMF -
      read -p "Press Enter to return to menu..." ;;
    F)
      require_sdr_device || continue
      dialog --title "direwolf APRS" --menu "Select APRS frequency:" 10 60 2 \
          "144390k" "144.390 MHz — North America" \
          "144800k" "144.800 MHz — Europe / rest of world" 2>/tmp/dw_freq
      dw_freq=$(cat /tmp/dw_freq 2>/dev/null)
      [ -z "$dw_freq" ] && dw_freq=144390k
      clear
      echo "Starting direwolf APRS decoder on ${dw_freq} — Ctrl+C to stop."
      rtl_fm -d "$(sdr_dev_arg)" -f "$dw_freq" -s 24000 - 2>/dev/null | direwolf -r 24000 -D 1 -
      read -p "Press Enter to return to menu..." ;;
    G)
      require_sdr_device || continue
      # acarsdec covers every frequency listed here from a single tuned
      # RTL-SDR, so they must all fit inside one sample-rate-wide window —
      # 1.95 MHz at its default 2 MS/s. The previous list opened at 129.125
      # and spanned 2.425 MHz, which acarsdec rejects outright ("Frequencies
      # too far apart", non-zero exit). These four are the common North
      # American ACARS channels and span 1.525 MHz.
      echo "ACARS frequencies: 130.025 130.450 131.125 131.550 MHz (scanning all)"
      echo "Ctrl+C to stop."
      acarsdec -r "$(sdr_dev_arg)" 130.025 130.450 131.125 131.550
      read -p "Press Enter to return to menu..." ;;
    H)
      # "force" so this always shows the picker, including with a single
      # dongle attached — picking it from here is an explicit request to
      # choose, unlike the lazy selection require_sdr_device does.
      select_sdr_device force
      continue ;;
    I)
      echo "Probing connected SDR hardware via SoapySDR..."
      SoapySDRUtil --find
      echo ""
      read -p "Press Enter to return to menu..." ;;
    J)
      echo "USB devices attached to the host:"
      lsusb
      echo ""
      read -p "Press Enter to return to menu..." ;;
    K)
      echo "Dropping into Bash. Type 'exit' to return to the menu."
      /bin/bash ;;
    L)
      echo "Exiting DragonOS SDR launcher."
      break ;;
    *)
      # Unrecognized/empty tag — the cancel check above already handles a
      # genuine ESC/Cancel, but treat anything else the same way
      # defensively: redraw rather than falling through to Exit.
      continue ;;
  esac
done
EOF

# Grant execution rights cleanly over the launcher framework asset
RUN chmod +x /usr/local/bin/sdr-menu.sh

# Fallback workspace layout and execution target configuration
WORKDIR /workspace
CMD ["/usr/local/bin/sdr-menu.sh"]
