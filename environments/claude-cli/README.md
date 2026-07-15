# Claude CLI — Standalone, Remote-Accessible Container

A single container running the `claude` CLI against a git repo (or any
directory) you point it at, reachable directly over its **own SSH server**
from any machine holding the matching private key — no NanoClaw, no channel
bots (Telegram/Discord/etc.), no Docker-outside-of-Docker orchestrator
spawning sibling containers. If you want Claude to have a chat presence on
Telegram/WhatsApp/etc. and its own conversation-group model, use the
`nanoclaw` or `nanoclaw-mnemon` environments instead — this one is for the
simpler case: you, a terminal, and a repo, from wherever you happen to be.

No custom `run.sh` — this is a plain `docker-compose.yml` with `build: .`,
using `deploy.sh`'s generic fallback directly.

---

## 🧭 How Login Works

SSH in and you land straight into a **persistent, detachable `tmux`
session** running `claude` in your workspace — not a fresh shell each time:

```bash
ssh -p ${SSH_PORT:-2222} claude@<host>
```

That's `/etc/profile.d/claude-tmux-attach.sh` (see `bashrc-tmux-attach.sh`)
running `tmux new-session -A -s claude -c ~/workspace claude` on every
interactive login — `-A` means *attach if it exists, create if it
doesn't*. Close the terminal, lose your WiFi, SSH in from a different
device entirely — reconnecting drops you back into the exact same live
conversation, not a new one. Detach on purpose with the usual tmux prefix
(`Ctrl-b d`) if you want to leave it running and step away deliberately.

`ssh host some-command` (a non-interactive, non-login invocation) skips
this entirely and just runs `some-command` — scripted SSH use is
unaffected.

---

## 🌐 Why a Container-Own `sshd` Instead of Host SSH + `docker exec`

`nanoclaw-mnemon`'s own README documents the other pattern (SSH to the
host, then `docker exec -it ... claude`) — that works fine if you already
have, and are comfortable granting, a full host shell account. This
environment is for the case where you'd rather hand out access to
**exactly this container and nothing else on the host** — reachable at its
own mapped port, authenticated by its own `authorized_keys`, with no host
account or `docker` group membership required for whoever's connecting.

By default `SSH_AUTHORIZED_KEYS_PATH` (see `.env.example`) points at your
own host's `~/.ssh/authorized_keys` — so anyone who can already SSH into
this machine can also SSH straight into this container, no separate key
setup needed. Point it at a dedicated file instead if you want a narrower
set of keys than your host already trusts.

---

## 🛠️ Prerequisites

- **Docker & Compose Plugin Installed** — see the repo root `README.md` if you haven't set this up yet.
- **An SSH keypair** you control the private half of. If you don't have one: `ssh-keygen -t ed25519`.

---

## 🚀 Deployment & Automation Guide

### 1. Configure your environment

```bash
cd environments/claude-cli
cp .env.example .env
# Set CLAUDE_WORKSPACE_PATH to the repo you want Claude working on.
# Edit SSH_PORT / SSH_AUTHORIZED_KEYS_PATH / PUID / PGID if the defaults don't fit.
```

Or use the repo's interactive `deploy.sh` menu, which walks you through the same `.env` fields.

### 2. Deploy

```bash
./run.sh   # via deploy.sh's generic docker-compose.yml fallback — no custom run.sh here
```

Or straight from `deploy.sh`'s menu — pick **Claude CLI** under **AI Assistants**.

### 3. First login

```bash
ssh -p ${SSH_PORT:-2222} claude@localhost
```

You'll land in the tmux-attached `claude` session. First run prompts Claude's own `/login` OAuth flow — it prints a URL; paste it into a browser on whichever machine you're physically at (same reasoning as `nanoclaw-mnemon`'s own "First-Time Setup": there's no GUI/display inside this container to open one itself). This only needs doing once — the session persists in the `claude-cli_claude_home` named volume.

---

## 🎛️ Deployment Policies

Select a policy when deploying from the `deploy.sh` menu, or set `REBUILD_POLICY` when running `./run.sh` directly:

| Policy | Action |
|--------|--------|
| `FAST` | Start container if not running; otherwise reconcile against `docker-compose.yml` (no rebuild) so config-only edits (e.g. a new `SSH_PORT`) still take effect |
| `STOP` | Pause the container (resumable with `FAST`) |
| `TEARDOWN` | Stop + remove the container; named volumes and `CLAUDE_WORKSPACE_PATH` untouched |
| `CLEAN` | Rebuild the image fresh, then stop + remove + redeploy |
| `INFO` | List data directories with sizes and useful commands |
| `WIPE` | Delete the `claude-cli_claude_home` and `claude-cli_ssh_host_keys` named volumes (irreversible — signs you out and changes the SSH fingerprint; your workspace repo is untouched, see `info.yaml`'s own confirm message) |

---

## 💾 Data Directories

### Named Docker Volumes

| Volume | Contents |
|--------|---------|
| `claude-cli_claude_home` | Claude CLI's own OAuth/session state (`~/.claude`) — deleting this signs you out |
| `claude-cli_ssh_host_keys` | This container's own SSH host keys — deleting this changes its SSH fingerprint |

### Bind Mount (Yours, Not This Environment's)

`CLAUDE_WORKSPACE_PATH` is your own pre-existing directory (typically a git repo) — this environment never creates, deletes, or claims ownership of it. `WIPE`/`CLEAN`/`TEARDOWN` never touch it. Back it up the same way you already back up any other repo on your host.

---

## 🖥️ Desktop Integration

Run `../../install-desktop-entries.sh` (or the `[Desktop] Install Desktop Entries` option in `deploy.sh`) after deploying to add an application-menu shortcut.

| Desktop entry | Opens |
|:---|:---|
| **Claude CLI (SSH)** | A terminal running `ssh -p <SSH_PORT> claude@localhost`, landing in the live tmux session |
| **Claude CLI Info** | This environment's generated `post-deploy-info.html` in default browser |

---

## 💡 Useful Commands

```bash
# SSH in from this machine or any other holding a trusted key
ssh -p ${SSH_PORT:-2222} claude@<host>

# Same thing, from the host directly, no SSH key needed
docker exec -it claude-cli tmux attach -t claude

# sshd logs
docker logs -f claude-cli

# Pause / resume without losing data
REBUILD_POLICY=STOP ./run.sh
REBUILD_POLICY=FAST ./run.sh
```

---

## 🔒 Security Notes

- **Key-based auth only.** `sshd_config` is patched at build time (`PasswordAuthentication no`, `PermitRootLogin no`) — there's no password to guess, only whoever's public key is in `SSH_AUTHORIZED_KEYS_PATH`.
- **`SSH_PORT` is a real network-facing port.** If this host is reachable from outside your LAN, treat `SSH_PORT` with the same care you'd give the host's own SSH port — don't forward it through your router unless you specifically mean to expose it, and keep `SSH_AUTHORIZED_KEYS_PATH` scoped to keys you actually trust with this access.
- **`PUID`/`PGID` control real host-filesystem ownership.** Files `claude` creates inside `CLAUDE_WORKSPACE_PATH` are written with these UID/GID on the host side, since it's a bind mount — set them to your own `id -u`/`id -g` (not left at the container-only default) if you want files to come out owned by you rather than an arbitrary UID 1000.
- **`claude` inside this container can read/write anything under `CLAUDE_WORKSPACE_PATH`** and run arbitrary commands as the `claude` user — same trust model as running `claude` directly on your own machine in that directory, just remote. It cannot reach anything else on the host filesystem or the Docker socket (unlike NanoClaw's agent containers, this one has no `docker.sock` mount at all).
