# NanoClaw — Personal AI Assistant

A self-hosted AI assistant built on Anthropic's Claude Agent SDK that runs on Raspberry Pi (or macOS). Connects to WhatsApp, Telegram, Slack, Discord, Gmail and other messaging channels, has structured long-term memory, and schedules recurring tasks.

Source: [github.com/nanocoai/nanoclaw](https://github.com/nanocoai/nanoclaw)

---

## How It Works

NanoClaw is not a single Docker container — it spawns an isolated Docker container per conversation group, so each channel's agent gets its own filesystem and Claude session. The orchestrator process that manages that (routes incoming messages, spawns/tears down group containers, delivers responses back) runs in one of two ways — see "Deployment Modes" below:

```
Messaging apps → orchestrator (router) → container (Claude Agent SDK) → orchestrator (delivery) → messaging apps
```

Default persistent memory is per-group: conversation history in the session database, plus `CLAUDE.local.md` (the agent's own notes-to-self, read on every spawn but never overwritten by the host). Structured graph memory (mnemon) and a markdown wiki are both optional, added via NanoClaw's own skills (`/add-mnemon`, `/add-karpathy-llm-wiki`) rather than installed by default — see the separate `nanoclaw-mnemon` environment in this repo if you want mnemon baked in automatically.

---

## 🔒 Deployment Modes

The orchestrator process itself — not the per-conversation-group agent containers, which are always sandboxed in Docker either way — can run two different ways, controlled by `NANOCLAW_DEPLOY_MODE` in `.env` (blank = auto-select by OS: **macOS defaults to `container`, Linux defaults to `host`**):

| | `host` (original) | `container` |
|---|---|---|
| Orchestrator process | Bare `systemd` (Linux) / `launchd` (macOS) service | Runs inside its own Docker container |
| Filesystem access | Everything the OS user account can read/write — the whole home directory, not just NanoClaw's own files | Only `NANOCLAW_INSTALL_PATH` — nothing else on the host is reachable |
| Docker access | Full host Docker daemon access either way (it has to spawn agent containers itself) | Same — via a bind-mounted `/var/run/docker.sock`, unavoidable in both modes |
| iMessage | ✅ Supported (`/add-imessage` skill — see "Adding Channels" below) | ❌ Not offered — needs real macOS Messages.app + TCC (Full Disk Access/Automation) permissions, which no Docker container can reach even on macOS (Docker Desktop always runs containers inside a Linux VM) |

**The actual security improvement in `container` mode is scoped filesystem access, not less Docker access** — the orchestrator still needs full control of the Docker daemon either way, since spawning/tearing down agent containers is its whole job. What changes is that a compromised or buggy orchestrator process can no longer read your SSH keys, browser data, or anything else outside `NANOCLAW_INSTALL_PATH` — in `host` mode, as a bare OS process, it has the exact same file access as your own login session.

### How container mode actually works

- The orchestrator's `Dockerfile`/`entrypoint.sh` provide the runtime (Node.js, pnpm, the `docker` CLI) — NanoClaw's own source is **not** baked into the image. It's `git clone`d into `NANOCLAW_INSTALL_PATH` at container start, exactly like `host` mode already does, so `git pull` keeps picking up upstream updates without rebuilding this image.
- `NANOCLAW_INSTALL_PATH` is bind-mounted at the **exact same absolute path** on the host and inside the container — not remapped to something like `/workspace`. This matters: NanoClaw spawns its own per-group agent containers via the bind-mounted Docker socket (Docker-outside-of-Docker — those containers are siblings of the orchestrator's, not nested inside it), and any path it passes to `docker run -v <path>:...` is resolved by the **host's** Docker daemon against the real host filesystem, not the orchestrator container's own view of it. Keeping the path identical on both sides is what makes that resolve correctly. Get this wrong and agent containers either fail to spawn or silently mount the wrong directory.
- NanoClaw's own installer (`setup/service.ts`) detects the service manager available and falls back to a plain `nohup node dist/index.js &`-style background launch when neither `systemd` nor `launchd` is present — which is exactly the normal state inside a Docker container, with no special handling needed on NanoClaw's side. `run.sh`'s container-mode `FAST` policy relaunches that same process directly on a restart, without re-running the full interactive wizard.
- First install still needs the same interactive wizard as `host` mode (Anthropic API key, first channel setup) — `run.sh` runs it via `docker exec -it nanoclaw bash -lc 'cd $NANOCLAW_INSTALL_PATH && bash nanoclaw.sh'` against the already-running orchestrator container, with the same `exec 0</dev/tty` rebinding every other interactive environment in this repo uses so it still works when invoked via `curl | bash`.

### What's verified vs. what isn't

The control flow above (`FAST`/`STOP`/`TEARDOWN`/`CLEAN`, image build, container create/start/reattach, the exact `docker run` mount flags) was verified against a stubbed `docker` binary exercising the real `run.sh` code paths, and the interactive wizard itself has since been run end-to-end for real, live, inside `container` mode. That live run surfaced several real gaps between NanoClaw's own setup assumptions and this specific container topology (no init system at all, no real `docker` CLI plugins, headless), all now fixed here rather than upstream — see `Dockerfile`, `entrypoint.sh`, and `systemctl-shim.sh`'s own comments for exactly what and why. It also settled an open question: **NanoClaw has no web UI by default at all** — confirmed directly in its own README ("no monitoring dashboard or debugging UI — describe the problem in chat"). `NANOCLAW_PORT`/the `-p` port mapping only pre-reserves a port on the container in case you later add its optional `/add-dashboard` skill; nothing listens there out of the box, in either deploy mode.

---

## ⚙️ Why This Needs a Custom `run.sh`

`deploy.sh`'s generic fallback (no `run.sh`) only knows how to build/run a Docker image or `docker compose up` a stack — it has no concept of anything outside Docker, and no concept of an interactive first-run wizard either. Depending on deploy mode, NanoClaw needs a custom script for different reasons:

- **`host` mode — OS-level service management**: registers and controls a `systemd` unit (Linux) or `launchd` plist (macOS), detected and driven via `systemctl`/`launchctl` rather than `docker`. Two different OS service managers, neither of which the generic fallback or `deploy-lib.sh` has any notion of.
- **`container` mode — the same interactive-attach state machine `dragonos-sdr`/`kali-pentest` need**: build the image if missing, reattach if the container's already running, restart if dormant, or hand off to the interactive setup wizard via `docker exec -it` if this is a fresh install — Compose's `up -d` model has no equivalent for any of that.
- **Cloning and handing off to an external installer, in both modes** — `git clone`s the upstream NanoClaw repo, then hands the terminal over to its own interactive `nanoclaw.sh` setup wizard (Node.js/pnpm install, Anthropic API key registration, first channel config). This is a multi-step, stateful, interactive first-run flow — not a single `docker run`/`compose up`.
- **Per-conversation-group container spawning, in both modes** — NanoClaw itself creates and manages a separate Docker container per messaging channel/group at runtime; `run.sh` never touches those directly, so there's no single "the container" for a generic archetype to even target.
- **`TEARDOWN`'s agent-container sweep** — finds and removes every `nanoclaw-agent-v2-*`-prefixed container by image name pattern, since these are spawned dynamically by NanoClaw's own router, not declared anywhere `deploy.sh` could discover statically.

None of this is a Docker Compose fit either — Compose describes a fixed set of services, but the actual per-group containers here are created dynamically at runtime by the orchestrator, with a lifecycle only NanoClaw's own router controls, and Compose's `up -d` model has no equivalent for the interactive first-run wizard `container` mode still needs.

---

## 🔧 Tools & Projects

| Tool | Link | Description |
|------|------|-------------|
| NanoClaw | [github.com/nanocoai/nanoclaw](https://github.com/nanocoai/nanoclaw) | Self-hosted AI assistant built on Claude — routes messages from WhatsApp, Telegram, Slack, and Discord to isolated per-group agent containers |
| Anthropic Claude | [anthropic.com](https://www.anthropic.com) | Large language model powering each agent's reasoning, memory recall, and task execution |

---

## Deployment

### First Time
The deploy menu calls `run.sh`, which clones the NanoClaw repository into `NANOCLAW_INSTALL_PATH` and hands off to the **interactive `nanoclaw.sh` wizard** — in `container` mode, via `docker exec -it` into the already-running orchestrator container; in `host` mode, directly on the terminal. The wizard will:
- Install Node.js, pnpm if missing
- Register your Anthropic API key
- Build the agent container
- Configure your first messaging channel

Configure `NANOCLAW_INSTALL_PATH` in `.env` to control where it installs (default: `~/nanoclaw`, expanded to your actual home directory — see the root README's `.env.example` Format section), and `NANOCLAW_DEPLOY_MODE` to control which mode is used (blank = auto by OS — see "Deployment Modes" above).

### Subsequent Runs
`FAST` policy detects the running service (`systemd`/`launchd` in `host` mode, the `nanoclaw` container in `container` mode) and starts it if stopped. No reinstall.

### CLEAN Policy
Stops and removes the existing installation (and, in `container` mode, rebuilds the orchestrator image first), then re-runs the full wizard.

---

## Configuration (`.env`)

| Variable | Purpose | Default |
|----------|---------|---------|
| `NANOCLAW_INSTALL_PATH` | Where the repo is cloned (bind-mounted at the same path in `container` mode) | `~/nanoclaw` |
| `NANOCLAW_PORT` | Reserved on the container for NanoClaw's optional `/add-dashboard` skill — not used by anything installed by default (see "What's verified vs. what isn't" above) | `3080` |
| `NANOCLAW_DEPLOY_MODE` | `container`, `host`, or blank for the OS-based default | blank (auto) |

The Anthropic API key is registered interactively by the wizard and stored by NanoClaw's own credential proxy (OneCLI). Do not put it in `.env`.

---

## Adding Channels

**Channels are no longer standalone `setup/add-*.sh` scripts** — a recent upstream NanoClaw change moved every channel (Telegram, WhatsApp, Discord, Slack, Signal, Teams, iMessage) out of trunk entirely ("NanoClaw doesn't ship channels in trunk", per the skills' own docs) and into Claude Code skills that pull the adapter code in on demand. If you've seen older instructions telling you to `bash setup/add-telegram.sh`, that script genuinely no longer exists.

**Current procedure**: start an interactive Claude Code session against the orchestrator's own NanoClaw checkout — directly on the host in `host` mode, via `docker exec` in `container` mode:

```bash
# host mode
cd ~/nanoclaw && claude

# container mode
docker exec -it nanoclaw bash -lc "cd \$NANOCLAW_INSTALL_PATH && claude"
```

Then, inside that session, run the skill for whichever channel you want: `/add-telegram`, `/add-whatsapp`, `/add-discord`, `/add-slack`, `/add-signal`, `/add-teams`, or `/add-imessage` (macOS `host` mode only — see "Deployment Modes" above; not offered in `container` mode at all). Each one walks you through it interactively: copies in that channel's adapter code, asks for whatever credential it needs (e.g. Telegram: create a bot via **@BotFather**, paste the token), restarts the service automatically, then runs a pairing/linking handshake (a one-time code, or a QR/pairing code for WhatsApp) so the service knows which chat is yours.

---

## 💾 Data Directories

Persistent data lives inside the install path and survives `TEARDOWN` **and** `CLEAN`:

| Directory | Contents |
|-----------|---------|
| `~/nanoclaw/groups/` | Per-group files: conversation history, memory wiki, transcripts, CLAUDE.md |
| `~/nanoclaw/data/` | Sessions, message database, task scheduler database, IPC streams |
| `~/nanoclaw/.env` | Anthropic/channel credentials NanoClaw's own wizard collected |
| `~/nanoclaw/store/` | Channel session state (e.g. WhatsApp pairing) |

`CLEAN` keeps the install directory's own NanoClaw source in sync with upstream (`git reset --hard`, which only ever touches git-tracked files — the paths above are all in NanoClaw's own `.gitignore`, so they're untouched by construction). The directories above are still the actual state worth backing up separately regardless, since `CLEAN` is not a substitute for real backups.

> **Fixed bug, was a known gotcha — `CLEAN` used to silently strip any channel/provider skill's wiring.** NanoClaw's Claude Code skills (`/add-telegram`, `/add-whatsapp`, `/add-discord`, etc.) install by copying in new **untracked** source files *and* editing existing **tracked** trunk files — a self-registration import appended to `src/channels/index.ts`, a new dependency line in `package.json`. `reset --hard` only discards uncommitted changes to tracked files, so it used to silently revert that wiring while leaving the new (untracked) channel files sitting there looking fully installed — no error, nothing in the logs, the channel just never loaded again. Confirmed against a real deploy on the `nanoclaw-mnemon` environment (same mechanism, same upstream NanoClaw) — see that environment's README for the full write-up. `run.sh` now snapshots any locally-modified tracked files as a patch before the reset and tries to reapply it afterward, restoring the wiring automatically in the common case; if upstream genuinely touched the same lines, it falls back to warning (with the affected files and the saved patch's path) instead of forcing a conflict — re-run that channel/provider skill (e.g. `/add-telegram` again) in that case to restore it by hand.

**Back up before CLEAN or WIPE:**

```bash
cp -r ~/nanoclaw/groups ~/backup/nanoclaw-groups
cp -r ~/nanoclaw/data   ~/backup/nanoclaw-data
```

---

## 🎛️ Deployment Policies

| Policy | Action |
|--------|--------|
| `FAST` | Start the orchestrator (service or container, depending on deploy mode) if stopped; skip if already active |
| `STOP` | Stop the orchestrator (agent containers keep running) |
| `TEARDOWN` | Stop the orchestrator + remove all agent containers; data untouched. In `container` mode, also removes the orchestrator container itself (image and install path are preserved) |
| `CLEAN` | Stop the orchestrator, remove agent containers, hard-sync the install path's NanoClaw source to latest upstream (git-tracked files only — `.env`/`groups/`/`data/`/`store/` untouched), rebuild and restart in place if this was an existing install. In `container` mode, also rebuilds the orchestrator image first, before touching anything running |
| `INFO` | List data directories with sizes and useful commands (scrollable via `less` in an interactive terminal) |
| `WIPE` | Delete `groups/` and `data/` only (install dir preserved) |

---

## 🖥️ Desktop Integration

On a Pi with a desktop environment, run once from the repo root:

```bash
./install-desktop-entries.sh
# or just this environment on its own:
./environments/nanoclaw/install-desktop.sh

# To remove entries (also in the deploy.sh menu as "Uninstall Desktop Entries"):
./install-desktop-entries.sh --uninstall
```

This installs a **NanoClaw AI** entry that opens the environment in your desktop's default terminal emulator.

The script checks whether the orchestrator is actually deployed before registering the entry — the `nanoclaw.service` systemd unit in `host` mode, or the `nanoclaw` container in `container` mode (same OS-based auto-detection as `run.sh`, overridable via the same `NANOCLAW_DEPLOY_MODE`) — printing a warning and exiting cleanly if it hasn't been deployed yet, and removing the entry automatically if it's later uninstalled. Deploy this environment first, then re-run to install the entry.

---

## 💡 Useful Commands

```bash
# --- host mode ---
# Service status and live logs
systemctl status nanoclaw
journalctl -u nanoclaw -f

# Restart after config change
sudo systemctl restart nanoclaw

# Register or update Anthropic API key
cd ~/nanoclaw && bash setup/register-claude-token.sh
# Add channels (see "Adding Channels" above — /add-telegram, /add-whatsapp, etc., not scripts)
cd ~/nanoclaw && claude

# --- container mode ---
# Orchestrator status and live logs
docker ps --filter name=nanoclaw
docker logs -f nanoclaw

# Restart after config change
docker restart nanoclaw

# Register or update Anthropic API key
docker exec -it nanoclaw bash -lc "cd \$NANOCLAW_INSTALL_PATH && bash setup/register-claude-token.sh"
# Add channels (see "Adding Channels" above — /add-telegram, /add-whatsapp, etc., not scripts)
docker exec -it nanoclaw bash -lc "cd \$NANOCLAW_INSTALL_PATH && claude"

# --- both modes ---
# List running agent containers
docker ps --filter name=nanoclaw-agent

# Web interface
http://<pi-ip>:3080
```

---

## Notes

- **"SSH into Claude CLI"** in this environment's own `deploy.sh` action menu (`info.yaml`'s `custom_actions`) is a shortcut into the separate, standalone `claude-cli` environment's own SSH session — a plain terminal `claude` conversation alongside NanoClaw's chat-platform one — if you've deployed that environment too. It reads `claude-cli`'s real, live `SSH_PORT` from its own `.env` at the moment you use it, not a hardcoded default, so it stays correct even if you've customized that port.
- **Docker Manager** in the deploy menu will show dynamically-created NanoClaw group containers alongside your other containers — plus the `nanoclaw` orchestrator container itself in `container` mode.
- NanoClaw containers never see raw API keys — a local HTTP proxy (OneCLI) injects credentials at request time. This is true in both deploy modes; `container` mode additionally limits what the *orchestrator itself* can reach on the host filesystem (see "Deployment Modes" above) — it doesn't change credential handling, which was already scoped away from the agent containers before `container` mode existed.
- `container` mode still needs full Docker daemon access (via the bind-mounted socket) to spawn/manage agent containers — that's unavoidable in either mode, since spawning agent containers is the orchestrator's whole job. The security improvement is specifically about *filesystem* access, not Docker access.
- **NanoClaw's own first-run wizard will warn about running as root** (`container` mode's orchestrator image has no `USER` directive, so it runs as root by default) and offer to walk you through creating a non-root Linux user instead. That warning is generic — written for NanoClaw's *host*-mode deployment, where "root" really does mean your whole machine — and isn't aware it's running inside a container here. Creating a non-root user inside the container doesn't meaningfully change this environment's actual exposure: the orchestrator already has the bind-mounted Docker socket regardless of which UID is running inside it, and socket access is root-equivalent on its own (see above) — a non-root process with access to that socket can still reach everything root could via it. It's safe to answer "continue as root" here. The one thing worth knowing either way: `NANOCLAW_INSTALL_PATH` is bind-mounted at the same path on the host, so files the orchestrator writes there are real files on your machine, not container-isolated — if that matters to you, a non-root Linux user may produce more predictable file ownership, but it isn't a meaningful security boundary in this specific setup.
