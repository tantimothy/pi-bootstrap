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
    # Core SDR Drivers and Software \
    rtl-sdr \
    librtlsdr-dev \
    hackrf \
    libhackrf-dev \
    soapysdr-tools \
    libsoapysdr-dev \
    gnuradio \
    gqrx-sdr \
    # Extra utilities, Audio routing support & Dialog \
    usbutils \
    procps \
    ca-certificates \
    pulseaudio-utils \
    dialog \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Fix RTL-SDR Kernel Driver Conflict inside the container just in case
RUN echo "blacklist dvb_usb_rtl28xxu" > /etc/modprobe.d/blacklist-rtl.conf

# Inject the Menu Script directly into the image boundaries
RUN echo '#!/bin/bash\n\
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

# Fallback default execution structure if run manually without the run.sh script
WORKDIR /workspace
CMD ["/usr/local/bin/sdr-menu.sh"]