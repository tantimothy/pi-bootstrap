# 🐳 Pi Bootstrap

A lightweight TUI hub for deploying and managing containerized environments on a Raspberry Pi. Run `deploy.sh` to get an interactive menu — select an environment, configure it, and it handles the rest.

```bash
# Clone and run
git clone https://github.com/tantimothy/pi-bootstrap.git
cd pi-bootstrap
./deploy.sh
```

Or run directly on a fresh Pi without cloning:

```bash
curl -fsSL -A "pi-bootstrap-installer" https://raw.githubusercontent.com/tantimothy/pi-bootstrap/master/deploy.sh | bash
```

`raw.githubusercontent.com` is served by a CDN with its own abuse/rate-limiting layer, separate
from the GitHub API's normal limits — it can return a 429 "scraping" page if hit repeatedly in
a short window (e.g. re-running this a few times while testing/debugging) or from a request
that looks like generic bot traffic (no auth, no distinguishing User-Agent). If you hit that,
wait a few minutes and retry, or just use the `git clone` method above instead — it doesn't go
through this raw-content path at all, so it isn't subject to the same rate-limiting.

The `-f` flag matters either way: without it, curl treats any HTTP error response — including
that 429 page — as "success" and pipes its body straight into `bash`, which executes it as
garbled commands instead of failing cleanly.

---

## 🗂️ Environments

| Environment | Description |
|:---|:---|
| [dragonos-sdr](environments/dragonos-sdr/) | Software-defined radio toolkit — GQRX, GNU Radio, RTL-SDR utilities, HackRF tools, ADS-B aircraft tracking (dump1090, readsb), rtl_433 sensor decoding, APRS packet radio (direwolf), ACARS aircraft messages (acarsdec), FM/pager/EAS decoding (multimon-ng) |
| [pihole-wireguard](environments/pihole-wireguard/) | Network stack — Pi-hole DNS ad-blocker + WireGuard VPN (wg-easy) + full monitoring suite (Prometheus, Grafana, Uptime Kuma, node/speedtest/blackbox exporters) + PADD terminal dashboard |
| [kali-pentest](environments/kali-pentest/) | Headless Kali Linux pentest environment — wireless attacks (Wifite2, aircrack-ng suite, hcxdumptool), network MITM (Bettercap, Nmap, tshark), exploitation (Metasploit), wardriving (Kismet + GPS) |
| [internet-pi](environments/internet-pi/) | Ansible-managed Raspberry Pi — Pi-hole, Prometheus, Grafana, Speedtest Exporter, Blackbox Exporter, Node Exporter (based on [geerlingguy/internet-pi](https://github.com/geerlingguy/internet-pi)) |
| [nanoclaw](environments/nanoclaw/) | Self-hosted AI assistant — routes WhatsApp/Telegram/Discord/Slack/etc. to isolated per-conversation-group Claude Agent SDK containers. `host` or `container` deploy mode (see its README) |
| [nanoclaw-mnemon](environments/nanoclaw-mnemon/) | Same as nanoclaw, `container` mode only, with [mnemon](https://github.com/mnemon-dev/mnemon) patched into the agent sandbox for persistent cross-session graph memory — optionally hybrid graph+vector recall via mnemon's own built-in Ollama embeddings, opt-in via `.env`. Also scaffolds NanoClaw's own Karpathy-pattern wiki skill. Fully independent install — coexists with plain nanoclaw on the same machine |
| [chat-frontends](environments/chat-frontends/) | A small hub of browser-based chat UIs for your host's Ollama — [Open WebUI](https://github.com/open-webui/open-webui) and [SillyTavern](https://github.com/SillyTavern/SillyTavern) (both on by default), plus [LobeHub](https://github.com/lobehub/lobe-chat) (needs its own Postgres), [NextChat](https://github.com/ChatGPTNextWeb/NextChat), and [AnythingLLM](https://github.com/Mintplex-Labs/anything-llm) (RAG-focused) as opt-ins. Toggle which ones run via `COMPOSE_PROFILES` in `.env`, no rebuild needed |
| [llm-gateways](environments/llm-gateways/) | An OpenAI-compatible proxy layer in front of your host's Ollama (and, optionally, hosted providers) — [LiteLLM](https://github.com/BerriAI/litellm) (on by default, config-only, no database needed) and [Portkey Gateway](https://github.com/Portkey-AI/gateway) (opt-in, a lighter no-config alternative). LiteLLM's Postgres (Virtual Keys/spend tracking/Admin UI) is a separate opt-in on top of that. Toggle which ones run via `COMPOSE_PROFILES` in `.env`, no rebuild needed |
| [claude-cli](environments/claude-cli/) | Standalone Claude CLI in a container with its own SSH server — no channel bots, no orchestrator. SSH in from any machine and land in a persistent `tmux` session running `claude` against a bind-mounted repo. For when you just want remote terminal access to Claude, not a chat-platform presence |
| [pi-barebones](environments/pi-barebones/) | Minimal Pi setup — tmux, fastfetch system info, TigerVNC remote desktop, custom package installs and `.bashrc` tweaks |
| [ntopng](environments/ntopng/) | Deep per-flow traffic analysis — DPI (nDPI), historical/timeseries trends via Redis. Split out as its own environment since it's heavyweight; pairs well alongside pihole-wireguard on a Pi with headroom to spare |
| [portainer](environments/portainer/) | Container visualization & management — full container/network/volume/image management UI with a live topology view. General-purpose Docker tooling, useful alongside any other environment on this Pi |

---

## 🖥️ Desktop Menu Integration

**Linux only** — `.desktop` files, `~/.local/share/applications`, and the `xdg-desktop-menu` submenu machinery this relies on are all XDG/Linux desktop-environment concepts with no macOS equivalent. On macOS, `./install-desktop-entries.sh` detects this and skips cleanly with a one-line message — nothing is written to `~/Desktop` or anywhere else. If you're running an environment (e.g. `nanoclaw` in `container` mode) on a Mac, just run `./deploy.sh` directly, or add it to your Dock/Login Items yourself; there's no equivalent auto-generated launcher on macOS today.

On a Pi with a desktop environment (LXDE, XFCE, GNOME), run once to register all environments as clickable desktop entries. This is also available as menu options in `./deploy.sh` — "[Desktop] Install Desktop Entries" and "[Desktop] Uninstall Desktop Entries":

```bash
./install-desktop-entries.sh

# To remove them
./install-desktop-entries.sh --uninstall
```

This installs entries to `~/.local/share/applications/` (the application menu) **and** mirrors each one onto `~/Desktop` (or your actual XDG Desktop folder, if it differs) as a clickable icon — copied there executable and, where `gio` is available, marked "trusted" so it launches directly instead of showing as inert text or prompting to trust it on every click. Each environment also gets its own submenu (e.g. "Pi-hole + WireGuard") in the application menu, instead of its entries scattering into existing folders like Internet or System Tools. What each type does:

| Entry type | How it opens |
|:---|:---|
| GQRX, GNU Radio Companion | X11 socket passthrough — window appears directly on the Pi desktop |
| SDR menu, Kali, NanoClaw | Opens in your desktop's default terminal emulator |
| Pi-hole, Grafana, Uptime Kuma, WireGuard, darkstat, Dozzle, ntopng, Portainer | Menu: tries `xdg-open`, then falls back through several other browser launchers against `http://localhost:<port>`. Desktop icon: a `Type=Link` entry opened directly by the desktop's default URL handler |
| `<Environment> Info` | Same as above, pointed at that environment's generated `post-deploy-info.html` (see below) via a `file://` URL |

Ports for the web UI entries are read from each environment's `.env` (falling back to a literal default baked into `desktop-entries.yaml` if unconfigured) at install time, so they stay correct after reconfiguration. Re-run the script if you change ports.

The menu entry and the Desktop icon for these are deliberately two different desktop-entry flavors, not one file copied to both places: the application menu only lists `Type=Application` entries on some desktop environments (`Type=Link` is silently filtered out of the menu, even though it works fine as a Desktop icon there) — so the menu copy uses `Type=Application` with a browser-fallback `Exec=`, and the Desktop copy uses the simpler `Type=Link`.

Only environments that are actually deployed get entries. Re-running the installer keeps the menu in sync: it registers entries for anything newly deployed, and removes entries for anything that isn't (or was undeployed since) — so stale shortcuts don't linger. "Deployed" is detected differently per environment, since each has a different way of showing it's actually running rather than just built:

| Environment | "Deployed" signal |
|:---|:---|
| pihole-wireguard | The `pihole` container exists |
| ntopng | The `ntopng` container exists |
| portainer | The `portainer` container exists |
| nanoclaw | The `nanoclaw.service` systemd unit is registered (`host` deploy mode) or the `nanoclaw` container exists (`container` deploy mode) |
| nanoclaw-mnemon | The `nanoclaw-mnemon` container exists (container mode only — no host mode) |
| chat-frontends | The `open-webui` container exists (its own flagship service — see that environment's `docker-compose.yml`) |
| llm-gateways | The `litellm` container exists (its own flagship service — see that environment's `docker-compose.yml`) |
| claude-cli | The `claude-cli` container exists |
| dragonos-sdr, kali-pentest | A local `.deployed` marker that `run.sh` creates the moment it launches the container (these run with `--rm`, so a cached image alone doesn't prove the environment was actually used) |

New entries appear in the menu automatically on Raspberry Pi OS; no manual refresh is needed.

### 📄 Post-deploy info page

Every environment's info page (both right after `run.sh` deploys it, and any time you open "INFO" from `./deploy.sh` — both routed through `lib/run-info.sh`) also (re)generates `environments/<env>/post-deploy-info.html` — a self-contained HTML page with the same data directories, useful commands, and notes as the terminal listing, except any web UI URLs are clickable links. It's not tracked in git (regenerated fresh each time) but is opened directly by that environment's `<Environment> Info` desktop entry above.

---

## 💾 Backup & Restore

`backup.sh` builds one archive containing every deployed environment's persistent data (data directories + named Docker volumes) and, by default, each environment's `.env` file. This is also available as menu options in `./deploy.sh` — "[Backup] Create Backup Archive" and "[Backup] Restore From Archive":

```bash
./backup.sh                    # back up every environment, .env included
./backup.sh --no-env           # exclude .env files (data dirs/volumes only)
./backup.sh -o /path/to/dir    # write the archive somewhere other than the current directory
```

The archive is only ever written **locally** — copying it to another machine (`scp`, `rsync`, a USB drive, cloud sync, AirDrop, whatever) is up to you. That keeps this deliberately dependency-free: no assumptions about SSH keys, network access, or the destination machine's OS. A `.tar.gz` opens the same way on Linux, macOS, and Windows.

```bash
./restore.sh <path-to-backup.tar.gz>              # interactive: pick which environment to restore
./restore.sh <path-to-backup.tar.gz> <env-name>   # restore one specific environment
./restore.sh <path-to-backup.tar.gz> all          # restore every environment in the archive
```

Restoring works the same whether it's the same Pi or a brand new machine — clone this repo, run `./restore.sh`, then redeploy each restored environment via `./deploy.sh` (or its `run.sh`, `REBUILD_POLICY=FAST`). Each environment's data directories are restored to their exact original absolute paths (some live inside `environments/<env>/`, others under `$HOME` — `restore.sh` preserves whichever it was), and named Docker volumes are recreated and repopulated from their own nested archive inside the backup.

**Security note:** since `.env` files (containing Pi-hole/Grafana passwords, WireGuard keys config, API tokens, etc.) are included by default, treat a backup archive as sensitive — it's only as safe as wherever you send it.

---

## 🔍 Checking for Image Updates

`FAST` deliberately doesn't pull a fresh image for a container that's already running (see the Policy Matrix below) — only `CLEAN` does. That means a container can quietly fall behind upstream indefinitely if you only ever redeploy with `FAST`. `check-updates.sh` answers "what's actually out of date right now" without touching anything:

```bash
./check-updates.sh
```

Also available as "Check Updates" under "[Manage] Containers & Images" in `./deploy.sh` — that menu entry always runs the `--apply` form described below, since the scan itself is identical either way and it only ever prompts when something's actually flagged; with nothing to update there's nothing to distinguish it from a plain scan. For every currently-running container across every environment, it pulls that container's exact image reference fresh (refreshing only Docker's local cache — a running container keeps using the image ID it already started from, so this never disrupts anything live) and compares the freshly-pulled image ID against what's actually running. A mismatch means an update is available but not yet applied.

**Locally-built images** (e.g. `darkstat`, `ntopng`, `dragonos-sdr`, `kali-pentest` — all built from a Dockerfile via `apt-get`, not pulled from a registry) have no tag to `docker pull` and compare, so they're checked differently: `apt-get update` is run live inside the running container (read-only — it only refreshes package-list metadata, nothing is installed or restarted) to see if any installed apt package has a newer version, and the Dockerfile's own `FROM` line is checked by pulling that base tag fresh and comparing it against the image's actual build history. Either one being out of date is reported as an update available; an image with no `apt-get` at all (nothing in this repo currently) would be reported as skipped instead.

A plain `./check-updates.sh` run is purely informational — it never restarts or recreates anything, matching this repo's deliberate choice not to auto-update (see `docs/future-enhancements/pihole-wireguard-additional-services.md`'s "Not recommended: Watchtower" section for why).

To actually apply what it finds, either redeploy that container's whole environment with `REBUILD_POLICY=CLEAN ./run.sh`, or target just the flagged containers:

```bash
./check-updates.sh --apply
```

This re-runs the same scan, then asks individually — `[y/N/a=all/c=cancel]` per flagged container, nothing is ever applied without an explicit yes (or "apply all") — whether to recreate it right now. `a` applies this and every remaining flagged container without asking again; `c` cancels and leaves this and every remaining container untouched (already-applied containers before that point are unaffected either way). Everything else in that container's environment is left untouched (`docker compose up -d --no-deps --force-recreate <name>` for compose-managed services); locally-built apt images get an actual rebuild first (`docker compose build --no-cache` for compose-managed services, or `lib/deploy-lib.sh`'s shared `deploy_environment()` — the same mechanics `deploy.sh` itself uses — for single-container environments like `dragonos-sdr`/`kali-pentest`, with or without their own `run.sh`) — the new image always finishes building before the old container is touched, so a failed rebuild never leaves you with nothing running. A container whose environment can't be determined is reported and left for you to apply manually.

---

## 🐕 Ollama Watchdog

Ollama itself isn't one of this repo's environments — it's a host-level dependency `nanoclaw-mnemon` prompts to install and that `chat-frontends`/`llm-gateways` also talk to, always running natively rather than containerized (see those environments' own READMEs for why). None of them monitor it. `ollama-watchdog.sh` is a standalone script for that, born from a real incident: Ollama's process was alive, `ollama ps` even still showed a loaded model, but every chat request hung forever with nothing in any app's logs — only a full restart fixed it. A check that just confirms the process exists would have missed that entirely; this instead hits Ollama's own API with a hard timeout:

```bash
./ollama-watchdog.sh --check      # one-shot: is it actually responding right now?
./ollama-watchdog.sh              # one-shot: check, and restart it if not
./ollama-watchdog.sh --restart    # force a restart regardless of health
```

To run this automatically on a schedule instead of by hand:

```bash
./ollama-watchdog.sh --install    # every 5 minutes by default — launchd on macOS, cron on Linux
./ollama-watchdog.sh --uninstall  # remove the scheduled job
```

Also reachable from `deploy.sh` itself — every environment that depends on Ollama (`nanoclaw-mnemon`, `chat-frontends`, `llm-gateways`) has a **"Check / Restart Ollama"** entry in its own action menu, via that environment's `info.yaml` `custom_actions` (see below) — no need to drop to a shell for it.

Restart behavior is platform- and install-method-aware: macOS prefers `killall Ollama` + `open -a Ollama` if that's how it's running (the default Mac install), Linux prefers `systemctl restart ollama` if the official installer's systemd unit exists, and both fall back to killing/relaunching a bare `ollama serve` process otherwise. Every check and restart attempt is logged to `~/.ollama-watchdog.log` (override with `OLLAMA_WATCHDOG_LOG`), and on macOS a restart also fires a native notification via `osascript` (falls back to `notify-send` on Linux desktops that have it) — useful for a scheduled run where nothing's watching the terminal.

**What this doesn't catch**: the health check hits Ollama's lightweight `/api/tags` endpoint (list installed models), not a real generation — enough to confirm the HTTP API itself is alive, which is what actually wedged in the incident above, but not a guarantee the generation engine specifically works if just that endpoint happens to still respond. A real `/api/generate` call would catch more, but needs a model already pulled, is slow, and burns real resources on every scheduled check — not worth it for something meant to run every few minutes.

---

## 🏗️ How It Works

### Routing Priority

`deploy.sh` scans each selected environment folder and picks the first match:

```text
environments/your-env/
│
├── 1. run.sh              →  delegates everything to the script (most flexible)
└── 2. docker-compose.yml  →  runs `docker compose up -d` (generic fallback, no run.sh needed)
```

There's technically a third fallback `lib/deploy-lib.sh` still recognizes — a bare `Dockerfile` with neither of the above — but it's a trap, not a real option: its `docker run` invocation has **no `-v` flag at all**, so while it happily pre-creates `info.yaml`'s `data_dirs` on the host (same as option 2), it never actually mounts them into the container — anything the app writes there is lost the moment it's recreated. Nothing in this repo uses it today; every current single-container environment has either a `run.sh` or a `docker-compose.yml`. If your environment is genuinely "just one simple container," write a one-service `docker-compose.yml` with `build: .` pointing at your `Dockerfile` instead — same "no `run.sh` needed" simplicity, but with real volume/port/flag support, since Compose can express everything the bare-`Dockerfile` path can't.

Option 2 (no `run.sh`) still gets the essentials generically, without writing any custom script: `CLEAN` builds/pulls fresh images *before* touching what's currently running (a failed build leaves the old container(s) untouched, same safety property every `run.sh` implements by hand), data directories from `info.yaml`'s `data_dirs` are pre-created before Docker ever touches them as a bind-mount target (via `lib/run-info.sh <env_dir> list-dirs`), desktop entries refresh automatically after a successful deploy (via `lib/run-install-desktop.sh`), and `check-updates.sh --apply` can target it too. This mechanics lives in `lib/deploy-lib.sh`'s `deploy_environment()`, shared by both `deploy.sh` and `check-updates.sh --apply` rather than duplicated between them. What it still can't do without a real `run.sh`: any host-level setup (network config, sysctls, DNS resilience, etc.), an interactive attach/reattach session, dynamic container spawning, or rollback snapshotting.

### Dependencies

`deploy.sh` checks for and auto-installs everything it needs on first run: `dialog` (the TUI itself), `docker` + the Compose plugin, and **go-yq** (`github.com/mikefarah/yq`) — required specifically because it's *not* the same `yq` some distros (Debian/Ubuntu) package under that name; that one's a Python jq-wrapper with an incompatible filter syntax. go-yq is what every environment's `desktop-entries.yaml`/`info.yaml` (see "Adding a New Environment" below) gets read through, installed to `/usr/local/bin/yq` — ahead of `/usr/bin` on `$PATH` — so it shadows any apt-installed impostor without touching or uninstalling it.

### Permission Wrapper

`deploy.sh` never assumes the user is in the `docker` group. It tests `/var/run/docker.sock` access and automatically prepends `sudo` if needed, exporting the resolved command as `$DOCKER_CMD` so all child environments inherit it.

### Policy Matrix

Every environment receives a `REBUILD_POLICY` variable:

| Policy | Container behaviour | Image cache |
|:---|:---|:---|
| `FAST` *(default)* | Reuse or reconcile whatever's already running rather than exiting silently stale — the exact mechanism varies by environment (Docker Compose's own config-hash recreate, re-running an idempotent Ansible playbook, or a custom config-drift hash for plain `docker run` environments); see each environment's README for specifics | Reuse local layer cache; rebuild/pull only what's missing |
| `CLEAN` | Build or pull the replacement *before* touching the existing containers, so a failed build/pull leaves the previous working setup untouched instead of leaving nothing running; some environments (e.g. `pihole-wireguard`) also keep the previous container as an explicit rollback fallback | Force `--no-cache` build or fresh `pull`, depending on environment |
| `STOP` | Pause containers (resumable with FAST) | — |
| `TEARDOWN` | Stop + remove containers; data untouched | — |
| `INFO` | Show data directories, sizes, and useful commands (scrollable via `less` in an interactive terminal) | — |
| `WIPE` | Delete persisted data directories (irreversible) | — |

### Session Logs

For environments driven by `docker-compose.yml`/`Dockerfile` (no `run.sh`), every `FAST`/`STOP`/`TEARDOWN`/`CLEAN` run is recorded to `environments/<env>/logs/<POLICY>-<timestamp>.log`, and likewise for `INFO`/`WIPE` on any environment — the full session, not just a `stdout` capture, via `script`, a real pty recorder. On failure, `deploy.sh` prints the last 30 lines of that log straight to the screen (plus its full path) before returning to the menu, so a fast-scrolling build/install failure doesn't just vanish before you can read it. These logs are gitignored (`environments/*/logs/`) — purely local troubleshooting artifacts, never committed.

Environments with their own `run.sh` (e.g. `nanoclaw`/`nanoclaw-mnemon`) are **not** session-logged. Some hand off to a fully-interactive sub-program that reattaches directly to `/dev/tty` (e.g. `nanoclaw-mnemon`'s own first-run setup wizard via `docker exec -it`) — stacking `script`'s own pty on top of that nested handoff was tried and broke both live rendering and keyboard input on a real terminal, so that path runs completely unwrapped instead, exactly as if invoked directly. Whatever it prints, it prints live on your actual screen; there's nothing to tail after the fact. Either way, `deploy.sh` resets the terminal (`stty sane` + drains any stray buffered input) before its next prompt, so a sub-program that exits without restoring the tty can't cause the menu to silently swallow your next keypress or flash by before you can read the result.

### Secret Pre-Processor

Each environment has a `.env.example` file. `deploy.sh` reads it to:
1. Show each variable's inline `#` comment as a scrollable info card
2. Generate a `dialog` form pre-filled with defaults
3. Write the result to a local `.env` file (gitignored — never committed)

---

## 🛠️ Adding a New Environment

Drop a folder into `environments/` — `deploy.sh` discovers it automatically. It'll show up at the end of the Environments menu (alphabetically, among any other undeclared environments) until you add it to **`config/environments.yaml`**, which controls that menu's display order and grouping (host setup, AI assistants, networking/security, management) — add your environment's folder name under whichever category fits, or a new one if it doesn't fit an existing category.

### Folder Layout

```text
environments/
└── my-environment/
    ├── .env.example          # drives the TUI config form — skip only if there's
    │                         # truly nothing to configure (see pi-barebones)
    ├── run.sh                # archetype 1: custom script (highest priority) —
    │                         # itself one of a few subtypes, see below
    ├── docker-compose.yml    # archetype 2: generic fallback, no run.sh needed
    ├── Dockerfile            # optional — a local image run.sh builds itself, or
    │                         # that docker-compose.yml's `build:` points at; never
    │                         # used standalone, see "Routing Priority" above
    ├── info.yaml             # recommended — see below
    ├── desktop-entries.yaml  # recommended if there's a menu-launchable target — see below
    ├── info.sh               # only if info.yaml can't express real branching
    ├── install-desktop.sh    # only if desktop-entries.yaml can't express real branching
    └── README.md             # Services & Ports, Data Directories, Desktop
                               # Integration, Useful Commands, security notes
```

`info.yaml`/`desktop-entries.yaml` (or the `info.sh`/`install-desktop.sh` override scripts that read them) aren't one of the two deploy archetypes — every environment needs the data they provide regardless of which archetype it uses. They're covered separately below since they're easy to miss (nothing on the `deploy.sh` discovery path requires them, but other scripts silently depend on them). Full schema for both YAML files — every key, valid values, and the substitution mechanism they share — lives in **[`docs/environment-yaml-schemas.md`](docs/environment-yaml-schemas.md)**; this section only covers the parts relevant to adding a new environment.

### `.env.example` Format

Only skip this file if the environment genuinely has nothing to configure — no ports, no secrets, no container names to declare (`pi-barebones` is the one environment that does without it). Every variable needs a `#` comment immediately above it — that comment becomes the form label shown to the user:

```ini
# Name used by the dashboard to track container state.
CONTAINER_NAME=my-app

# Port to expose the web UI on.
WEB_PORT=8080

# Leave blank to force the user to set it explicitly.
API_SECRET_KEY=

# Absolute path, or a leading ~ — expanded to the current user's actual
# home directory when the TUI writes .env (see below).
INSTALL_PATH=~/my-app
```

A leading `~` (a bare `~`, or `~/...`) in any field's value — whether typed into the form or left as an `.env.example` default — gets expanded to the current user's actual home directory before being written to `.env`. This is deliberate, not incidental: every value the TUI writes gets single-quoted so `$`-bearing secrets (e.g. a bcrypt hash) survive round-tripping through the form without bash trying to expand them — but single quotes suppress `~` expansion exactly the same way, so without this, a `~`-based default would end up as a literal, permanently-broken `~/my-app` in `.env` instead of an actual path. `~otheruser/...` (someone else's home directory) is intentionally left untouched. Prefer `~` over hardcoding `/home/pi/...` for any install-path-shaped default — it resolves correctly regardless of OS or username, where a Pi-specific literal silently breaks for anyone else (see `nanoclaw`/`nanoclaw-mnemon`'s own `NANOCLAW_INSTALL_PATH`).

**A leading `~` is treated as home-directory shorthand unconditionally — there's no per-field "is this actually a path" detection.** The writer has no concept of field types; it only ever looks at the first character(s) of the value itself. This is intentional (no naming convention like `*_PATH`/`*_DIR` to invent, learn, or keep consistent across every environment's `.env.example`) but does mean the rule is global: **never start a non-path value with `~` in `.env.example`** — there's no escape hatch, and it would get silently, incorrectly expanded to a home directory path the same way a real path does. In practice this has never come up (no port, container name, password, API key, or timezone value has any reason to start with `~`), but it's a real constraint on any value you write there, not just on ones that happen to be paths.

**This expansion happens exactly once, at the moment `deploy.sh`'s TUI writes `.env` — `~` does *not* work as a live placeholder inside `.env` itself.** `run.sh` just `source`s `.env` as a plain bash script; nothing re-expands `~` on every run. If you hand-edit `.env` directly (bypassing the TUI) and write `~/something`, whether it resolves depends entirely on bash's own quoting rules at that moment — and since every value the TUI itself writes is single-quoted (the convention used throughout every `.env` this repo produces), a hand-typed `~` inside quotes there stays a literal, non-expanding `~` forever. Always write an absolute path when editing `.env` by hand; only rely on `~` in `.env.example` (or the TUI form), never in `.env` itself.

### `CONTAINER_NAME`

A single name for the environment's **primary** container — never space-separated, even for a multi-container stack. There's no generic orchestrator tracking mechanism that reads this as a list; each archetype reads it directly, the same way any other `.env` variable would:

- **`docker-compose.yml`**: Compose's own `${VAR}` substitution — `container_name: ${CONTAINER_NAME:-my-app}`.
- **`run.sh`**: a plain bash default — `CONTAINER_NAME="${CONTAINER_NAME:-my-app}"`.

For a multi-service `docker-compose.yml`, every service *other* than the primary gets prefixed with this value, but only when it's actually set — so an unmodified deployment keeps every service's original bare name, and a customized one gets `<name>-servicename` for all of them:

```yaml
services:
  pihole:
    container_name: ${CONTAINER_NAME:-pihole}                      # primary
  wg-easy:
    container_name: ${CONTAINER_NAME:+${CONTAINER_NAME}-}wg-easy   # prefixed only if set
```

See `pihole-wireguard/docker-compose.yml` for a real example spanning 13 services.

```ini
CONTAINER_NAME=my-app
```

`desktop-entries.yaml`'s `deployed_check` needs this exact same resolved value to know whether the environment is actually running. For a `docker-compose.yml`-based environment, point it at the primary service instead of restating the name — see `from_compose_service` in `docs/environment-yaml-schemas.md`.

**Running more than one instance of the same environment side by side** works the same way for any environment, not just one built specifically for it: copy the whole environment folder, give the copy's `.env` a distinct `CONTAINER_NAME` (and any other value that must not collide — ports, install paths), and deploy it independently. Docker Compose's own project scoping (derived from the directory name, since nothing in this repo pins `-p`/`COMPOSE_PROJECT_NAME`) plus this per-service `CONTAINER_NAME` parameterization is what keeps two copies from colliding on containers or named volumes. `desktop-entries.yaml`'s `entries[].id`/`menu.id`/`info.id` are **not** part of that — they're fixed literals, not `${CONTAINER_NAME}`-expanded, so a second copy's desktop shortcuts overwrite the first's rather than creating separate ones (the containers/volumes themselves are unaffected). See `claude-cli`'s README ("Running Multiple Instances") for a fully worked example, including that caveat in practice.

### Archetype 1: `run.sh` (Custom Script)

**Use this when** you need something Archetype 2's generic fallback structurally cannot express — see "Routing Priority" above for exactly what it already covers on its own (safe build-before-teardown `CLEAN`, data-dir pre-creation, desktop refresh). Concretely, that means:
- Host-level configuration outside Docker entirely (sysctls, netplan/network config, nftables rules, systemd/launchd units, `apt-get install` on the host)
- An interactive, `--rm` foreground session with its own attach/reattach state machine (exec into a running container, `docker start` a dormant one, or launch fresh) — Compose's `up -d` model has no equivalent for this, regardless of what runtime flags the container itself needs
- A container lifecycle that isn't a static, discoverable set of containers at all — a host service that spawns containers dynamically at runtime, or delegates entirely to an external installer
- CLEAN rollback snapshotting, or any other deploy-time behavior beyond "build/pull, then swap"

Note what's *not* on this list: hardware/network passthrough flags (`--privileged`, `--net=host`, `--device`) alone aren't a reason by themselves — `docker-compose.yml` can express all of those natively (`privileged:`, `network_mode: host`, `devices:`). `run.sh` earns its place when one of the flags above needs *combining* with them (an interactive attach state machine, for instance), not from the flags in isolation.

**`run.sh` is itself one of a few subtypes**, depending on what it actually orchestrates underneath — `deploy.sh`'s own Environments menu labels each one accordingly (this list reflects what's actually in this repo today, not an exhaustive taxonomy — there may be others):

| Subtype | Menu label | Real example(s) | What `run.sh` does |
|---|---|---|---|
| Calls a local `Dockerfile` directly | `[run.sh + Dockerfile]` | `dragonos-sdr`, `kali-pentest`, `nanoclaw`/`nanoclaw-mnemon` (`container` deploy mode) | Builds/runs its own single container with an interactive attach/reattach state machine, plus `--privileged`/`--net=host`/`--device` (`dragonos-sdr`/`kali-pentest`), or a Dockerfile that provides a runtime for an external installer to run inside rather than building the app itself (`nanoclaw`/`nanoclaw-mnemon` — see below) |
| Calls a local `docker-compose.yml` | `[run.sh + Compose]` | `pihole-wireguard`, `ntopng` | Compose owns the container(s); `run.sh` exists for host-level prerequisites around it (`pihole-wireguard`) or just a FAST-reattach shortcut before delegating to Compose (`ntopng`) |
| Clones and delegates to a 3rd-party repo | `[run.sh: 3rd-party repo]` | `internet-pi`, `nanoclaw` (`host` deploy mode) | No local `Dockerfile`/`docker-compose.yml` at all — clones an external project and hands off to its own installer (`internet-pi`'s `ansible-playbook`, `nanoclaw`'s interactive Node wizard) |
| Pure host provisioning, no containers | `[run.sh: host-only]` | `pi-barebones` | `apt-get install`, `.bashrc` injection, a `systemd`/`launchd` unit — never touches Docker at all |

`nanoclaw` straddles two of these rows on purpose: it clones and delegates to a 3rd-party installer in both of its deploy modes, but in `container` mode that installer runs *inside* a container built from a local `Dockerfile` that provides the runtime (Node.js, pnpm, `docker` CLI) rather than baking NanoClaw's own source into the image — see its README's "Deployment Modes" section for the full design (including why the bind mount must use the identical path on both sides of the container boundary).

Whatever the subtype, the same rules apply:

**What must be in the environment:** `run.sh` itself, checked into git as executable (`chmod +x` — `deploy.sh` defensively re-`chmod`s it before every run, but a non-executable `run.sh` still fails for anyone invoking it directly; this has bitten this repo before). It's fine to *also* have a `docker-compose.yml` and/or `Dockerfile` alongside it when one is the right fit for the container(s) themselves but the environment needs something extra around it — `run.sh` still takes priority and is expected to invoke `$DOCKER_COMPOSE`/`docker build` itself in that case; the generic fallback is never reached.

**What its README must document:** a "⚙️ Why This Needs a Custom `run.sh`" section, listing concretely what it does that Archetype 2 can't — not just "it's complex," but the specific flags/behaviors from the bullet list above, and which subtype it is. See `dragonos-sdr`, `kali-pentest`, `nanoclaw`, `pi-barebones`, and `pihole-wireguard`'s READMEs for real examples of each case. If you can't articulate a concrete reason, use Archetype 2 instead — `portainer` used to have a `run.sh` for no real reason beyond historical inertia, and it was removed once that became clear.

Key rules:
- **Never** hardcode `docker` — use `DOCKER=${DOCKER_CMD:-docker}` to inherit the sudo wrapper
- Source `.env` with `set -a; source "$SCRIPT_DIR/.env"; set +a`
- Create volume paths with `mkdir -p` *before* `docker run` — otherwise Docker creates them as root
- Re-bind TTY with `exec 0</dev/tty` before any `-it` container so it works when invoked via `curl | bash`

```bash
#!/bin/bash
DOCKER=${DOCKER_CMD:-docker}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a; source "$SCRIPT_DIR/.env"; set +a
fi

IMAGE_NAME="my-app:latest"
IMAGE_EXISTS=$($DOCKER images -q "$IMAGE_NAME" 2>/dev/null)

$DOCKER stop "$CONTAINER_NAME" 2>/dev/null
$DOCKER rm   "$CONTAINER_NAME" 2>/dev/null

if [ "${REBUILD_POLICY:-FAST}" = "CLEAN" ] || [ -z "$IMAGE_EXISTS" ]; then
    $DOCKER build --no-cache -t "$IMAGE_NAME" "$SCRIPT_DIR"
fi

mkdir -p "${HOST_DATA_PATH:-$SCRIPT_DIR/data}"

exec 0</dev/tty; exec 1>/dev/tty; exec 2>/dev/tty

$DOCKER run -it --rm \
  --name "$CONTAINER_NAME" \
  -v "${HOST_DATA_PATH:-$SCRIPT_DIR/data}:/data" \
  "$IMAGE_NAME"
```

### Archetype 2: `docker-compose.yml` (Generic Fallback)

**Use this when** the environment is one or more long-running services with no host-level configuration needed around them — including a genuinely simple single-container one. This is the preferred archetype for anything that fits, and that includes cases that might look at first like they need a bare `Dockerfile`: a one-service compose file with `build: .` handles those too, with real volume/port/flag support the bare-`Dockerfile` fallback doesn't have (see "Routing Priority" above for why that fallback is best avoided entirely). Only reach for Archetype 1 if you have a concrete reason from the list above.

**What must be in the environment:** `docker-compose.yml`, with the primary service's `container_name:` set to `${CONTAINER_NAME:-<default>}` (every other service prefixed the same way — see `CONTAINER_NAME` above). Docker Compose picks up the generated `.env` automatically — no explicit `--env-file` needed. `lib/deploy-lib.sh`'s generic fallback drives it directly (`compose pull` + `compose build --no-cache` before `compose down`/`compose up -d` on `CLEAN`, `compose stop`/`compose down` for `STOP`/`TEARDOWN`), so no `run.sh` is required at all unless something outside the stack itself is needed. `privileged:`, `network_mode: host`, `devices:`, and arbitrary `ports:`/`volumes:` are all fair game here — none of that requires `run.sh` on its own.

**What its README must document:** the standard baseline — a Services & Ports table, Data Directories, Desktop Integration, Useful Commands (see the Folder Layout section above). No "why run.sh" section needed if there isn't one; that's the common, preferred case.

```yaml
services:
  myapp:
    container_name: ${CONTAINER_NAME:-my-app}
    build: .              # or image: myimage:latest, if pulling from a registry
    ports:
      - "${WEB_PORT:-8080}:8080"
    restart: unless-stopped
```

### `info.yaml` (Recommended)

Nearly every environment has one — it's not optional in practice. `run.sh` (or the generic Compose fallback) calls it at the end of every deploy for the post-deploy summary; `deploy.sh`'s `INFO` and `WIPE` policies delegate to it entirely (they don't touch containers directly at all); `backup.sh` reads it (via a `manifest` action) to discover which data directories and named volumes to archive; and it's what generates `post-deploy-info.html`, the page the desktop "Info" icon opens. Skip it and INFO, WIPE, backup, and the info desktop entry all silently do nothing for that environment.

Declarative YAML, not a script — every caller goes through `lib/run-info.sh <env_dir> <action>`, which calls `lib/info-lib.sh`'s `run_info_yaml` to read it directly. No `info.sh` needed unless the environment has real branching (see below):

```yaml
data_dirs:
  - path: "${SCRIPT_DIR}/my-app-data"
    description: "My app's config and database"
web_uis:
  - name: "My App"
    url: "http://${HOST_IP}:${WEB_PORT:-8080}"
useful_commands: |2
     docker logs -f my-app
```

`${VAR}`/`${VAR:-default}` markers get resolved against `.env` (if present) and a couple of synthetic variables (`SCRIPT_DIR`, `HOST_IP`) — `.env.example` itself is never sourced, so every `.env`-driven marker needs its own explicit `:-default` matching that variable's `.env.example` default (`WEB_PORT` above defaults to `8080` because that's what `.env.example` documents; a marker with no default silently renders blank if `.env` doesn't set that key). Every field, the full substitution mechanism, and — importantly — the `useful_commands` block-scalar indentation trap (a plain `|` silently strips a uniformly-indented block's leading spaces to zero; always use `|2`) are documented in **[`docs/environment-yaml-schemas.md`](docs/environment-yaml-schemas.md)**.

Also in there: `custom_actions` — an environment's own extension point for adding brand-new items to `deploy.sh`'s per-environment action menu, beyond the fixed `FAST`/`STOP`/`TEARDOWN`/`CLEAN`/`INFO`/`WIPE` set (`nanoclaw-mnemon`'s "Scaffold a Wiki for a Group" and "Check / Restart Ollama" entries are real, working examples).

**Only add an `info.sh` override** if the environment needs something `info.yaml` genuinely can't express as static data — a conditional field set (`internet-pi`'s `PIHOLE_ENABLE`/`MONITORING_ENABLE` flags deciding which web UIs even exist) or an OS-dependent value (`nanoclaw`'s host-vs-macOS service commands). Call `_load_info_yaml` first for everything that *is* static, override just the one thing that varies, then call `run_info` directly — see `nanoclaw/info.sh` or `internet-pi/info.sh` as templates. `ACTION` is always one of `list` (terminal + regenerates `post-deploy-info.html`), `delete` (the `WIPE` policy, with a confirmation prompt), `manifest` (machine-readable, used by `backup.sh`), or `list-dirs` (machine-readable `data_dirs` paths only, one per line, used by `deploy.sh`'s generic fallback path) — none of these are something you call yourself.

### `desktop-entries.yaml` (Recommended if there's a menu-launchable target)

Not just web UIs — `entries[].kind: exec` covers X11 GUI apps (`dragonos-sdr`'s GQRX/GNU Radio Companion, launched via X11 socket passthrough) and terminal launchers (SDR menu, Kali, NanoClaw) just as much as `kind: link` covers browser-opened web UIs. Skip this only if the environment has no menu-launchable target at all (`pi-barebones` has none; `internet-pi`'s ports come from an externally-managed Ansible playbook rather than this repo's own `.env`, which is why it doesn't have one either — worth reconsidering if that ever changes). `install-desktop-entries.sh` at the repo root discovers every environment directory automatically and dispatches to `lib/run-install-desktop.sh` for each — nothing else needs registering it.

```yaml
menu:
  id: my-environment
  name: My Environment
  icon: network-server
deployed_check:
  kind: container              # or "marker" or "systemd" — see the schema doc
  value: "${CONTAINER_NAME:-my-app}"   # or, for a docker-compose.yml-based
                                # environment, from_compose_service: myapp
                                # instead — see below
entries:
  - id: pi-bootstrap-my-app
    name: "My App"
    comment: "What it does"
    icon: network-server
    kind: link                 # or "exec" — see the schema doc
    target: "http://localhost:${WEB_PORT}"
info:
  id: pi-bootstrap-my-environment-info
  name: "My Environment Info"
```

`deployed_check.kind` covers the three mechanisms actually in use across the current environments — `container` (`docker ps -a --filter name=^/<value>$`, for anything that stays running), `marker` (a `.deployed` file `run.sh` touches right before launch, for `--rm` containers where a cached image alone doesn't prove it was ever used), or `systemd` (a registered unit, for host-level installs like `nanoclaw`). For a `container`-kind check on a `docker-compose.yml`-based environment, prefer `from_compose_service: <service-key>` over `value:` — it reads the name straight out of that service's own `container_name:` field instead of carrying a second copy of it.

`entries[].kind` is `link` for a plain URL open (→ `install_link_icon`, which writes both the application-menu entry and the Desktop icon — see below) or `exec` for anything that isn't a plain URL (X11 passthrough, `docker exec`, a terminal launcher — `target` is then the full `Exec=` command string, and an optional `terminal: true/false` controls the `Terminal=` field, default `false`).

Full schema (every key, valid values, the same `${VAR}` substitution mechanism `info.yaml` uses): **[`docs/environment-yaml-schemas.md`](docs/environment-yaml-schemas.md)**.

**Only add an `install-desktop.sh` override** for real branching that isn't expressible as static YAML — `nanoclaw` is the one example today (host-vs-container deploy-mode detection changes both `deployed_check.kind` and its systemd-vs-container check). Call `_load_desktop_entries_yaml` first for everything that *is* static, set `DEPLOYED_CHECK_KIND`/`DEPLOYED_CHECK_VALUE` yourself, then call `run_desktop_install` directly — see `nanoclaw/install-desktop.sh`.

Every environment gets its **own submenu** (`register_submenu`, called automatically by `run_desktop_install`) rather than scattering entries into existing categories like Internet or System Tools — `Categories=` is derived from `menu.id` automatically too, never set it yourself. `install_link_icon` writes both the application-menu entry (`Type=Application`, browser-fallback `Exec=`) and the Desktop icon (`Type=Link`) — these are deliberately two different desktop-entry flavors, not the same file copied twice, because `Type=Link` is silently filtered out of the menu on some desktop environments.

### Registering with `backup.sh`

Unlike `info.yaml`/`desktop-entries.yaml` (discovered automatically per-environment), "is this environment actually deployed, or just configured-but-never-run" is a manually-maintained `case` statement inside the **root** `backup.sh`'s `is_deployed()` function — add your environment there so `backup.sh` doesn't skip its data or, conversely, doesn't try to back up an empty shell that was only ever set up in the TUI wizard:

```bash
my-environment)
    $DOCKER ps -a --filter "name=^/my-app$" -q 2>/dev/null | grep -q .
    ;;
```

Environments without a case here fall through to the default (`*) true ;;`) — always treated as deployed, which is harmless but less precise than an explicit check.

---

## 📋 Project Notes

Repo-wide notes that don't belong in any single environment's own README:

- **[`docs/lessons-learned.md`](docs/lessons-learned.md)** — cross-cutting
  things discovered the hard way that generalize across the whole repo
  (checking `origin/master` for unrelated work before every push, a
  merged PR's branch being done for good, etc.).
- **[`docs/lessons-learned/`](docs/lessons-learned)** — one file per
  environment, the detailed found-it/fixed-it account for that
  environment's own real-world debugging sessions (e.g.
  `nanoclaw-mnemon.md`'s `mnemon setup --global` saga, `claude-cli.md`'s
  first-deploy issues).
- **[`docs/refactoring-opportunities.md`](docs/refactoring-opportunities.md)**
  — known, real code duplication deliberately left alone until a genuine
  third use case justifies extracting it, with the reasoning for why and
  what would change that.
- **[`docs/future-enhancements/`](docs/future-enhancements)** — design
  proposals and hardening plans for not-yet-fully-verified features (Pi-hole
  HA, additional `pihole-wireguard` services, `claude-cli`'s gateway
  redirect, generalizing `claude-cli`'s multi-instance pattern), one file
  per topic.
- **[`docs/pending-activities.md`](docs/pending-activities.md)** — a
  snapshot of currently open follow-ups; GitHub's own PR/issue state is
  always the source of truth, this is a convenience index that goes stale
  the moment something's resolved — prune it accordingly rather than
  trusting it blindly.
