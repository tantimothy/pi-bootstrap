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
    # Extra utilities, Audio routing support & Dialog
    usbutils \
    procps \
    ca-certificates \
    pulseaudio-utils \
    dialog \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Fix RTL-SDR Kernel Driver Conflict inside the container just in case
RUN echo "blacklist dvb_usb_rtl28xxu" > /etc/modprobe.d/blacklist-rtl.conf

# Inject a hybrid Entrypoint wrapper using a clean, unescaped Heredoc deployment strategy
RUN cat << 'EOF' > /usr/local/bin/sdr-menu.sh
#!/bin/bash

# Check if standard input is attached to an active terminal socket
if [ ! -t 0 ]; then
  echo "[DAEMON] Running in non-interactive pipeline context. Initializing background core engines safely..."
  exec tail -f /dev/null
fi

while true; do
  CHOICE=$(dialog --clear --backtitle "DragonOS Pi - SDR Launcher Menu" \
                  --title " Select an SDR Tool " \
                  --menu "Choose a tool to launch:" 28 80 16 \
                  1  "GQRX              — Graphical spectrum analyzer / FM/AM/SSB receiver" \
                  2  "GNU Radio         — Visual signal processing flowgraph editor" \
                  3  "rtl_test          — Benchmark & verify RTL-SDR dongle" \
                  4  "rtl_fm            — FM/AM/SSB demodulator → audio output" \
                  5  "rtl_tcp           — Network SDR server (connect from GQRX/SDR# remotely)" \
                  6  "rtl_power         — Wideband spectrum power scan across a frequency range" \
                  7  "hackrf_info       — Read HackRF firmware version & hardware registers" \
                  8  "hackrf_sweep      — Fast full-spectrum scan (1 MHz – 6 GHz)" \
                  9  "hackrf_transfer   — Receive or transmit raw IQ data to/from file" \
                  10 "dump1090          — ADS-B aircraft tracker (1090 MHz, interactive table)" \
                  11 "readsb            — ADS-B decoder with MLAT & web map (port 8080)" \
                  12 "rtl_433           — Decode 433/868/915 MHz sensors, remotes & meters" \
                  13 "SoapySDRUtil      — Probe all connected SDR hardware (any vendor)" \
                  14 "lsusb             — List physical USB connections on the host" \
                  15 "Bash Shell        — Drop to a raw terminal inside the container" \
                  16 "Exit" \
                  3>&1 1>&2 2>&3)

  if [ $? -ne 0 ]; then
    echo "Menu canceled. Exiting..."
    break
  fi

  clear
  case "$CHOICE" in
    1)
      echo "Launching GQRX..."
      gqrx ;;
    2)
      echo "Launching GNU Radio Companion..."
      gnuradio-companion ;;
    3)
      echo "Testing RTL-SDR dongle..."
      rtl_test -t
      echo ""
      read -p "Press Enter to return to menu..." ;;
    4)
      read -p "Center frequency (e.g. 100.1M for 100.1 MHz FM): " freq
      echo "Demodulating $freq — piping audio to aplay. Press Ctrl+C to stop."
      rtl_fm -f "$freq" -M wbfm -s 200000 -r 48000 - 2>/dev/null | aplay -r 48000 -f S16_LE 2>/dev/null
      read -p "Press Enter to return to menu..." ;;
    5)
      read -p "Listen port [default 1234]: " port
      port=${port:-1234}
      echo "Starting RTL-TCP server on 0.0.0.0:$port"
      echo "Point GQRX or SDR# at this host:$port — press Ctrl+C to stop."
      rtl_tcp -a 0.0.0.0 -p "$port" ;;
    6)
      read -p "Start frequency (e.g. 88M): " start_freq
      read -p "End  frequency  (e.g. 108M): " end_freq
      echo "Scanning $start_freq:$end_freq — Ctrl+C to stop."
      rtl_power -f "$start_freq:$end_freq:100k" -g 50 -i 1 -1 /tmp/power_scan.csv
      head -30 /tmp/power_scan.csv
      read -p "Press Enter to return to menu..." ;;
    7)
      echo "Reading HackRF hardware info..."
      hackrf_info
      echo ""
      read -p "Press Enter to return to menu..." ;;
    8)
      read -p "Min frequency in MHz [default 100]: " min_f
      min_f=${min_f:-100}
      read -p "Max frequency in MHz [default 500]: " max_f
      max_f=${max_f:-500}
      echo "Sweeping ${min_f}M–${max_f}M — Ctrl+C to stop."
      hackrf_sweep -f "${min_f}:${max_f}" -g 20 -l 32 2>&1 | head -50
      read -p "Press Enter to return to menu..." ;;
    9)
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
    10)
      echo "Starting dump1090 ADS-B receiver (interactive table view)..."
      echo "Listening on 1090 MHz for aircraft position broadcasts."
      echo "HTTP map available at http://localhost:8080 if the port is published."
      echo "Ctrl+C to stop."
      dump1090 --interactive --net --net-http-port 8080 --net-beast-output-port 30005
      read -p "Press Enter to return to menu..." ;;
    11)
      read -p "Your latitude  (optional, enables map range rings): " lat
      read -p "Your longitude (optional, enables map range rings): " lon
      args="--net --interactive"
      [ -n "$lat" ] && args="$args --lat $lat"
      [ -n "$lon" ] && args="$args --lon $lon"
      echo "Starting readsb — web map at http://localhost:8080 — Ctrl+C to stop."
      readsb $args
      read -p "Press Enter to return to menu..." ;;
    12)
      echo "Starting rtl_433 — decoding 433/868/915 MHz sensors, remotes, meters..."
      echo "Ctrl+C to stop."
      rtl_433
      read -p "Press Enter to return to menu..." ;;
    13)
      echo "Probing connected SDR hardware via SoapySDR..."
      SoapySDRUtil --find
      echo ""
      read -p "Press Enter to return to menu..." ;;
    14)
      echo "USB devices attached to the host:"
      lsusb
      echo ""
      read -p "Press Enter to return to menu..." ;;
    15)
      echo "Dropping into Bash. Type 'exit' to return to the menu."
      /bin/bash ;;
    16|*)
      echo "Exiting DragonOS SDR launcher."
      break ;;
  esac
done
EOF

# Grant execution rights cleanly over the launcher framework asset
RUN chmod +x /usr/local/bin/sdr-menu.sh

# Fallback workspace layout and execution target configuration
WORKDIR /workspace
CMD ["/usr/local/bin/sdr-menu.sh"]