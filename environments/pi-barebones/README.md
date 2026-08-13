# Pi Barebones — First-Time Pi Initialization

Bootstraps a fresh Raspberry Pi OS install with a minimal quality-of-life setup: installs packages from `packages.txt`, drops a `.tmux.conf` into your home directory, and injects two `.bashrc` blocks that auto-attach a tmux session on login and run a system info screen at the very end of it.

This is not a Docker environment — it runs directly on the host and has no containers.

---

## ⚙️ Why This Needs a Custom `run.sh`

`deploy.sh`'s generic fallback only knows how to build/run a Docker image or `docker compose up` a stack — every one of its code paths assumes a `Dockerfile` or `docker-compose.yml` exists. This environment has neither, on purpose: everything it does is host-level provisioning with no container involved at all, so there's nothing for a Docker-based fallback to even discover:

- **`apt-get install`** of packages listed in `packages.txt` — direct host package management, not a container image build.
- **Idempotent `.bashrc` injection** — two independently-positioned marker-delimited blocks (tmux auto-attach, fastfetch on login), carefully ordered so other environments (e.g. `pihole-wireguard`'s PADD launcher) can insert their own block in between without disturbing tmux-first/fastfetch-last ordering. No Docker archetype has any notion of "edit the host user's shell rc file."
- **TigerVNC install and systemd service setup** — installs `tigervnc-standalone-server`, resolves a Debian-version-dependent password utility (`vncpasswd` vs `tigervncpasswd`), writes `/etc/tigervnc/vncserver.users` and a `vncserver@.service` unit file, then enables/starts it via `systemctl`. This is host-level remote-desktop infrastructure, not something expressible as a container at all.
- **xscreensaver autostart** — writes an XDG autostart entry under `~/.config/autostart` so `xscreensaver` launches whenever the X11 desktop session starts (VNC or physical). Again, no Docker archetype has any notion of a per-user desktop autostart directory.
- **Display resolution / X11 custom action** — the "Set Resolution to 1920x1080 (Console + X11)" menu action shells out to `raspi-config nonint`, which touches `/boot/firmware/config.txt` and the boot cmdline directly; this is host firmware configuration, well outside anything Docker can reach.

Since there's no `Dockerfile`/`docker-compose.yml` for this environment, `deploy.sh` has literally nothing to fall back to without `run.sh` — it's the only archetype that fits.

---

## 🔧 Tools & Projects

| Tool | Link | Description |
|------|------|-------------|
| tmux | [github.com/tmux/tmux](https://github.com/tmux/tmux) | Terminal multiplexer — persists sessions across SSH disconnects and splits one terminal into panes/windows |
| fastfetch | [github.com/fastfetch-cli/fastfetch](https://github.com/fastfetch-cli/fastfetch) | Fast system info display (OS, CPU, RAM, uptime) shown on login — neofetch replacement written in C |
| TigerVNC | [tigervnc.org](https://tigervnc.org) | High-performance VNC server — streams the full Pi desktop to any VNC client at 1920×1080, auto-starts on boot via systemd |
| xscreensaver | [jwz.org/xscreensaver](https://www.jwz.org/xscreensaver/) | X11 screensaver/locker daemon, autostarted on desktop login |

Note: [PADD](https://github.com/pi-hole/PADD) (Pi-hole's terminal stats dashboard) is wired up by the `pihole-wireguard` environment, not this one — see its README.

---

## What It Does

1. **Copies `.tmux.conf`** from this directory to `~/.tmux.conf` if the file exists
2. **Installs packages** listed in `packages.txt` (one package name per line, `#` for comments)
3. **Injects two `.bashrc` blocks** (idempotent — safe to re-run; old blocks are replaced, not duplicated), kept separate and independently positioned rather than one combined block so other environments can inject their own login-time commands in between:
   - **tmux block**, always re-pinned immediately before any other custom block (e.g. `pihole-wireguard`'s PADD launcher) — or appended at the end if none exist yet — runs `tmux new-session -A` (attaches to an existing tmux session or creates one). Never prepended to the absolute top of `.bashrc`, since that would run before the default `.bashrc`'s own "if not running interactively, don't do anything" guard and could break non-interactive shell invocations (scp, ansible, `ssh host command`, etc.)
   - **fastfetch block**, always re-pinned to the very bottom of `.bashrc` — runs `fastfetch` if installed (system info display)

   For example, `pihole-wireguard`'s PADD launcher block inserts itself between these two, so the login sequence is always tmux → PADD → fastfetch regardless of which environment you deploy first.
4. **Installs and configures TigerVNC** — see below
5. **Wires up xscreensaver autostart** — writes `~/.config/autostart/xscreensaver.desktop` (idempotent — overwritten, not appended, on re-run) so the screensaver daemon launches under any X11 desktop session (VNC or physical monitor)

The `.bashrc` injections use marker comments so re-running the script cleanly replaces the previous blocks rather than appending duplicate lines.

---

## 🖥️ Display Resolution (Console + X11)

If the first physical/HDMI connect renders too big or off-screen — common when the Pi auto-negotiates a mode the monitor/capture device can't actually show correctly — use the **"Set Resolution to 1920x1080 (Console + X11)"** action from `deploy.sh`'s menu for this environment (or run `scripts/set-resolution.sh` directly). It:

1. Forces the desktop session to X11 via `raspi-config nonint do_wayland W1` (Raspberry Pi OS Bookworm defaults to Wayland/labwc, which xscreensaver and this fixed-resolution mode don't work under)
2. Forces console framebuffer resolution to 1920x1080 (DMT mode 82) via `raspi-config nonint do_resolution 2 82`, plus an explicit `video=HDMI-A-1:1920x1080@60D` cmdline.txt override on systems using the `vc4-kms-v3d` (full KMS) driver — `do_resolution`'s own `hdmi_group`/`hdmi_mode` config.txt keys are silently ignored under KMS
3. Wires up an XDG autostart entry (`~/.config/autostart/force-x11-resolution.desktop`) that re-pins every connected output to 1920x1080 via `xrandr` on every X11 login — Xorg's `modesetting` driver re-probes the monitor's EDID independently of the KMS console override and will otherwise pick the monitor's own preferred (often higher, e.g. native 4K) mode once the desktop session starts

**Requires a reboot** (`sudo reboot`) to take effect — the console/KMS changes are firmware/boot-config changes; the X11 autostart entry applies on the next desktop login.

This is independent of the VNC session's own resolution, which is set separately by `geometry=1920x1080` in `~/.vnc/config` (see below) and already defaults to 1920x1080.

---

## Customising the Package List

Edit `packages.txt` to add or remove packages. One package name per line, comments with `#`:

```
# Terminal utilities
tmux
fastfetch
xscreensaver

# Networking tools
nmap
htop
```

Run `./run.sh` again after editing — `apt-get install` is idempotent so already-installed packages are skipped.

---

## Deployment

```bash
chmod +x run.sh
./run.sh
```

Then reload your shell or reconnect via SSH to see the `.bashrc` changes take effect:

```bash
source ~/.bashrc
```

---

## 🖥️ TigerVNC Remote Desktop

`run.sh` installs and configures TigerVNC automatically. All steps are idempotent — re-running the script is safe.

### What gets configured

| Step | What happens |
|:---|:---|
| Install | `tigervnc-standalone-server` and `tigervnc-common` via apt |
| Password | Prompts for a VNC password once; skipped on subsequent runs if `~/.vnc/passwd` or `~/.config/tigervnc/passwd` already exists |
| `~/.vnc/config` | Written with `session=lightdm-xsession`, `geometry=1920x1080`, `depth=24`, `localhost=0` |
| `/etc/tigervnc/vncserver.users` | Maps display `:1` to the current user |
| systemd service | `/etc/systemd/system/vncserver@.service` — auto-starts on boot |
| Boot enable | `systemctl enable vncserver@1.service` + immediate start |

The current user is detected automatically (`$SUDO_USER` or `$USER`) — the username is not hardcoded.

### Connecting

Open any VNC client and connect to:

```
Host:     <Pi IP address>:5901
Password: the one you set during setup
```

> **Port:** display `:1` maps to TCP port `5901` (`:2` → `5902`, etc.)

### Managing the VNC service

```bash
# Check status
systemctl status vncserver@1.service

# Restart (e.g. after a config change)
sudo systemctl restart vncserver@1.service

# Stop
sudo systemctl stop vncserver@1.service

# View VNC server log
cat ~/.vnc/*.log
```

### Changing the VNC password

```bash
vncpasswd
# then restart the service
sudo systemctl restart vncserver@1.service
```

### OS Compatibility — Debian 13 (Trixie)

On Debian 13, the password utility ships in a separate package as `tigervncpasswd` rather than `vncpasswd`. `run.sh` handles this automatically:

1. Checks for `vncpasswd`, then `tigervncpasswd`
2. Installs `tigervnc-tools` if neither is found
3. Creates a symlink `/usr/local/bin/vncpasswd → tigervncpasswd` so the short name works everywhere

If you hit this manually (e.g. outside of `run.sh`):

```bash
sudo apt install -y tigervnc-tools
tigervncpasswd               # set password
sudo ln -sf /usr/bin/tigervncpasswd /usr/local/bin/vncpasswd  # optional shortcut
```

### Changing resolution

Edit `~/.vnc/config` and update the `geometry` line, then restart the service:

```bash
nano ~/.vnc/config
# change geometry=1920x1080 to e.g. geometry=1280x720
sudo systemctl restart vncserver@1.service
```

---

## 🎛️ Deployment Policies

`run.sh` never branches on `$REBUILD_POLICY` at all — it always runs the same idempotent setup regardless of which policy would otherwise apply, so `STOP`/`TEARDOWN`/`CLEAN`/`WIPE` would all be no-ops if shown. `deploy.sh`'s policy menu detects this generically (a `run.sh` with zero `POLICY` references, paired with `info.yaml` declaring no `data_dirs`/`install_dirs`/`named_volumes`) and only presents the two policies that actually do something:

| Policy | Action |
|--------|--------|
| `FAST` | Install missing packages and update `.bashrc` blocks — safe to re-run any time |
| `INFO` | No persistent data directories — shows useful commands (scrollable via `less` in an interactive terminal) |

---

## 💡 Useful Commands

```bash
# Re-run setup after editing packages.txt
./run.sh

# Attach to the tmux session
tmux attach

# View current .bashrc injected blocks
grep -A5 'PI TMUX SETUP START' ~/.bashrc
grep -A5 'PI FASTFETCH SETUP START' ~/.bashrc

# Check VNC server status
systemctl status vncserver@1.service

# Restart VNC after config changes
sudo systemctl restart vncserver@1.service

# Change VNC password
vncpasswd

# View VNC server log
cat ~/.vnc/*.log

# Force console + X11 to 1920x1080 (also available as a deploy.sh menu action)
bash scripts/set-resolution.sh

# Configure screensaver timeout/lock (X11 only)
xscreensaver-demo
```
