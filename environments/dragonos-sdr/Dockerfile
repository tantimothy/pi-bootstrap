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
  # Keep container persistently alive while waiting for raw hardware signal streams
  exec tail -f /dev/null
fi

# If a terminal TTY is present, jump straight into the interactive user TUI selection framework
while true; do
  CHOICE=$(dialog --clear --backtitle "DragonOS Pi - SDR Launcher Menu" \
                  --title " Select an SDR Tool " \
                  --menu "Choose a tool to launch (with descriptions):" 18 75 8 \
                  1 "GQRX (Graphical FM/AM Spectrum Analyzer)" \
                  2 "GNU Radio Companion (Visual Flowgraph Editor)" \
                  3 "rtl_test (Benchmark & verify RTL-SDR dongle)" \
                  4 "hackrf_info (Read HackRF hardware registers)" \
                  5 "SoapySDRUtil (Check connected SDR hardware matrix)" \
                  6 "lsusb (List physical USB hardware connections)" \
                  7 "Bash Shell (Standard terminal access)" \
                  8 "Exit" \
                  3>&1 1>&2 2>&3)

  # Check exit status code of the dialog selection frame (ESC / Cancel)
  if [ $? -ne 0 ]; then
    echo "Menu canceled or interrupted. Exiting..."
    break
  fi

  clear
  case "$CHOICE" in
    1) echo "Launching GQRX..."; gqrx ;; 
    2) echo "Launching GNU Radio Companion..."; gnuradio-companion ;; 
    3) echo "Running RTL-SDR hardware test..."; rtl_test -t; echo ""; read -p "Press Enter to return to menu..." ;; 
    4) echo "Reading HackRF details..."; hackrf_info; echo ""; read -p "Press Enter to return to menu..." ;; 
    5) echo "Probing hardware via SoapySDR..."; SoapySDRUtil --find; echo ""; read -p "Press Enter to return to menu..." ;; 
    6) echo "Listing Host-attached USB hardware..."; lsusb; echo ""; read -p "Press Enter to return to menu..." ;; 
    7) echo "Dropping into standard Bash Shell. Type 'exit' to return to the menu."; /bin/bash ;; 
    8|*) echo "Exiting DragonOS Container Framework Execution Layer..."; break ;;
  esac
done
EOF

# Grant execution rights cleanly over the launcher framework asset
RUN chmod +x /usr/local/bin/sdr-menu.sh

# Fallback workspace layout and execution target configuration
WORKDIR /workspace
CMD ["/usr/local/bin/sdr-menu.sh"]