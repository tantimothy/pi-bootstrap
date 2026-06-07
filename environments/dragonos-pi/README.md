# DragonOS Core Container with Interactive Tool Menu

This repository provides an isolated, containerized environment mimicking **DragonOS** on a Raspberry Pi OS (64-bit) host. 

This environment features an automated TUI dashboard setup script that dynamically parses an `.env.example` file using `dialog`, presents a configuration interface, and writes an active `.env` file. A dedicated deployment wrapper script (`run.sh`) then dynamically sources these variables to launch the container with precise hardware, X11 video, and host audio passthrough.

The container includes a built-in **TUI (Text User Interface) launch menu** powered by `dialog` to seamlessly execute containerized software-defined radio (SDR) applications.

---

## Prerequisites

Before building or running the container, ensure your Raspberry Pi environment is ready:

1. **Hardware:** A Raspberry Pi (4 or 5 recommended) running **Raspberry Pi OS (64-bit / Bookworm)**.
2. **SDR Hardware:** An RTL-SDR dongle, HackRF, LimeSDR, or similar device.
3. **Docker Engine:** Installed and configured to run without `sudo`:
   ```bash
   sudo apt-get update
   sudo apt-get install docker.io -y
   sudo usermod -aG docker $USER
   ```

*(Note: Log out and log back in to apply group changes).*

---

## 1. Host Kernel Driver Fix (Crucial Step)

By default, Linux loads a digital TV tuner driver (`dvb_usb_rtl28xxu`) when an RTL-SDR is plugged in. This locks the hardware and prevents SDR applications from binding to it.

Run this command on your **host Raspberry Pi** to release the lock:
```bash
sudo echo "blacklist dvb_usb_rtl28xxu" | sudo tee /etc/modprobe.d/blacklist-rtl.conf
```
**Action Required**: Unplug and re-plug your SDR USB device after running the command above.

---

## 2. Configuration via the TUI Dashboard

This deployment relies on environmental variable abstraction. Do not hardcode paths or system configurations into the scripts.

1. Ensure the `.env.example` blueprint file is present in your workspace.
2. Run your automated dashboard script. The parsing engine will read the inline comments as a Legend, prompt you for adjustments, and generate your finalized `.env` file.

---

## 3. Building the Container

Clone this repository, navigate to the directory containing the `Dockerfile`, and build your modular Docker image:

```bash
docker build -t dragonos-pi .
```

---

## 4. Running the Container via `run.sh`

Instead of executing a static `docker run` block with hardcoded flags, use the accompanying deployment wrapper. It programmatically sources your tailored `.env` variables and triggers the container initialization.

Execute the script from your terminal:
```bash
chmod +x run.sh
./run.sh
```

### Dynamic Environment Variables Handled by `run.sh`:
- `DISPLAY`: Forwards your desktop X11 GUI server socket to render graphical applications.
- `HOST_USB_BUS_PATH`: Maps raw physical access to the host's USB routing matrix for hardware discovery.
- `HOST_SOUND_DEVICE`: Links physical sound architecture (`/dev/snd`) down to the container.
- `HOST_PULSE_NATIVE_SOCKET`: Passes the local PulseAudio or PipeWire server daemon stream directly to your speakers.
- `HOST_WORKSPACE_VOLUME`: Mounts a persistent directory on your host to prevent losing your captured signal data or flowgraphs when exiting.
- `CONTAINER_ENTRYPOINT_COMMAND`: Instructs the container whether to boot directly into the interactive selection menu, or drop cleanly into a raw shell.

---

## 5. Using the Interactive Menu

Upon launching, a blue screen interface will load in your terminal window. Use the **Up/Down Arrow Keys** to navigate, and press **Enter** to execute an action.

**Available Options:**
- **GQRX**: Opens a graphical spectrum analyzer. Perfect for listening to local FM radio frequencies, tracking bandwidth, and testing audio routing.
- **GNU Radio Companion**: Launches the robust block-diagram SDR workbench environment.
- **rtl_test**: Performs a quick diagnostic loop on plugged-in RTL-SDR hardware to check for missing packets/samples.
- **hackrf_info**: Probes and verifies the status/firmware version of any plugged-in HackRF hardware.
- **SoapySDRUtil**: Automatically discovers all compatible SDR hardware layers available to the system.
- **lsusb**: Standard hardware diagnostic to verify the Raspberry Pi actually sees your USB hardware device.
- **Bash Shell**: Escapes the menu and drops you into a raw shell inside the container environment. Type `exit` in the shell to go right back to the main menu.
- **Exit**: Cleanly shuts down and exits the container environment.

---

## 6. Verifying and Tuning In

Once inside the container through your selected application or the shell interface, verify your system pipelines:

**Step A: Check Hardware Access**
Run the discovery utility matching your hardware setup:
```bash
# General USB check
lsusb

# For RTL-SDR hardware
rtl_test

# For HackRF hardware
hackrf_info

# General SoapySDR discovery
SoapySDRUtil --find
```

**Step B: Listen to FM Radio (Audio & GUI Test)**
Launch GQRX to verify that both video and audio pipelines are bridging seamlessly to your host:
```bash
gqrx
```

1. Select your recognized SDR device from the initial drop-down menu and press **OK**.
2. Navigate to the **Receiver Options** panel on the right side.
3. Change the **Filter Mode** to **WFM** (Wideband FM, standard for commercial radio).
4. Dial into an active local FM radio frequency (e.g., `101.100 MHz`).
5. Click the **Play** button (triangle icon) in the top-left toolbar.
6. Increase the **Gain** slider under *Input Controls* until you see the signal waterfall, and adjust the **Volume** slider on the bottom right. You should hear the radio station playing directly through your Pi's speakers or headphones.

---

## Customizing and Extending

The included `Dockerfile` installs a foundational set of SDR software (`gnuradio`, `gqrx`, `soapysdr`, `rtl-sdr`, and `hackrf`). If your specific project requires extra tools commonly found in DragonOS (such as `dump1090` for ADS-B tracking or digital speech decoders), simply append them to the `apt-get install` stack in the `Dockerfile` and rebuild.