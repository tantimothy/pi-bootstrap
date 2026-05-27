# DragonOS Core Container with Interactive Tool Menu

This repository provides an isolated, containerized environment mimicking **DragonOS** on a Raspberry Pi OS (64-bit) host. 

This version includes a **TUI (Text User Interface) launch menu** powered by `dialog`. When you run the container, it will present an interactive menu explaining what each tool does and allowing you to load them instantly while handling background USB hardware mapping, graphical interface mapping, and native audio loops.

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

_(Note: Log out and log back in to apply group changes)._

1. **Host Kernel Driver Fix (Crucial Step)**
By default, Linux loads a digital TV tuner driver (_dvb_usb_rtl28xxu_) when an RTL-SDR is plugged in. This locks the hardware and prevents SDR applications from binding to it.
Run this command on your host Raspberry Pi to release the lock:
```bash
sudo echo "blacklist dvb_usb_rtl28xxu" | sudo tee /etc/modprobe.d/blacklist-rtl.conf
```
**Action Required**: Unplug and re-plug your SDR USB device after running the command above.

2. **Building the Container**

Clone this repository, navigate to the directory containing the `Dockerfile`, and build the Docker image:

```bash
docker build -t dragonos-pi .

```

3. **Running the Container**

To launch the interactive selection menu with full hardware pass-through, GUI rendering, and audio server integration, run the following command:

```bash
docker run -it \
  --privileged \
  -v /dev/bus/usb:/dev/bus/usb \
  -e DISPLAY=$DISPLAY \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  --net=host \
  --device /dev/snd \
  -e PULSE_SERVER=unix:${XDG_RUNTIME_DIR}/pulse/native \
  -v ${XDG_RUNTIME_DIR}/pulse/native:${XDG_RUNTIME_DIR}/pulse/native \
  -v ~/.config/pulse/cookie:/root/.config/pulse/cookie \
  --name my-dragonos \
  --rm \
  dragonos-pi
```

**Note on flags**: The `--rm` flag automatically cleans up the container instance when you choose "Exit" from the menu. Remove it if you want the container to persist.

**Argument Breakdown:**
 - `--privileged` & `-v /dev/bus/usb...`: Grants the container raw access to the physical USB bus where your SDR is connected.
 - `-e DISPLAY` & `-v /tmp/.X11-unix...`: Forwards the X11 display socket so GUI applications inside the container render cleanly on your desktop.
 - `--device /dev/snd`: Passes physical sound devices to the container environment.
 - `-e PULSE_SERVER...` & volume maps: Securely links the host's PulseAudio/PipeWire daemon to the container so you can hear decoded audio natively.

4. **Using the Interactive Menu**
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
 
## Verifying and Tuning In
Once inside the interactive terminal of your new container, test that everything is working perfectly.

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
6. Increase the **Gain** slider under _Input Controls_ until you see the signal waterfall, and adjust the **Volume** slider on the bottom right. You should hear the radio station playing directly through your Pi's speakers or headphones.

## Customizing and Extending
The included `Dockerfile` installs a foundational set of SDR software (`gnuradio`, `gqrx`, `soapysdr`, `rtl-sdr`, and `hackrf`). If your specific project requires extra tools commonly found in DragonOS (such as `dump1090`, `gqrx`, or digital speech decoders), simply append them to the `apt-get install` stack in the `Dockerfile` and rebuild.
