# DragonOS Core Container with Interactive Tool Menu

This repository provides an isolated, containerized environment mimicking **DragonOS** configurations on a Raspberry Pi OS (64-bit) host. 

This environment features an automated TUI dashboard setup script that dynamically parses an `.env.example` file using `dialog`, presents a unified configuration interface, and writes an uncommitted local `.env` file. A specialized, non-interactive deployment wrapper script (`run.sh`) then dynamically sources these variables to manage the container lifecycle based on central platform policies.

The container includes a built-in **TUI (Text User Interface) launch menu** powered by `dialog` to seamlessly execute containerized software-defined radio (SDR) applications.

---

## 🔧 Tools & Projects

| Tool | Link | Description |
|------|------|-------------|
| DragonOS | [cemaxecuter.com](https://cemaxecuter.com) | Ubuntu-based Linux distribution pre-loaded with SDR tools — this environment mirrors its toolset on Debian |
| GNU Radio | [gnuradio.org](https://www.gnuradio.org) | Visual signal processing framework — build and run SDR flowgraphs with a drag-and-drop GUI |
| GQRX | [gqrx.dk](https://www.gqrx.dk) | Graphical SDR receiver — spectrum waterfall display for FM/AM/SSB listening and spectrum analysis |
| RTL-SDR | [rtl-sdr.com](https://www.rtl-sdr.com) | Software-defined radio driver and utilities for low-cost DVB-T USB dongles repurposed as wideband receivers |
| HackRF | [greatscottgadgets.com/hackrf](https://greatscottgadgets.com/hackrf/) | Half-duplex SDR transceiver covering 1 MHz–6 GHz — tools for transmitting and receiving arbitrary RF |
| SoapySDR | [github.com/pothosware/SoapySDR](https://github.com/pothosware/SoapySDR) | Hardware-agnostic SDR abstraction layer — lets GNU Radio and other tools work with any SDR hardware |

---

## Prerequisites

Before building or running the container, ensure your Raspberry Pi environment is ready:

1. **Hardware:** A Raspberry Pi (4 or 5 recommended) running **Raspberry Pi OS (64-bit / Bookworm)**.
2. **SDR Hardware:** An RTL-SDR dongle, HackRF, LimeSDR, or similar device.
3. **Docker Engine:** Installed and configured to run without local `sudo`:
   ```bash
   sudo apt-get update
   sudo apt-get install docker.io -y
   sudo usermod -aG docker $USER
   ```

*(Note: Log out and log back in to apply group changes).*

---

## 1. Host Kernel Driver Fix (Crucial Step)

By default, Linux loads a digital TV tuner driver (`dvb_usb_rtl28xxu`) when an RTL-SDR is plugged in. This locks the physical hardware registers and prevents SDR applications from binding to the device.

Run this command on your **host Raspberry Pi** to release the lock:
```bash
sudo echo "blacklist dvb_usb_rtl28xxu" | sudo tee /etc/modprobe.d/blacklist-rtl.conf
```
**Action Required**: Unplug and re-plug your SDR USB device after running the command above to refresh the host kernel assignments.

---

## 2. Configuration via the TUI Dashboard

This deployment relies entirely on clean environmental variable abstraction. Do not hardcode static paths or system configurations into the execution scripts.

1. Ensure the `.env.example` blueprint file is present in your workspace folder layout.
2. Run your automated dashboard script. The parsing engine will read the inline metadata comments as a Legend layout, prompt you for configuration adjustments via interactive menus, and generate your finalized local `.env` file.

---

## 3. Building the Container

Clone this repository, navigate to the directory containing the `Dockerfile`, and build your modular Docker image:

```bash
docker build -t dragonos-pi .
```

---

## 4. Running the Container via `run.sh`

Instead of executing a static `docker run` block with hardcoded flags, use the accompanying deployment wrapper script. It programmatically sources your tailored `.env` variables, ensures safe permissions, respects system policies, and triggers container initialization.

Execute the script from your non-interactive or interactive pipeline terminal:
```bash
chmod +x run.sh
./run.sh
```

### Advanced Policy Engine Routing Logic:
- **The Container-Running Shortcut**: If `REBUILD_POLICY=FAST` and the container is actively running (`docker ps`), the script logs a bypass message and exits code `0` immediately to preserve runtime uptime and ongoing captures.
- **The Container-Stopped Shortcut**: If `REBUILD_POLICY=FAST` and the container exists but is *stopped* (and the local image cache is present), it issues a fast `docker start` sequence to preserve the system lifecycle state and any uncommitted data layer shifts, then exits code `0`.
- **Smart Compilation Branching**:
  - If `REBUILD_POLICY=CLEAN`, it forces an explicit image eviction (`docker rmi`) and runs a pristine, zero-cache compilation (`docker build --no-cache`).
  - If `REBUILD_POLICY=FAST` but the image layer is completely missing, it executes a standard compilation (`docker build`) *without* the `--no-cache` flag to maximize ARM architecture performance by utilizing cached base layers.

### Parent Pipeline Compatibility Features:
- **Strict Non-Interactive Execution**: To run smoothly within automated environment threads (like a background `curl | bash` stream), the script excludes all interactive flags (`-it`, `-t`, or `< /dev/tty`). It runs fully detached via `-d` governed under a long-term `--restart=unless-stopped` lifecycle strategy.
- **Inherited Engine Wrappers**: Avoids raw hardcoded docker commands by natively inheriting socket permission adjustments via the framework variable `DOCKER=${DOCKER_CMD:-docker}`.
- **Pre-emptive Volume Generation Constraint**: The script runs host-level `mkdir -p` validations on your targeted volume storage targets *before* invoking container runtime parameters. This prevents Docker from generating folders under root-ownership, ensuring you retain full read/write privileges over captured assets.

### Dynamic Environment Variables Handled by `run.sh`:
- `CONTAINER_NAME`: The unique identification string used to target and audit runtime containers.
- `DOCKER_IMAGE_TAG`: The target compiled image tracking tag mapped to your application layer.
- `DISPLAY`: Forwards your desktop X11 GUI server socket to render graphical applications.
- `HOST_USB_BUS_PATH`: Maps raw physical access to the host's USB routing matrix for hardware discovery.
- `HOST_SOUND_DEVICE`: Links physical sound architecture (`/dev/snd`) down to the container.
- `HOST_PULSE_NATIVE_SOCKET`: Passes the local PulseAudio or PipeWire server daemon stream directly to your speakers.
- `HOST_PULSE_COOKIE_PATH`: Maps the local binary sound credentials required to authorize client streams.
- `HOST_CAPTURES_PATH`: Mounts a persistent host directory for wireless security captures, IQ handshake loops, and radio dumps.
- `HOST_MSF_DATA_PATH`: Mounts a persistent host directory to retain custom workspace logs, flowgraphs, or exploit modules.
- `CONTAINER_ENTRYPOINT_COMMAND`: Instructs the container whether to boot directly into the interactive selection menu, or drop cleanly into a raw shell.

---

## 5. Using the Interactive Menu

Upon launching, a blue screen TUI will load in your terminal. Use the arrow keys to select an SDR tool and press Enter to launch it. Press `q` or select the exit option to return to the menu.

---

## 💾 Data Directories

Persistent data is stored on the host and survives container removal:

| Directory | Contents |
|-----------|---------|
| `./workspace/captures/` | SDR captures, signal recordings, IQ dumps, analysis outputs |
| `./workspace/msf_data/` | Metasploit Framework data — workspaces, loot, credentials |

**Back up before any destructive operation:**
```bash
cp -r environments/dragonos-sdr/workspace ~/backup/
```

---

## 🎛️ Deployment Policies

| Policy | Action |
|--------|--------|
| `FAST` | Start container if not running; reattach if already active |
| `STOP` | Pause container (resumable with FAST) |
| `TEARDOWN` | Stop + remove container; data directories untouched |
| `CLEAN` | Stop + remove + rebuild image from scratch (slow on ARM) |
| `INFO` | List data directories with sizes and useful commands |
| `WIPE` | Delete persisted data directories (irreversible — back up first) |

---

## 💡 Useful Commands

```bash
# Reattach to the SDR tool menu in a running container
docker exec -it sdr-dragonos-core /usr/local/bin/sdr-menu.sh

# Open a raw shell inside the container
docker exec -it sdr-dragonos-core bash

# View container logs
docker logs sdr-dragonos-core

# Browse SDR captures on the host
ls ./workspace/captures/

# List connected USB SDR devices on the host
lsusb | grep -i "rtl\|sdr\|hackrf\|lime"
```