# NanoClaw — Personal AI Assistant

A self-hosted AI assistant built on Anthropic's Claude Agent SDK that runs on Raspberry Pi (or macOS). Connects to WhatsApp, Telegram, Slack, Discord, Gmail and other messaging channels, has structured long-term memory, and schedules recurring tasks.

Source: [github.com/qwibitai/nanoclaw](https://github.com/qwibitai/nanoclaw)

---

## How It Works

NanoClaw runs as a **host-level Node.js service** (systemd on Linux, launchd on macOS). It is not a single Docker container — instead it spawns an isolated Docker container per conversation group, so each channel's agent gets its own filesystem and Claude session.

```
Messaging apps → host process (router) → container (Claude Agent SDK) → host process (delivery) → messaging apps
```

Memory works in three layers:
1. **Raw sources** — transcripts, articles, web clips
2. **mnemon graph** — structured facts with semantic search via local Ollama embeddings
3. **Wiki pages** — human-readable narrative syntheses browsable in Obsidian

---

## 🔧 Tools & Projects

| Tool | Link | Description |
|------|------|-------------|
| NanoClaw | [github.com/qwibitai/nanoclaw](https://github.com/qwibitai/nanoclaw) | Self-hosted AI assistant built on Claude — routes messages from WhatsApp, Telegram, Slack, and Discord to isolated per-group agent containers |
| Anthropic Claude | [anthropic.com](https://www.anthropic.com) | Large language model powering each agent's reasoning, memory recall, and task execution |
| Ollama | [ollama.com](https://ollama.com) | Local LLM and embedding server — NanoClaw uses it to run `nomic-embed-text` for semantic memory search without sending data to an external API |
| whisper.cpp | [github.com/ggerganov/whisper.cpp](https://github.com/ggerganov/whisper.cpp) | Local voice transcription (optional) — converts voice messages to text on-device using OpenAI's Whisper model compiled for ARM |

---

## Deployment

### First Time
The deploy menu calls `run.sh` which clones the NanoClaw repository and hands off to the **interactive `nanoclaw.sh` wizard**. The wizard will:
- Install Node.js, pnpm if missing
- Register your Anthropic API key
- Build the agent container
- Configure your first messaging channel

Configure `NANOCLAW_INSTALL_PATH` in `.env` to control where it installs (default: `/home/pi/nanoclaw`).

### Subsequent Runs
FAST policy detects the systemd/launchd service and starts it if stopped. No reinstall.

### CLEAN Policy
Stops and removes the existing installation, then re-runs the full wizard.

---

## Configuration (`.env`)

| Variable | Purpose | Default |
|----------|---------|---------|
| `NANOCLAW_INSTALL_PATH` | Where the repo is cloned | `/home/pi/nanoclaw` |
| `NANOCLAW_PORT` | Web UI port | `3080` |

The Anthropic API key is registered interactively by the wizard and stored by NanoClaw's own credential proxy (OneCLI). Do not put it in `.env`.

---

## Adding Channels

After the initial install, each channel has its own add script:

```bash
cd ~/nanoclaw
bash setup/add-telegram.sh
bash setup/add-discord.sh
bash setup/add-whatsapp.sh
bash setup/add-slack.sh
bash setup/add-imessage.sh   # macOS only
```

---

## 💾 Data Directories

Persistent data lives inside the install path and survives `TEARDOWN`:

| Directory | Contents |
|-----------|---------|
| `~/nanoclaw/groups/` | Per-group files: conversation history, memory wiki, transcripts, CLAUDE.md |
| `~/nanoclaw/data/` | Sessions, message database, task scheduler database, IPC streams |

The install directory itself (`~/nanoclaw/`) can be re-cloned by the `CLEAN` policy; the `groups/` and `data/` subdirectories are what actually need backing up.

**Back up before CLEAN or WIPE:**
```bash
cp -r ~/nanoclaw/groups ~/backup/nanoclaw-groups
cp -r ~/nanoclaw/data   ~/backup/nanoclaw-data
```

---

## 🎛️ Deployment Policies

| Policy | Action |
|--------|--------|
| `FAST` | Start service if stopped; skip if already active |
| `STOP` | Stop the nanoclaw service (agent containers keep running) |
| `TEARDOWN` | Stop service + remove all agent containers; data untouched |
| `CLEAN` | Stop service, remove containers, wipe install dir, reinstall |
| `INFO` | List data directories with sizes and useful commands |
| `WIPE` | Delete `groups/` and `data/` only (install dir preserved) |

---

## 🖥️ Desktop Integration

On a Pi with a desktop environment, run once from the repo root:

```bash
./install-desktop-entries.sh
# or just this environment on its own:
./environments/nanoclaw/install-desktop.sh
```

This installs a **NanoClaw AI** entry that opens the environment in your desktop's default terminal emulator.

The script checks whether the `nanoclaw.service` systemd unit exists before registering the entry — it prints a warning and exits cleanly if the service hasn't been installed yet. Deploy this environment first, then re-run to install the entry.

---

## 💡 Useful Commands

```bash
# Service status and live logs
systemctl status nanoclaw
journalctl -u nanoclaw -f

# Restart after config change
sudo systemctl restart nanoclaw

# List running agent containers
docker ps --filter name=nanoclaw-agent

# Register or update Anthropic API key
cd ~/nanoclaw && bash setup/register-claude-token.sh

# Add messaging channels
cd ~/nanoclaw && bash setup/add-whatsapp.sh
cd ~/nanoclaw && bash setup/add-telegram.sh
cd ~/nanoclaw && bash setup/add-discord.sh
cd ~/nanoclaw && bash setup/add-imessage.sh   # macOS only

# Web interface
http://<pi-ip>:3080
```

---

## Notes

- **Docker Manager** in the deploy menu will show dynamically-created NanoClaw group containers alongside your other containers.
- **Ollama** (local embeddings for semantic memory recall) is installed by the wizard and requires ~300 MB for the `nomic-embed-text` model. Pi 4 (4 GB) or Pi 5 recommended.
- **whisper.cpp** (local voice transcription) is optional but requires compilation from source on ARM; the wizard handles this.
- NanoClaw containers never see raw API keys — a local HTTP proxy (OneCLI) injects credentials at request time.
