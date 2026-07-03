# Pi Barebones — First-Time Pi Initialization

Bootstraps a fresh Raspberry Pi OS install with a minimal quality-of-life setup: installs packages from `packages.txt`, drops a `.tmux.conf` into your home directory, and injects a `.bashrc` block that auto-attaches a tmux session and runs a system info screen on every login.

This is not a Docker environment — it runs directly on the host and has no containers.

---

## 🔧 Tools & Projects

| Tool | Link | Description |
|------|------|-------------|
| tmux | [github.com/tmux/tmux](https://github.com/tmux/tmux) | Terminal multiplexer — persists sessions across SSH disconnects and splits one terminal into panes/windows |
| fastfetch | [github.com/fastfetch-cli/fastfetch](https://github.com/fastfetch-cli/fastfetch) | Fast system info display (OS, CPU, RAM, uptime) shown on login — neofetch replacement written in C |
| PADD | [github.com/pi-hole/PADD](https://github.com/pi-hole/PADD) | Pi-hole live stats dashboard for the terminal — shows query rates, blocked %, top domains; displayed on login if `padd.sh` is present in `~` |

---

## What It Does

1. **Copies `.tmux.conf`** from this directory to `~/.tmux.conf` if the file exists
2. **Installs packages** listed in `packages.txt` (one package name per line, `#` for comments)
3. **Injects a `.bashrc` block** (idempotent — safe to re-run; old block is replaced, not duplicated):
   - Runs `tmux new-session -A` — attaches to an existing tmux session or creates one
   - Runs `~/padd.sh` if it exists (Pi-hole PADD dashboard)
   - Runs `fastfetch` if installed (system info display)

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
# List installed packages from packages.txt
cat environments/pi-barebones/packages.txt

# Re-run setup after editing packages.txt
./run.sh

# Attach to the tmux session
tmux attach

# List running tmux sessions
tmux ls

# View current .bashrc injected block
grep -A20 'PI INITIAL SETUP START' ~/.bashrc
```
