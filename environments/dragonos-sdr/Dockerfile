# Using a stable, slim Debian base appropriate for Raspberry Pi (ARM64)
FROM debian:bookworm-slim

# Avoid prompts during installation
ENV DEBIAN_FRONTEND=noninteractive

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
    # ADS-B Aircraft Tracking
    dump1090-mutability \
    readsb \
    # Multi-protocol RF Decoder (433/868/915 MHz sensors, remotes)
    rtl-433 \
    # ACARS aircraft data-link messages
    acarsdec \
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
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Fix RTL-SDR Kernel Driver Conflict inside the container just in case
RUN echo "blacklist dvb_usb_rtl28xxu" > /etc/modprobe.d/blacklist-rtl.conf

# Inject a hybrid Entrypoint wrapper using a clean, unescaped Heredoc deployment strategy
RUN cat << 'EOF' > /usr/local/bin/sdr-menu.sh
#!/bin/bash

BOLD=$'\033[1m'
CYAN=$'\033[36m'
DIM=$'\033[2m'
RESET=$'\033[0m'

# Check if standard input is attached to an active terminal socket
if [ ! -t 0 ]; then
  echo "[DAEMON] Running in non-interactive pipeline context. Initializing background core engines safely..."
  exec tail -f /dev/null
fi

while true; do
  # Real dialog --treeview nesting (category headers at depth 0, tools
  # indented under them at depth 1) instead of a flat numbered list with
  # no grouping at all — same pattern as kali-pentest's own menu. Category
  # header tags ("hdr_*") are handled below by just looping back to
  # redraw, same as a real tool would return to the menu.
  CHOICE=$(dialog --clear --backtitle "DragonOS Pi - SDR Launcher Menu" \
                  --title " Select an SDR Tool " \
                  --treeview "Choose a tool to launch:" 36 80 28 \
                  hdr_info     "[Info]"                    off 0 \
                  1            "Environment info: data dirs, useful commands" off 1 \
                  hdr_recv     "[SDR Receivers]"            off 0 \
                  2            "GQRX — Graphical spectrum analyzer / FM/AM/SSB receiver" off 1 \
                  3            "GNU Radio — Visual signal processing flowgraph editor" off 1 \
                  hdr_rtlsdr   "[RTL-SDR Utilities]"        off 0 \
                  4            "rtl_test — Benchmark & verify RTL-SDR dongle" off 1 \
                  5            "rtl_fm — FM/AM/SSB demodulator to audio via aplay" off 1 \
                  6            "rtl_tcp — Network SDR server (connect from GQRX/SDR# remotely)" off 1 \
                  7            "rtl_power — Wideband spectrum power scan across a frequency range" off 1 \
                  hdr_hackrf   "[HackRF Utilities]"         off 0 \
                  8            "hackrf_info — Read HackRF firmware version & hardware registers" off 1 \
                  9            "hackrf_sweep — Fast full-spectrum scan (1 MHz - 6 GHz)" off 1 \
                  10           "hackrf_transfer — Receive or transmit raw IQ data to/from file" off 1 \
                  hdr_adsb     "[ADS-B Aircraft Tracking]"  off 0 \
                  11           "dump1090 — ADS-B aircraft tracker (1090 MHz, interactive table)" off 1 \
                  12           "readsb — ADS-B decoder with MLAT & web map (port 8080)" off 1 \
                  hdr_decoders "[Signal Decoders]"          off 0 \
                  13           "rtl_433 — Decode 433/868/915 MHz sensors, remotes & meters" off 1 \
                  14           "multimon-ng — Decode pagers, EAS weather alerts & DTMF from FM" off 1 \
                  15           "direwolf — APRS packet radio decoder / TNC (144.390/144.800 MHz)" off 1 \
                  16           "acarsdec — ACARS aircraft data-link messages (129-131 MHz)" off 1 \
                  hdr_sysutil  "[System Utilities]"         off 0 \
                  17           "SoapySDRUtil — Probe all connected SDR hardware (any vendor)" off 1 \
                  18           "lsusb — List physical USB connections on the host" off 1 \
                  hdr_session  "[Session]"                  off 0 \
                  19           "Bash Shell — Drop to a raw terminal inside the container" off 1 \
                  20           "Exit"                       off 1 \
                  3>&1 1>&2 2>&3)

  if [ $? -ne 0 ]; then
    # Cancel/ESC on the treeview itself — redraw rather than exiting the
    # whole session; only an explicit "Exit" selection (option 20 below)
    # should actually end this script and return to the host.
    continue
  fi

  clear
  case "$CHOICE" in
    hdr_*)
      # A category header row was selected — nothing to launch, redraw the tree.
      continue ;;
    1)
      cat <<INFOEOF | less -r
${BOLD}📡 DragonOS SDR — Environment Info${RESET}

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
      echo "Launching GQRX..."
      gqrx ;;
    3)
      echo "Launching GNU Radio Companion..."
      gnuradio-companion ;;
    4)
      echo "Testing RTL-SDR dongle..."
      rtl_test -t
      echo ""
      read -p "Press Enter to return to menu..." ;;
    5)
      read -p "Center frequency (e.g. 100.1M for 100.1 MHz FM): " freq
      echo "Demodulating $freq — piping audio to aplay. Press Ctrl+C to stop."
      rtl_fm -f "$freq" -M wbfm -s 200000 -r 48000 - 2>/dev/null | aplay -r 48000 -f S16_LE 2>/dev/null
      read -p "Press Enter to return to menu..." ;;
    6)
      read -p "Listen port [default 1234]: " port
      port=${port:-1234}
      echo "Starting RTL-TCP server on 0.0.0.0:$port"
      echo "Point GQRX or SDR# at this host:$port — press Ctrl+C to stop."
      rtl_tcp -a 0.0.0.0 -p "$port" ;;
    7)
      read -p "Start frequency (e.g. 88M): " start_freq
      read -p "End  frequency  (e.g. 108M): " end_freq
      echo "Scanning $start_freq:$end_freq — Ctrl+C to stop."
      rtl_power -f "$start_freq:$end_freq:100k" -g 50 -i 1 -1 /tmp/power_scan.csv
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
    10)
      dialog --title "HackRF Transfer" --menu "Mode:" 10 55 2 \
          "rx" "Receive IQ samples from RF to file" \
          "tx" "Transmit IQ samples from file to RF" 2>/tmp/hrf_mode
      hrf_mode=$(cat /tmp/hrf_mode 2>/dev/null)
      clear
      if [ "$hrf_mode" = "rx" ]; then
          read -p "Center frequency (e.g. 433.92M): " freq
          read -p "Sample rate in MHz (e.g. 2M):     " srate
          outfile="/workspace/capture_$(date +%Y%m%d_%H%M%S).iq"
          echo "Recording to $outfile — Ctrl+C to stop."
          hackrf_transfer -r "$outfile" -f "$freq" -s "$srate" -l 32 -g 16
      elif [ "$hrf_mode" = "tx" ]; then
          read -p "Path to IQ file to transmit: " iqfile
          read -p "Center frequency (e.g. 433.92M): " freq
          read -p "Sample rate in MHz (e.g. 2M):     " srate
          echo "Transmitting $iqfile at $freq — Ctrl+C to stop."
          hackrf_transfer -t "$iqfile" -f "$freq" -s "$srate" -x 47
      fi
      read -p "Press Enter to return to menu..." ;;
    11)
      echo "Starting dump1090 ADS-B receiver (interactive table view)..."
      echo "Listening on 1090 MHz for aircraft position broadcasts."
      echo "HTTP map available at http://localhost:8080 if the port is published."
      echo "Ctrl+C to stop."
      dump1090 --interactive --net --net-http-port 8080 --net-beast-output-port 30005
      read -p "Press Enter to return to menu..." ;;
    12)
      read -p "Your latitude  (optional, enables map range rings): " lat
      read -p "Your longitude (optional, enables map range rings): " lon
      args="--net --interactive"
      [ -n "$lat" ] && args="$args --lat $lat"
      [ -n "$lon" ] && args="$args --lon $lon"
      echo "Starting readsb — web map at http://localhost:8080 — Ctrl+C to stop."
      readsb $args
      read -p "Press Enter to return to menu..." ;;
    13)
      echo "Starting rtl_433 — decoding 433/868/915 MHz sensors, remotes, meters..."
      echo "Ctrl+C to stop."
      rtl_433
      read -p "Press Enter to return to menu..." ;;
    14)
      echo "Common frequencies: 152.240M (POCSAG pager), 162.400M (NOAA Weather/EAS)"
      read -p "Frequency to monitor: " freq
      echo "Decoding all digital modes from $freq — Ctrl+C to stop."
      rtl_fm -f "$freq" -s 22050 - 2>/dev/null | multimon-ng -t raw -a ALL -
      read -p "Press Enter to return to menu..." ;;
    15)
      dialog --title "direwolf APRS" --menu "Select APRS frequency:" 10 60 2 \
          "144390k" "144.390 MHz — North America" \
          "144800k" "144.800 MHz — Europe / rest of world" 2>/tmp/dw_freq
      dw_freq=$(cat /tmp/dw_freq 2>/dev/null)
      [ -z "$dw_freq" ] && dw_freq=144390k
      clear
      echo "Starting direwolf APRS decoder on ${dw_freq} — Ctrl+C to stop."
      rtl_fm -f "$dw_freq" -s 24000 - 2>/dev/null | direwolf -r 24000 -D 1 -
      read -p "Press Enter to return to menu..." ;;
    16)
      echo "ACARS frequencies: 129.125 130.025 130.450 131.550 MHz (scanning all)"
      echo "Ctrl+C to stop."
      acarsdec -r 0 129.125 130.025 130.450 131.550
      read -p "Press Enter to return to menu..." ;;
    17)
      echo "Probing connected SDR hardware via SoapySDR..."
      SoapySDRUtil --find
      echo ""
      read -p "Press Enter to return to menu..." ;;
    18)
      echo "USB devices attached to the host:"
      lsusb
      echo ""
      read -p "Press Enter to return to menu..." ;;
    19)
      echo "Dropping into Bash. Type 'exit' to return to the menu."
      /bin/bash ;;
    20)
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