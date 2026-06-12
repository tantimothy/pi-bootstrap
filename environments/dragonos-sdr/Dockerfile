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

# Inject a hybrid Entrypoint wrapper that accommodates non-interactive pipeline daemons
RUN echo '#!/bin/bash\n\
# Check if standard input is attached to an active terminal socket\n\
if [ ! -t 0 ]; then\n\
  echo "[DAEMON] Running in non-interactive pipeline context. Initializing background core engines safely..."\n\
  # Keep container persistently alive while waiting for raw hardware signal streams\n\
  exec tail -f /dev/null\n\
fi\n\
\n\
# If a terminal TTY is present, jump straight into the interactive user TUI selection framework\n\
while true; do\n\
  CHOICE=$(dialog --clear --backtitle "DragonOS Pi - SDR Launcher Menu" \\\n\
                  --title " Select an SDR Tool " \\\n\
                  --menu "Choose a tool to launch (with descriptions):" 18 75 8 \\\n\
                  1 "GQRX (Graphical FM/AM Spectrum Analyzer)" \\\n\
                  2 "GNU Radio Companion (Visual Flowgraph Editor)" \\\n\
                  3 "rtl_test (Benchmark & verify RTL-SDR dongle)" \\\n\
                  4 "hackrf_info (Read HackRF hardware registers)" \\\n\
                  5 "SoapySDRUtil (Check connected SDR hardware matrix)" \\\n\
                  6 "lsusb (List physical USB hardware connections)" \\\n\
                  7 "Bash Shell (Standard terminal access)" \\\n\
                  8 "Exit" \n\
                  3>&1 1>&2 2>&3)\n\
\n\
  clear\n\
  case "$CHOICE" in\n\
    1) echo "Launching GQRX..."; gqrx ;; \n\
    2) echo "Launching GNU Radio Companion..."; gnuradio-companion ;; \n\
    3) echo "Running RTL-SDR hardware test..."; rtl_test -t; echo ""; read -p "Press Enter to return to menu..." ;; \n\
    4) echo "Reading HackRF details..."; hackrf_info; echo ""; read -p "Press Enter to return to menu..." ;; \n\
    5) echo "Probing hardware via SoapySDR..."; SoapySDRUtil --find; echo ""; read -p "Press Enter to return to menu..." ;; \n\
    6) echo "Listing Host-attached USB hardware..."; lsusb; echo ""; read -p "Press Enter to return to menu..." ;; \n\
    7) echo "Dropping into standard Bash Shell. Type '\''exit'\'' to return to the menu."; /bin/bash ;; \n\
    *) echo "Exiting DragonOS Container..."; break ;; \n\
  esac\n\
done' > /usr/local/bin/sdr-menu.sh && chmod +x /usr/local/bin/sdr-menu.sh

# Fallback workspace layout and execution target configuration
WORKDIR /workspace
CMD ["/usr/local/bin/sdr-menu.sh"]