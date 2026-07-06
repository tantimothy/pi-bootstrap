# Pi Barebones — First-Time Pi Initialization

Bootstraps a fresh Raspberry Pi OS install with a minimal quality-of-life setup: installs packages from `packages.txt`, drops a `.tmux.conf` into your home directory, and injects a `.bashrc` block that auto-attaches a tmux session and runs a system info screen on every login.

This is not a Docker environment — it runs directly on the host and has no containers.

---

## 🔧 Tools & Projects

| Tool | Link | Description |
|------|------|-------------|
| tmux | [github.com/tmux/tmux](https://github.com/tmux/tmux) | Terminal multiplexer — persists sessions across SSH disconnects and splits one terminal into panes/windows |
| fastfetch | [github.com/fastfetch-cli/fastfetch](https://github.com/fastfetch-cli/fastfetch) | Fast system info display (OS, CPU, RAM, uptime) shown on login — neofetch replacement written in C |
| TigerVNC | [tigervnc.org](https://tigervnc.org) | High-performance VNC server — streams the full Pi desktop to any VNC client at 1920×1080, auto-starts on boot via systemd |

Note: [PADD](https://github.com/pi-hole/PADD) (Pi-hole's terminal stats dashboard) is wired up by the `pihole-wireguard` environment, not this one — see its README.

---

## What It Does

1. **Copies `.tmux.conf`** from this directory to `~/.tmux.conf` if the file exists
2. **Installs packages** listed in `packages.txt` (one package name per line, `#` for comments)
3. **Injects a `.bashrc` block** (idempotent — safe to re-run; old block is replaced, not duplicated):
   - Runs `tmux new-session -A` — attaches to an existing tmux session or creates one
   - Runs `fastfetch` if installed (system info display)
4. **Installs and configures TigerVNC** — see below

The `.bashrc` injection uses marker comments so re-running the script cleanly replaces the previous block rather than appending duplicate lines.

---

## Customising the Package List

Edit `packages.txt` to add or remove packages. One package name per line, comments with `#`:

```
# Terminal utilities
tmux
fastfetch

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

| Policy | Action |
|--------|--------|
| `FAST` | Install missing packages and update `.bashrc` block |
| `STOP` | No-op — no running services to stop |
| `TEARDOWN` | No-op — no containers to remove |
| `CLEAN` | Same as FAST (re-runs setup idempotently) |
| `INFO` | No persistent data directories — shows useful commands |
| `WIPE` | No data directories to delete |

---

## 💡 Useful Commands

```bash
# Re-run setup after editing packages.txt
./run.sh

# Attach to the tmux session
tmux attach

# View current .bashrc injected block
grep -A20 'PI INITIAL SETUP START' ~/.bashrc

# Check VNC server status
systemctl status vncserver@1.service

# Restart VNC after config changes
sudo systemctl restart vncserver@1.service

# Change VNC password
vncpasswd

# View VNC server log
cat ~/.vnc/*.log
```
