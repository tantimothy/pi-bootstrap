# DragonOS Core Container with Interactive Tool Menu

This repository provides an isolated, containerized environment mimicking **DragonOS** configurations on a Raspberry Pi OS (64-bit) host. 

This environment features an automated TUI dashboard setup script that dynamically parses an `.env.example` file using `dialog`, presents a unified configuration interface, and writes an uncommitted local `.env` file. A specialized, non-interactive deployment wrapper script (`run.sh`) then dynamically sources these variables to manage the container lifecycle based on central platform policies.

The container includes a built-in **TUI (Text User Interface) launch menu** powered by `dialog` to seamlessly execute containerized software-defined radio (SDR) applications.

---

## 🔧 Tools & Projects

Base image: [debian:bookworm-slim](https://hub.docker.com/_/debian) — additional SDR tools from the Debian/Kali package catalog can be installed with `apt-get install` inside the container. The following are pre-installed by the Dockerfile:

> **Note:** This container mirrors a subset of the [DragonOS](https://cemaxecuter.com) toolset. The full DragonOS distribution additionally includes SDR++ , CubicSDR, dump1090 (ADS-B), WSJT-X (FT8/FT4), Direwolf (APRS), gr-gsm (GSM), inspectrum, multimon-ng, rtl_433, and more — these can be added to the Dockerfile via `apt-get install`.

### Graphical Tools

| Tool | Link | Description |
|------|------|-------------|
| GQRX | [gqrx.dk](https://www.gqrx.dk) | Graphical SDR receiver — spectrum waterfall, FM/AM/SSB/CW demodulation, recording |
| GNU Radio Companion | [gnuradio.org](https://www.gnuradio.org) | Visual flowgraph editor — build and run signal processing pipelines with drag-and-drop blocks |

### RTL-SDR Utilities (`rtl-sdr` package)

| Binary | Description |
|--------|-------------|
| `rtl_test` | Benchmark and verify RTL-SDR dongle — tests sample rate, reports dropped samples |
| `rtl_fm` | FM/AM/SSB demodulator — pipes demodulated audio to stdout for playback via `aplay` or `sox` |
| `rtl_sdr` | Raw IQ data recorder — captures samples to file at a given frequency and sample rate |
| `rtl_tcp` | Network SDR server — streams raw IQ over TCP so remote clients (GQRX, SDR#) can use the dongle |
| `rtl_power` | Wideband spectrum power scanner — sweeps a frequency range and logs signal levels over time |
| `rtl_biast` | Bias-T control — enables 5V DC on the antenna port to power active antennas and LNAs |
| `rtl_eeprom` | EEPROM read/write — change dongle serial number, vendor/product strings, bias-T default |

### HackRF Utilities (`hackrf` package)

| Binary | Description |
|--------|-------------|
| `hackrf_info` | Read hardware registers, firmware version, serial number, and board revision |
| `hackrf_transfer` | Transmit or receive raw IQ data to/from file — the primary HackRF capture/replay tool |
| `hackrf_sweep` | Fast full-spectrum scanner — covers the HackRF's entire 1 MHz–6 GHz range at up to 8 GHz/s |
| `hackrf_debug` | Low-level hardware register inspection and debugging |
| `hackrf_operacake` | OperaCake antenna switch control — select antenna port programmatically |

### ADS-B Aircraft Tracking

Receives aircraft position broadcasts on **1090 MHz** — any RTL-SDR dongle can decode these.

| Tool | Link | Description |
|------|------|-------------|
| `dump1090` | [github.com/mutability/dump1090](https://github.com/mutability/dump1090) | ADS-B Mode S decoder — interactive terminal aircraft table + HTTP map on port 8080 |
| `readsb` | [github.com/wiedehopf/readsb](https://github.com/wiedehopf/readsb) | Modern dump1090 fork — adds MLAT support, better performance, optional lat/lon for range rings on the web map |

> **Note:** The web map (port 8080) requires the container to be started with `-p 8080:8080`. Add `"8080:8080"` to the ports section of the run config, or access the interactive terminal view without it.

### Multi-Protocol RF Decoding

| Tool | Link | Description |
|------|------|-------------|
| `rtl_433` | [github.com/merbanan/rtl_433](https://github.com/merbanan/rtl_433) | Decodes hundreds of 433/868/915 MHz devices — weather stations, door sensors, car tire pressure sensors, power meters, garage remotes |

### Terrestrial Radio & Digital Mode Decoding

| Package | Tool(s) | Description |
|---------|---------|-------------|
| `alsa-utils` | `aplay` | PCM audio playback — required for `rtl_fm \| aplay` to produce sound |
| `sox` | `sox`, `soxi`, `play` | Audio Swiss-army knife — sample-rate conversion, WAV recording, format bridging for rtl_fm pipelines |
| `multimon-ng` | `multimon-ng` | [github.com/EliasOenal/multimon-ng](https://github.com/EliasOenal/multimon-ng) — decodes POCSAG/FLEX pagers, EAS/SAME weather alerts, DTMF, and APRS audio tones from an rtl_fm pipe |

### APRS / Packet Radio

| Tool | Link | Description |
|------|------|-------------|
| `direwolf` | [github.com/wb2osz/direwolf](https://github.com/wb2osz/direwolf) | Software TNC — decodes APRS packets piped from `rtl_fm` on 144.390 MHz (NA) / 144.800 MHz (EU); also runs as a full iGate or digipeater |

### ACARS Aircraft Data Link

| Tool | Link | Description |
|------|------|-------------|
| `acarsdec` | [github.com/szpajder/acarsdec](https://github.com/szpajder/acarsdec) | Multi-channel ACARS decoder — decodes text messages (weather, gate assignments, ops) transmitted by commercial aircraft on 129.125 / 130.025 / 130.450 / 131.550 MHz |

### Hardware Abstraction

| Tool | Link | Description |
|------|------|-------------|
| SoapySDR | [github.com/pothosware/SoapySDR](https://github.com/pothosware/SoapySDR) | Hardware-agnostic SDR abstraction layer — `SoapySDRUtil --find` probes all connected devices regardless of manufacturer |

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
  - If `REBUILD_POLICY=CLEAN`, it runs a pristine, zero-cache compilation (`docker build --no-cache`) *first*, before touching any existing container. Only after that build succeeds does it stop/remove the previous container — a failed build now leaves the previous working container running instead of leaving nothing at all. (The build retags the image name onto the new image, leaving the old one dangling rather than deleting it.)
  - If `REBUILD_POLICY=FAST` but the image layer is completely missing, it executes a standard compilation (`docker build`) *without* the `--no-cache` flag to maximize ARM architecture performance by utilizing cached base layers.
- **Config Drift Detection**: A hash of the settings that feed the `docker run` invocation (USB bus path, sound device, X11/Pulse paths, entrypoint command, capture/data volume paths) is stored in `.container-config-hash` (gitignored, like `.deployed`) every time the container is launched. On a later `FAST` run, if any of those settings changed (e.g. you edited `.env`) since the existing container was created:
  - **Currently running** — you're only warned; your active session is never killed automatically. Run `TEARDOWN` then `FAST` (or `CLEAN`) to pick up the new config.
  - **Dormant (stopped but not removed)** — nothing is attached, so it's recreated automatically with the current settings instead of reusing the stale one.

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

| Option | Tool | What it does |
|:---|:---|:---|
| **1** | GQRX | Graphical spectrum analyzer — spectrum waterfall, FM/AM/SSB demodulation |
| **2** | GNU Radio Companion | Visual flowgraph editor for signal processing pipelines |
| **3** | rtl_test | Benchmark RTL-SDR dongle, test sample rates, report dropped samples |
| **4** | rtl_fm | FM/AM/SSB demodulator — prompts for frequency, pipes audio to `aplay` |
| **5** | rtl_tcp | Network SDR server — exposes the dongle over TCP for remote SDR clients |
| **6** | rtl_power | Wideband power scan — prompts for frequency range, logs signal levels |
| **7** | hackrf_info | Read HackRF firmware version, serial number, hardware registers |
| **8** | hackrf_sweep | Fast spectrum scan — prompts for MHz bounds, sweeps up to 8 GHz/s |
| **9** | hackrf_transfer | IQ capture/replay submenu — receive to file or transmit from file |
| **10** | dump1090 | ADS-B decoder — live aircraft table in terminal + HTTP map on port 8080 |
| **11** | readsb | ADS-B decoder with MLAT — prompts for lat/lon for web map range rings |
| **12** | rtl_433 | Decode 433/868/915 MHz devices — weather sensors, remotes, meters |
| **13** | multimon-ng | Digital mode decoder — prompts for frequency, decodes pagers/EAS/DTMF from rtl_fm pipe |
| **14** | direwolf | APRS decoder — submenu for NA (144.390 MHz) or EU (144.800 MHz) frequency |
| **15** | acarsdec | ACARS decoder — scans 129.125 / 130.025 / 130.450 / 131.550 MHz simultaneously |
| **16** | SoapySDRUtil | Probe all connected SDR hardware regardless of vendor |
| **17** | lsusb | List USB devices attached to the host |
| **18** | Bash Shell | Raw terminal inside the container — full access to all installed tools |
| **19** | Exit | Leave the menu (container keeps running in background) |

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
| `CLEAN` | Rebuild image from scratch (slow on ARM), then stop + remove the old container only once the build succeeds |
| `INFO` | List data directories with sizes and useful commands |
| `WIPE` | Delete `./workspace/captures/`, `./workspace/msf_data/`, and `./workspace/` |

---

## 🖥️ Desktop Integration

On a Pi with a desktop environment (LXDE, XFCE, GNOME), run once from the repo root:

```bash
./install-desktop-entries.sh
# or just this environment on its own:
./environments/dragonos-sdr/install-desktop.sh

# To remove entries (also in the deploy.sh menu as "Uninstall Desktop Entries"):
./install-desktop-entries.sh --uninstall
```

| Desktop entry | How it opens |
|:---|:---|
| **GQRX** | X11 socket passthrough — spectrum waterfall window appears directly on the Pi desktop |
| **GNU Radio Companion** | X11 socket passthrough — flowgraph editor window on the Pi desktop |
| **SDR Tools Menu** | Opens in your desktop's default terminal emulator |

The script only registers entries once you've actually launched this environment at least once — `run.sh` records that in a local `.deployed` marker file right before it starts the container. A cached `dragonos-pi` image on its own isn't enough, since an image built for a one-off test can otherwise linger indefinitely. Deploy this environment first, then re-run to install the entries; running `REBUILD_POLICY=TEARDOWN ./run.sh` clears the marker and the next install run removes the entries automatically.

X11 entries use `DISPLAY=:0`, which is correct for a directly connected Pi desktop. For SSH with X forwarding, edit the installed `.desktop` files and replace `:0` with your `$DISPLAY` value.

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