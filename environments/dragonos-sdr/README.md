# DragonOS Core Container with Interactive Tool Menu

This repository provides an isolated, containerized environment mimicking **DragonOS** configurations on a Raspberry Pi OS (64-bit) host. 

This environment features an automated TUI dashboard setup script that dynamically parses an `.env.example` file using `dialog`, presents a unified configuration interface, and writes an uncommitted local `.env` file. A specialized, non-interactive deployment wrapper script (`run.sh`) then dynamically sources these variables to manage the container lifecycle based on central platform policies.

The container includes a built-in **TUI (Text User Interface) launch menu** powered by `dialog` to seamlessly execute containerized software-defined radio (SDR) applications.

---

## ⚙️ Why This Needs a Custom `run.sh`

`deploy.sh` can deploy a bare `Dockerfile` environment generically (build the image, `docker run` it) without any `run.sh` at all — but only with a hardcoded `-p 80:80` on the default bridge network, no extra flags. This environment needs several things that generic fallback structurally cannot express:

- **`--privileged` and `--device "${HOST_SOUND_DEVICE}"`** — direct RTL-SDR/HackRF USB and `/dev/snd` audio hardware passthrough from *this specific* Pi.
- **`--net=host`** — required for tools like `rtl_tcp` (network SDR server) and any TCP/UDP listeners the menu launches.
- **X11 (`HOST_X11_UNIX_PATH`) and PulseAudio (`HOST_PULSE_NATIVE_SOCKET`, `HOST_PULSE_COOKIE_PATH`) socket forwarding** — lets GUI tools (GQRX, GNU Radio Companion) render a window and play audio on the host's own display/speakers, not just run headless.
- **Config-drift fingerprinting** — hashes the host-specific settings above so a `FAST` reattach never silently uses stale USB/audio/display paths after you edit `.env`.
- **The `.deployed` marker** — the container runs with `--rm`, so no lingering container/image state proves it was ever launched; `desktop-entries.yaml`'s `deployed_check` reads this marker instead.
- **TTY handling for the interactive menu** — `exec < /dev/tty` before `docker run -it` so the script still works when invoked through a non-interactive pipe (e.g. `curl | bash`).

None of this is expressible via `docker-compose.yml` either (Compose has no per-service passthrough for the host's PulseAudio cookie file or a live USB-drift hash), so a custom `run.sh` is the only fit.

---

## 🔧 Tools & Projects

Base image: [debian:bookworm-slim](https://hub.docker.com/_/debian) — additional SDR tools from the Debian package catalog can be installed with `apt-get install` inside the container. The following are pre-installed by the Dockerfile:

> **Note:** everything below comes from `apt` except **readsb** and **acarsdec**, which have no Debian package at all — the Dockerfile compiles those (plus `libacars`) from pinned upstream sources. See [Tools built from source](#tools-built-from-source) for the pins and what to change when bumping one.

> **Note:** This container mirrors a subset of the [DragonOS](https://cemaxecuter.com) toolset. The full DragonOS distribution additionally includes SDR++ , CubicSDR, dump1090 (ADS-B), WSJT-X (FT8/FT4), Direwolf (APRS), gr-gsm (GSM), inspectrum, multimon-ng, rtl_433, and more — these can be added to the Dockerfile via `apt-get install`.

### Graphical Tools

| Tool | Link | Description |
|------|------|-------------|
| GQRX | [gqrx.dk](https://www.gqrx.dk) | Graphical SDR receiver — spectrum waterfall, FM/AM/SSB/CW demodulation, recording |
| GNU Radio Companion | [gnuradio.org](https://www.gnuradio.org) | Visual flowgraph editor — build and run signal processing pipelines with drag-and-drop blocks |

These two are the only X11 applications in the menu, and reaching the host's
display from inside the container takes two things, not one:

1. **The display socket** — `run.sh` mounts `/tmp/.X11-unix` and passes
   `DISPLAY` through.
2. **The session's MIT-MAGIC-COOKIE** — the X server refuses connections that
   cannot present it. `run.sh` mounts the host's authority file to
   `/root/.Xauthority` and sets `XAUTHORITY`, choosing the host's own
   `$XAUTHORITY` if set and falling back to `~/.Xauthority`; override with
   `HOST_XAUTHORITY_PATH` in `.env` when neither is right, which is common
   under XWayland (the cookie often lives under `/run/user/1000/`). It is
   mounted **only if the file exists** — Docker would otherwise create a
   directory there, which is worse than no mount — and `run.sh` warns on
   startup when it finds none.

If a GUI tool still exits immediately, the menu now keeps its error on screen
and prints what `DISPLAY`, `XAUTHORITY`, the socket directory and the cookie
file actually look like inside the container. The usual one-line fix, run in
the desktop session that owns the display:

```bash
xhost +local:      # allow local clients, including this container
```

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
| `dump1090` | [github.com/mutability/dump1090](https://github.com/mutability/dump1090) | ADS-B Mode S decoder — interactive terminal aircraft table plus Beast (30005) / SBS (30003) / raw (30002) network output |
| `readsb` | [github.com/wiedehopf/readsb](https://github.com/wiedehopf/readsb) | Modern dump1090 fork — adds MLAT support and better decode performance; interactive terminal table plus Beast (30005) / SBS (30003) / raw (30002) network output. Built from source (see below) |
| `viewadsb` | (ships with readsb) | readsb's terminal aircraft-table viewer — attaches to a running readsb over the network instead of opening the dongle itself |

> **Note:** **Neither tool serves a web map in this image**, so there is nothing on port 8080. readsb has no built-in web server at all. Debian compiles `dump1090-mutability` without one too (`--net-http-port` is accepted, warned about, then ignored) and instead ships the map's HTML at `/usr/share/dump1090-mutability/html` with lighttpd/nginx snippets in `/etc/lighttpd/conf-available`, for a real web server to serve. A map therefore means running one — either that packaged HTML against dump1090's JSON, or [tar1090](https://github.com/wiedehopf/tar1090) against readsb's `--write-json` output. What both tools do give straight away is the interactive terminal table and the network ports above; `run.sh` starts the container with `--net=host`, so those are already the host's ports with no publishing needed.

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
| `acarsdec` | [github.com/TLeconte/acarsdec](https://github.com/TLeconte/acarsdec) | Multi-channel ACARS decoder — decodes text messages (weather, gate assignments, ops) transmitted by commercial aircraft. The menu scans 130.025 / 130.450 / 131.125 / 131.550 MHz. Built from source (see below) |

> **Note:** acarsdec covers every frequency you give it from one tuned RTL-SDR, so they must all fall inside a single sample-rate-wide window — 1.95 MHz at its default 2 MS/s (`rtl.c` tests the span against the sample rate minus a 50 kHz guard band). The four above span 1.525 MHz. Anything wider is rejected at startup with `Frequencies too far apart` and a non-zero exit, not silently narrowed — which is what the previous 129.125 / 130.025 / 130.450 / 131.550 list (2.425 MHz) would have done.

### Hardware Abstraction

| Tool | Link | Description |
|------|------|-------------|
| SoapySDR | [github.com/pothosware/SoapySDR](https://github.com/pothosware/SoapySDR) | Hardware-agnostic SDR abstraction layer — `SoapySDRUtil --find` probes all connected devices regardless of manufacturer |

> **Note:** SoapySDR is *only* an abstraction layer. `soapysdr-tools` on its own
> finds nothing at all — each piece of hardware needs its own module package, so
> the Dockerfile installs the RTL-SDR and HackRF ones too. Debian ABI-versions
> those (`soapysdr0.8-module-rtlsdr` under bookworm), so the Dockerfile tries the
> versioned names first, the unversioned aliases second, and falls back to a
> build-time warning rather than failing the image if neither exists in a future
> base. Nothing else in this environment goes through SoapySDR — every other tool
> talks to librtlsdr or libhackrf directly — so a missing module costs menu tag I
> its output and nothing more.

### Tools built from source

`readsb` and `acarsdec` are not in the Debian bookworm archive. Listing them
in the Dockerfile's `apt-get install` does not degrade gracefully — apt exits
`100` with `Unable to locate package`, and the whole image build fails on that
line, so nothing after it is built either. The Dockerfile compiles them (plus
`libacars`, which acarsdec needs to decode the ATS/CPDLC/ADS-C payloads inside
ACARS messages rather than just print the raw text) from upstream instead, each
pinned to an exact ref via a build `ARG`:

| Source | Pin (`ARG`) | Build |
|--------|-------------|-------|
| [wiedehopf/readsb](https://github.com/wiedehopf/readsb) | `READSB_VERSION=v3.16.16` | `make RTLSDR=yes`; no `install` target upstream, so `readsb` and `viewadsb` are copied to `/usr/local/bin` |
| [szpajder/libacars](https://github.com/szpajder/libacars) | `LIBACARS_VERSION=v2.2.1` | CMake → `/usr/local`, then `ldconfig` so acarsdec's `pkg-config` lookup finds it |
| [TLeconte/acarsdec](https://github.com/TLeconte/acarsdec) | `ACARSDEC_COMMIT=339f63eb…` | CMake with `-Drtl=ON` |

Notes for anyone bumping these:

- **acarsdec is pinned to a commit, not a tag, on purpose.** Its newest tag
  (`acarsdec-3.7`, 2022) predates the CMake build the Dockerfile uses, and
  upstream ended development at the pinned commit (*"The End"*, 2025-07-31) —
  so the pin is the project's final state rather than a moving branch head.
- **`-Drtl=ON` is what compiles in RTL-SDR support.** With no SDR option set,
  acarsdec's CMakeLists prints `No sdr option set ! are you sure ?` and still
  produces a binary — one that can only read from a file.
- **acarsdec's CMakeLists hardcodes `-Ofast -march=native`**, so that binary is
  tuned for whichever CPU built the image. Correct here (`run.sh` builds on the
  Pi that runs it), but it means the image is not safely copyable to an older
  or different CPU.
- Override any pin at build time without editing the Dockerfile, e.g.
  `docker build --build-arg READSB_VERSION=v3.16.16 -t dragonos-pi .`
- These three add a few minutes to a cold build on a Pi. `REBUILD_POLICY=FAST`
  reuses the cached layers; only `CLEAN` (`--no-cache`) recompiles them.
- `check-updates.sh` does **not** see these pins. It compares this image's
  `FROM` line and its apt packages against upstream, so a new readsb release
  will never show up there — bump `READSB_VERSION` by hand and run a `CLEAN`
  deploy.

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

Upon launching, a blue screen TUI will load in your terminal. It's a single `dialog --menu` with category headers (`[SDR Receivers]`, `[ADS-B Aircraft Tracking]`, etc.) shown alongside their tools, each indented underneath its category with manual tree-branch markers (`├──`/`└──`) rather than one flat undifferentiated list — everything's visible on one screen. (An earlier version used `dialog --treeview` for this; that was reverted since `--treeview`'s rendering depends on the installed `dialog` build actually supporting it, and a build that doesn't can silently show every row — including category headers — with a selectable marker that looks like multi-select. A plain `--menu` has no such ambiguity.) Category header tags are the bare category word, not prefixed with anything — selecting one just silently redraws the menu, no popup. Cancel/Esc also just redraws the menu — it never exits — only the explicit "Exit" tag does that. The menu also remembers your last selection and re-highlights it on redraw, rather than always resetting to the top.

The image sets `LANG` and `LC_ALL` to Debian's built-in `C.UTF-8` locale so
`dialog`/ncurses renders those tree branches and em dashes as Unicode. If an
older image shows byte-like sequences such as `~T~T` or `~@~T` in their place,
rebuild the DragonOS environment with the CLEAN policy to pick up the locale
fix; merely reattaching with FAST continues to use the existing image.

Tool tags run **1-9, then continue A, B, C, ...** rather than going to two-digit numbers — every tag stays a single keystroke for dialog's own type-ahead.

| Tag | Category | Tool | What it does |
|:---|:---|:---|:---|
| **1** | Info | Info | Environment info — data directory paths and useful host-side commands, since the outer `deploy.sh` `INFO` policy isn't reachable once you're attached in here. Colored and paged through `less -r`, like the outer `INFO` screen. |
| **2** | SDR Receivers | GQRX | Graphical spectrum analyzer — spectrum waterfall, FM/AM/SSB demodulation |
| **3** | SDR Receivers | GNU Radio Companion | Visual flowgraph editor for signal processing pipelines |
| **4** | RTL-SDR Utilities | rtl_test | Submenu: dropped-sample check, or oscillator (PPM) error measurement. Deliberately *not* `rtl_test -t`, which is the Elonics E4000 tuner benchmark and aborts on the R820T/R828D tuners these dongles actually use |
| **5** | RTL-SDR Utilities | rtl_fm | FM/AM/SSB demodulator — prompts for frequency, pipes audio to `aplay` |
| **6** | RTL-SDR Utilities | rtl_tcp | Network SDR server — exposes the dongle over TCP for remote SDR clients |
| **7** | RTL-SDR Utilities | rtl_power | Wideband power scan — prompts for frequency range, logs signal levels |
| **8** | HackRF Utilities | hackrf_info | Read HackRF firmware version, serial number, hardware registers |
| **9** | HackRF Utilities | hackrf_sweep | Fast spectrum scan — prompts for MHz bounds, sweeps up to 8 GHz/s |
| **A** | HackRF Utilities | hackrf_transfer | IQ capture/replay submenu — receive to file or transmit from file. Prompts in MHz and converts to Hz, since `hackrf_transfer` takes raw Hz and silently reads `433.92M` as 433 Hz |
| **B** | ADS-B Aircraft Tracking | dump1090 | ADS-B decoder — live aircraft table in terminal, Beast/SBS/raw network output (no web map in Debian's build — see above) |
| **C** | ADS-B Aircraft Tracking | readsb | ADS-B decoder with MLAT — prompts for lat/lon for range/distance stats, serves Beast/SBS network output |
| **D** | Signal Decoders | rtl_433 | Decode 433/868/915 MHz devices — weather sensors, remotes, meters |
| **E** | Signal Decoders | multimon-ng | Digital mode decoder — prompts for frequency, then decodes POCSAG512/1200/2400, FLEX, EAS and DTMF from an rtl_fm pipe (multimon-ng has no "all modes" switch; each demodulator is named explicitly) |
| **F** | Signal Decoders | direwolf | APRS decoder — submenu for NA (144.390 MHz) or EU (144.800 MHz) frequency |
| **G** | Signal Decoders | acarsdec | ACARS decoder — scans 130.025 / 130.450 / 131.125 / 131.550 MHz simultaneously |
| **H** | System Utilities | Select RTL-SDR device | Choose which dongle tags 4-7 and B-G use — see [Choosing between dongles](#choosing-between-dongles) |
| **I** | System Utilities | SoapySDRUtil | Probe all connected SDR hardware regardless of vendor. Needs SoapySDR's per-hardware modules, which the image installs alongside `soapysdr-tools` — without them this reports "No devices found!" even with a working dongle attached |
| **J** | System Utilities | lsusb | List USB devices attached to the host |
| **K** | Session | Bash Shell | Raw terminal inside the container — full access to all installed tools |
| **L** | Session | Exit | Leave the menu (container keeps running in background) |

### Choosing between dongles

Every RTL-SDR tool here defaults to "device 0" when told nothing, and device 0
is a coin flip the moment a second dongle is attached — USB enumeration order
is not stable across a reboot or a replug. That matters because the two
dongles people typically own for this are not interchangeable:

| Dongle | Good for | Not usable for |
|--------|----------|----------------|
| RTL-SDR Blog V3/V4 | Everything — 1 PPM TCXO, bias tee, HF via direct sampling, no filtering in the way | — |
| FlightAware Pro Stick | 1090 MHz ADS-B (built-in LNA) | Nothing physically blocked, but the always-on LNA overloads easily on strong out-of-band signals — run it at much lower gain |
| FlightAware Pro Stick **Plus** | 1090 MHz ADS-B (LNA + SAW filter) | Tags D-G — the 1090 MHz SAW filter rejects 433 MHz, ACARS, APRS and pager traffic outright |

So the menu picks a dongle **once per session** and passes it explicitly to
every tool that opens one (tags 4-7 and B-G). Selection happens lazily, on the
first tool that actually needs a radio — with exactly one dongle attached it is
chosen silently, with several you get a picker, and tag **H** re-opens that
picker at any time. The current choice is shown in the menu's top line and on
the tag **1** info screen.

This is session state, never image state: nothing is written to disk or baked
into the image, so swapping dongles needs a fresh menu session (or tag H) —
**never** a rebuild.

Tools that take a serial number get one, because a serial survives an
unplug/replug within a session where an index does not. Two exceptions are
handled automatically:

- **`dump1090-mutability` only understands `--device-index`**, so tag B always
  passes the index.
- **Unprogrammed dongles share a serial.** Both an RTL-SDR Blog V3 and a
  FlightAware Pro Stick leave the factory as `00000001`, so with two of them
  attached a serial would resolve to whichever enumerated first. The picker
  detects the collision and falls back to the index. To fix it permanently,
  give each dongle its own serial once, on the host, with one dongle plugged
  in at a time:

  ```bash
  rtl_eeprom -d 0 -s ADSB      # then replug the dongle for it to take effect
  ```

  After that the names show up in the picker and stay stable across reboots.

GQRX (tag 2) and GNU Radio (tag 3) are untouched by this — both have their own
device selection built in. The HackRF tools (tags 8-A) address different
hardware entirely.

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
| `FAST` | Start container if not running; reattach if already active (warns instead of reattaching silently if `.env` config drifted since the container was created) |
| `STOP` | Pause container (resumable with FAST) |
| `TEARDOWN` | Stop + remove container; data directories untouched |
| `CLEAN` | Rebuild image from scratch (slow on ARM), then stop + remove the old container only once the build succeeds |
| `INFO` | List data directories with sizes and useful commands (scrollable via `less` in an interactive terminal) |
| `WIPE` | Delete `./workspace/captures/`, `./workspace/msf_data/`, and `./workspace/` |

---

## 🖥️ Desktop Integration

On a Pi with a desktop environment (LXDE, XFCE, GNOME), run once from the repo root:

```bash
./install-desktop-entries.sh
# or just this environment on its own:
bash lib/run-install-desktop.sh environments/dragonos-sdr

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
