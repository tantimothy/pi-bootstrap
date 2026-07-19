# Claude CLI — Standalone, Remote-Accessible Container

A single container running the `claude` CLI against a git repo (or any
directory) you point it at, reachable two ways: its **own SSH server**
(any machine holding the matching private key), and — once bootstrapped —
Claude Code's own **`/remote-control`**, reachable from claude.ai/code on
any device with no port exposure at all (see "Using This as Your Remote
Runner" below). No NanoClaw, no channel bots (Telegram/Discord/etc.), no
Docker-outside-of-Docker orchestrator spawning sibling containers. If you
want Claude to have a chat presence on Telegram/WhatsApp/etc. and its own
conversation-group model, use the `nanoclaw` or `nanoclaw-mnemon`
environments instead — this one is for the simpler case: you, a terminal,
and a repo, from wherever you happen to be.

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
running `tmux new-session -A -s claude -c ~/workspace claude --continue` on
every interactive login — `-A` means *attach if it exists, create if it
doesn't*. Close the terminal, lose your WiFi, SSH in from a different
device entirely — reconnecting drops you back into the exact same live
conversation, not a new one. Detach on purpose with the usual tmux prefix
(`Ctrl-b d`) if you want to leave it running and step away deliberately.

`ssh host some-command` (a non-interactive, non-login invocation) skips
this entirely and just runs `some-command` — scripted SSH use is
unaffected.

**`--continue` (not bare `claude`) is what makes this also survive a
*container* restart, not just a dropped connection.** tmux's own session is
in-memory — it doesn't survive anything that kills the container's
processes (`STOP`/`FAST`, `TEARDOWN`+redeploy, `CLEAN`, a plain
`docker restart`), even though your actual conversation history does, since
it's written under `~/.claude` — the `claude_cli_home` named volume. `-A`
only skips re-running the launch command when a live tmux session already
exists to attach to; after a restart there isn't one, so this command runs
fresh and `--continue` is what resumes your most recent conversation
instead of silently starting a blank one. Want a specific *older*
conversation instead of just the latest? Get a plain shell (below) and run
`claude --resume` for an interactive picker.

### Getting a Plain Shell Instead of the `claude` Conversation

Since window 0 of the tmux session runs `claude` directly (not a shell that
happens to launch `claude`), you can't just type a shell command at the
prompt — it goes to `claude` as a chat message instead. Three ways to get
an actual shell, for things like `git`, `gh`, or a one-time `claude mcp
add` (see "Connecting to Home Assistant" below):

- **New tmux window, same connection (recommended):** press `Ctrl-b c` —
  only window 0 was launched with the `claude` command; any window you
  create yourself gets a normal shell. Switch back to the conversation
  with `Ctrl-b n`/`Ctrl-b p` (next/previous window) or `Ctrl-b 0`.
- **A second, non-interactive SSH connection:** `ssh -p ${SSH_PORT:-2222}
  claude@<host> '<command>'` — appending a command skips the tmux
  auto-attach entirely (see above), so it runs and exits without touching
  your live session at all. Good for scripting or a single quick command.
- **From the Docker host directly:** `docker exec -it -u claude
  ${CONTAINER_NAME:-claude-cli} bash`.

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
docker compose up -d
```

Or use `deploy.sh`'s menu instead — pick **Claude CLI** under **AI Assistants**. It also refreshes desktop entries and prints the INFO summary afterward, neither of which a bare `docker compose up -d` does on its own. There's no `run.sh` here — `deploy.sh`'s generic Compose fallback drives this environment directly.

### 3. First login

```bash
ssh -p ${SSH_PORT:-2222} claude@localhost
```

You'll land in the tmux-attached `claude` session. First run prompts Claude's own `/login` OAuth flow — it prints a URL; paste it into a browser on whichever machine you're physically at (same reasoning as `nanoclaw-mnemon`'s own "First-Time Setup": there's no GUI/display inside this container to open one itself). This only needs doing once — the session persists in the `${CONTAINER_NAME:-claude-cli}_claude_home` named volume (see "Running Multiple Instances" below for why that name isn't fixed).

---

## 🧬 Running Multiple Instances

**Fastest path:** once this instance is deployed, its application-menu submenu has a **"New Claude CLI Instance..."** entry (`new-instance.sh`) — it interactively asks for an instance name, SSH port, and workspace path, then does everything described below for you: copies the folder, writes the new `.env`, registers the copy in `config/environments.yaml`, deploys it, and installs its own desktop entries. Every instance carries its own copy of this script, so any instance's submenu can spawn the next one. On macOS (no application-menu submenus), run it directly instead: `./environments/claude-cli/new-instance.sh`.

**By hand:** each instance needs its own copy of this environment's folder (e.g. `cp -r environments/claude-cli environments/claude-cli-work`) — `deploy.sh`'s model is one `.env` per environment directory, not multiple profiles inside one. Give the copy's `.env` a distinct `CONTAINER_NAME`, `SSH_PORT`, and `CLAUDE_WORKSPACE_PATH` (all three must differ, or you'll either collide on the port or point two containers at the same repo), then deploy it independently.

**How the isolation actually works:** there's no custom `run.sh` here (see "Deploy" above) — every lifecycle action goes through `deploy.sh`'s generic Compose fallback, which just runs plain `docker compose` commands (`up -d`/`stop`/`down`/`build --no-cache`) from inside whichever directory you invoke it from. Docker Compose's own project scope defaults to that directory's name (nothing in this repo pins `-p`/`COMPOSE_PROJECT_NAME`), so two differently-named folders are two separate Compose projects automatically — a `CLEAN` run against `claude-cli-work/` never touches whatever's running from `claude-cli/`. The container itself is also always given an explicit `container_name: ${CONTAINER_NAME:-claude-cli}`, so that's really a second, redundant layer keeping instances apart, not the only one.

**Named volumes and the SSH host key follow `CONTAINER_NAME` automatically** — `${CONTAINER_NAME:-claude-cli}_claude_home` and `${CONTAINER_NAME:-claude-cli}_ssh_host_keys` are both derived from it, not fixed literals, so two differently-named instances get fully separate Claude CLI login state and separate SSH host keys, not a shared, colliding one. Confirmed by reading `docker-compose.yml`'s own `volumes:` section — worth checking directly if you ever rename an existing instance's `CONTAINER_NAME` after the fact, since that's effectively a fresh pair of volumes (old ones orphaned, not migrated). `INFO`/`WIPE`/`backup.sh` all read `info.yaml` per-directory too, so each instance's own data listing and backup only ever cover its own two volumes, never a sibling instance's.

Two instances with genuinely distinct `CONTAINER_NAME`s never overwrite each other's containers or volumes — Docker Compose just creates two of everything, side by side.

**Desktop entries follow `CONTAINER_NAME` too** — `desktop-entries.yaml`'s `entries[].id`/`menu.id`/`info.id` are `${CONTAINER_NAME}`-expanded, same as `docker-compose.yml`'s own volume `name:` fields, so a second instance with a distinct `CONTAINER_NAME` installs its own separate `.desktop` files instead of overwriting the first instance's.

**If you copy the folder by hand instead of using "New Claude CLI Instance...":** the copy won't be in `deploy.sh`'s menu ordering. `config/environments.yaml` only lists the original `claude-cli` folder — a copy still shows up (anything under `environments/` not listed there gets appended alphabetically by `deploy.sh`'s own fallback pass rather than hidden), just not grouped under "AI Assistants" with everything else. Add it to `config/environments.yaml` yourself (`new-instance.sh` does this step automatically) if you want it grouped properly.

---

## 🛰️ Using This as Your Remote Runner

Two different remote-access mechanisms apply here, layered rather than competing — one to bootstrap the container, one for ongoing day-to-day use.

### Recommended: Claude Code's own `/remote-control`

Once the container's `claude` session is signed in, run `/remote-control` (or `/rc`) **inside that tmux-attached session** to link it to your claude.ai account. From then on, [claude.ai/code](https://claude.ai/code) on your phone, tablet, or any browser reaches this exact session directly — same conversation, same workspace, same history — with **no port forwarding, no VPN, and no SSH key on the remote device at all**. Your machine only makes outbound HTTPS calls to Anthropic; nothing listens for inbound connections on its behalf.

This is a genuinely good structural fit for this container specifically: `docker-compose.yml` sets `restart: unless-stopped`, and the `tmux` session inside keeps `claude` alive independently of whether anything is attached to it — so the "local process has to stay running" requirement `/remote-control` has is already satisfied just by this container being deployed, not by you keeping a terminal open.

**Prerequisites `/remote-control` needs that this environment doesn't manage**: a Claude Pro/Max/Team/Enterprise subscription (it isn't available on plain API-key billing), and being signed in via `/login` first (see "First login" above — same account, no extra setup).

**What still requires SSH**: `/remote-control` only continues an *existing, already-running* session — you still need at least one SSH connection to get there in the first place (first `/login`, first `/remote-control` to link a device, setting `GH_TOKEN`/registering the Home Assistant MCP server below). After that initial bootstrap, ongoing use can be entirely through `/remote-control` — see "Security Notes" for why you might want to close `SSH_PORT` off entirely once you've reached that point.

### Reaching `SSH_PORT` itself (for bootstrapping, or if you'd rather not use `/remote-control`)

- **On your own LAN**: nothing further to do — `ssh -p <SSH_PORT> claude@<host-lan-ip>` works exactly like the `localhost` example above.
- **Away from the LAN (recommended: a mesh VPN, not a router port-forward)**: install [Tailscale](https://tailscale.com) (or WireGuard directly — this repo's own `pihole-wireguard` environment already bundles `wg-easy` if you'd rather self-host that) on the host machine, then SSH to its Tailscale/VPN address instead of a public one. This keeps `SSH_PORT` off the open internet entirely — see "Security Notes" below for why that matters, since this container's sshd is a real, if key-only, network-facing service.
- **If you do forward the port directly instead**: that's a real choice you can make, just go in aware of the tradeoff in "Security Notes" — key-only auth makes brute-forcing impractical, but it's still a public-facing sshd.
- **From a phone/tablet, without `/remote-control`**: any SSH client app (Termius, Blink Shell, JuiceSSH, etc.) pointed at that address with your private key imported — same tmux session, same live conversation, picked up mid-thought from wherever you are.

---

## 🔀 Pointing Claude CLI at a Gateway (LiteLLM/Portkey)

Two menu actions — **"Point Claude CLI at a Gateway (LiteLLM/Portkey)"**
and **"Revert Claude CLI to Anthropic (undo Gateway)"** — redirect this
container's `claude` at a self-hosted gateway (this repo's own
`llm-gateways` environment, or any other Anthropic-Messages-API-compatible
endpoint) instead of `api.anthropic.com`, and back again. Both are also
plain scripts if you'd rather run them directly:
`./scripts/point-to-gateway.sh [litellm|portkey]` and
`./scripts/revert-to-claude.sh`.

**How it works:** Claude Code reads two env vars at startup —
`ANTHROPIC_BASE_URL` (where to send requests) and `ANTHROPIC_AUTH_TOKEN`
(the bearer credential for that endpoint). `point-to-gateway.sh` reads
both from `.env.gateway.litellm` or `.env.gateway.portkey` (two small,
separate parameter files in this directory — never this environment's own
`.env`, so switching gateways or reverting never loses track of the other
one's settings), writes them into this environment's own `.env`, and
restarts the container (`docker compose up -d` — the same command
`deploy.sh`'s `FAST` policy already runs) so `entrypoint.sh` re-exports
them into `/etc/environment` for every future login shell, the same
mechanism `GH_TOKEN` already uses. `revert-to-claude.sh` just removes
both lines from `.env` and restarts the same way — `claude` then falls
back to the OAuth session already stored under `~/.claude` (the
persistent `claude_cli_home` volume) from your original `/login`; the
env-var override and that OAuth session are separate auth paths, so
clearing one doesn't sign you out of the other.

**Before using this, fill in the gateway file first**: open
`.env.gateway.litellm` and/or `.env.gateway.portkey` and set
`ANTHROPIC_AUTH_TOKEN` (for LiteLLM: `LITELLM_MASTER_KEY` from
`environments/llm-gateways/.env`; for Portkey: whatever key it should
forward to Anthropic on your behalf — Portkey ships with no server-side
auth of its own, see `llm-gateways`' own README "Security Notes"). Both
files default `ANTHROPIC_BASE_URL` to `http://host.docker.internal:<port>`
rather than a container name or `localhost` — `claude-cli` and
`llm-gateways` are separate Compose projects with no shared Docker
network, so the only way this container reaches either gateway's
published port is through the host itself, same reasoning `llm-gateways`'
own README gives for why LiteLLM reaches Ollama that way. If you changed
`LITELLM_PORT`/`PORTKEY_PORT` from their defaults (4000/8787) in
`llm-gateways`' own `.env`, update the matching gateway file here to
match.

**Not independently verified against a live gateway from inside this
repo** — worth stating plainly rather than implying it's been tested,
consistent with how `nanoclaw-mnemon`'s own README handles claims like
this. Claude Code's `ANTHROPIC_BASE_URL` expects an endpoint that speaks
the Anthropic Messages API shape specifically — a different
request/response format than the `/v1/chat/completions` OpenAI-compatible
endpoint `llm-gateways`' own README documents calling directly. LiteLLM
and Portkey both document their own Anthropic-compatible routes, but
confirm your installed version still exposes one at the base URL each
`.env.gateway.*` file here assumes, before relying on it: run
`point-to-gateway.sh`, then send `claude` a real message inside the
session and check it actually responds rather than erroring, instead of
trusting this comment alone.

**Restarting ends any live tmux session, but doesn't lose it** — same as
any other config change here (see "How Login Works" above): SSH back in
and `--continue` resumes the same conversation, now against whichever
endpoint you just pointed it at.

**Interaction with `/remote-control`** (see "Using This as Your Remote
Runner" below): redirecting `ANTHROPIC_BASE_URL` only changes where
*model* traffic goes — `/remote-control`'s own linkage is gated on your
Pro/Max/Team/Enterprise OAuth subscription login, a separate channel from
wherever inference requests are actually routed. Whether an already-linked
`/remote-control` session tolerates a live gateway redirect without
needing to be re-linked hasn't been tested against a real deploy — treat
it as a "verify live" case rather than an assumed-safe one, same caveat
as the gateway compatibility itself above.

---

## 🐙 Connecting to a GitHub Repo

`CLAUDE_WORKSPACE_PATH` gets you one repo, already checked out on the host. Two ways to give `claude` real GitHub access beyond that — for cloning other repos, pushing, or opening PRs — lightest first:

**Option A — SSH agent forwarding (recommended: no secrets stored in the container at all)**

```bash
ssh -A -p ${SSH_PORT:-2222} claude@<host>
```

`-A` forwards your local `ssh-agent`'s already-loaded keys into the session, so `git clone git@github.com:you/repo.git`, `git push`, etc. work exactly as they would on your own machine — authenticated against whatever key your agent already holds, for exactly the duration of that one connection, nothing written to disk. (`AllowAgentForwarding` is pinned `yes` in this image's `sshd_config` — see the `Dockerfile`'s own comment.)

**This option only works while you're actually connected over SSH with `-A`.** If you're mainly reaching this container through `/remote-control` (see "Using This as Your Remote Runner" above) rather than SSH, there's no forwarded agent present — use Option B instead.

**Option B — `GH_TOKEN` (works from `/remote-control` too — for non-interactive use: `gh pr create`, `gh pr review`, or `git` over HTTPS without a live forwarded agent)**

Agent forwarding alone gets you `git` over SSH, not the GitHub *API* — if you want Claude driving `gh` itself (opening PRs, commenting, checking CI), or you're primarily using `/remote-control` rather than SSH'ing in, set `GH_TOKEN` in `.env` to a [fine-grained personal access token](https://github.com/settings/tokens?type=beta) scoped to whichever repos you want reachable, then redeploy (`FAST` is enough — no rebuild needed, this only changes the container's environment). `entrypoint.sh` writes it to `/etc/environment` (so every login shell sees it via PAM, no token file under `~/.ssh` or `~/.claude`) and runs `gh auth setup-git` once, wiring `gh`'s own credential helper into git — so plain `git push`/`git clone` over HTTPS pick up `GH_TOKEN` too, not just `gh` commands themselves. Unlike agent forwarding, this is baked into the container's environment itself, so it's there regardless of which mechanism ("Using This as Your Remote Runner" above) got you into the session.

Either option, also set `GIT_USER_NAME`/`GIT_USER_EMAIL` in `.env` — commits fail with no identity configured, and this container has none baked in.

---

## 🏠 Connecting to Home Assistant

Home Assistant has a built-in **Model Context Protocol Server** integration — enabling it turns whatever you've already exposed to Assist into an MCP server Claude can register directly as a tool source, no separate bridge, bot, or webhook relay needed.

1. In Home Assistant: **Settings → Devices & Services → Add Integration → "Model Context Protocol Server"**, and make sure the entities you want Claude to control are actually exposed to Assist (**Settings → Voice assistants → Expose**) — HA's own exposure list is the real access boundary here, not anything this container adds.
2. Create a **long-lived access token**: your Home Assistant user profile → **Security** tab → **Long-Lived Access Tokens** → Create Token.
3. From inside a session on this container (SSH in, you're already in the tmux `claude` session — this is a one-time `claude mcp` command, run it in a shell, not as a message to Claude):
   ```bash
   claude mcp add --transport sse home-assistant http://<ha-host>:8123/mcp_server/sse \
     --header "Authorization: Bearer <your-long-lived-token>"
   ```
   Run `claude mcp add --help` first to confirm the current flag names — Claude Code's own MCP CLI surface isn't something this environment scripts or pins a version of, since the registration is per-user state stored in Claude Code's own config, not something `.env`/`docker-compose.yml` should hold a token for.
4. `<ha-host>` is whatever address *this container* can actually reach Home Assistant at: the same LAN IP/hostname you'd type into a browser if Home Assistant runs on a separate device (e.g. a Pi running HAOS — the common case), or `host.docker.internal` if it happens to run as a process on this same host (see `chat-frontends`' README for the OrbStack caveat on that hostname specifically, if that's your setup and it doesn't resolve).

Once registered, Claude can see and act on exactly what you've exposed to Assist — nothing more. Revoking the long-lived token (or narrowing what's exposed to Assist) in Home Assistant itself is how you scope or pull this back later; nothing about it lives in this environment's own `.env` or volumes.

This registration lives under `~/.claude` — the `${CONTAINER_NAME:-claude-cli}_claude_home` named volume — so it's tied to the container, not to any one connection method. Register it once (over an initial SSH session), and it's available whether you come back over SSH or through `/remote-control`.

---

## 🎛️ Deployment Policies

Select a policy from `deploy.sh`'s menu — recommended, since it also handles desktop-entry refresh and `CLEAN`'s safe build-before-swap ordering. There's no `run.sh` here to set `REBUILD_POLICY` on directly (see "Deploy" above); the table below shows the equivalent raw `docker compose` command for each policy if you'd rather run it by hand from this directory:

| Policy | Action | Direct equivalent |
|--------|--------|--------------------|
| `FAST` | Start container if not running; otherwise reconcile against `docker-compose.yml` (no rebuild) so config-only edits (e.g. a new `SSH_PORT`) still take effect | `docker compose up -d` |
| `STOP` | Pause the container (resumable with `FAST`) | `docker compose stop` |
| `TEARDOWN` | Stop + remove the container; named volumes and `CLAUDE_WORKSPACE_PATH` untouched | `docker compose down` |
| `CLEAN` | Rebuild the image fresh, then stop + remove + redeploy | `docker compose build --no-cache && docker compose down && docker compose up -d` |
| `INFO` | List data directories with sizes and useful commands | `deploy.sh` menu only |
| `WIPE` | Delete the `${CONTAINER_NAME:-claude-cli}_claude_home` and `${CONTAINER_NAME:-claude-cli}_ssh_host_keys` named volumes (irreversible — signs you out and changes the SSH fingerprint; your workspace repo is untouched, see `info.yaml`'s own confirm message) | `deploy.sh` menu only |

---

## 💾 Data Directories

### Named Docker Volumes

| Volume | Contents |
|--------|---------|
| `${CONTAINER_NAME:-claude-cli}_claude_home` | Claude CLI's own OAuth/session state (`~/.claude`) — deleting this signs you out |
| `${CONTAINER_NAME:-claude-cli}_ssh_host_keys` | This container's own SSH host keys — deleting this changes its SSH fingerprint |

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
docker exec -it ${CONTAINER_NAME:-claude-cli} tmux attach -t claude

# sshd logs
docker logs -f ${CONTAINER_NAME:-claude-cli}

# Pause / resume without losing data
docker compose stop
docker compose up -d

# Redirect Claude CLI at a self-hosted gateway, and back again
# (see "Pointing Claude CLI at a Gateway" above — fill in the matching
# .env.gateway.* file first)
./scripts/point-to-gateway.sh [litellm|portkey]
./scripts/revert-to-claude.sh
```

---

## 🩺 Troubleshooting

### `Permission denied (publickey)` on first SSH

The most common cause: `SSH_AUTHORIZED_KEYS_PATH` (default `~/.ssh/authorized_keys` on the host) didn't exist yet the first time you deployed. Docker Compose's bind mount auto-creates a missing source path as an **empty directory**, not a file — so instead of your keys, the container got nothing to match against, and every key is rejected. Check for this first:

```bash
ls -la ~/.ssh/authorized_keys
# a directory (not "-rw-------") confirms this is what happened
```

Fix it in three steps:

1. **Remove the directory Docker created** (safe if empty — nothing you put there yourself):
   ```bash
   rmdir ~/.ssh/authorized_keys
   ```
2. **Create a real file containing your public key.** If you don't already have a keypair on disk (`ls ~/.ssh/*.pub` comes back empty — common if you use an SSH agent like 1Password's or a hardware key that never wrote a `.pub` file locally), check what your agent is offering first:
   ```bash
   ssh-add -L                      # lists keys held by your agent, if any
   # found one? use it directly:
   ssh-add -L >> ~/.ssh/authorized_keys
   # nothing listed? generate a new keypair:
   ssh-keygen -t ed25519
   cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
   ```
   ```bash
   chmod 600 ~/.ssh/authorized_keys
   ```
3. **Recreate the container — a plain restart isn't enough.** The running container's mount was set up back when the host path was still a directory; `docker compose stop && docker compose up -d` reuses that same container and its stale mount config, and fails outright with a `not a directory: Are you trying to mount a directory onto a file` error. Force recreation instead (`deploy.sh`'s `TEARDOWN` + `FAST`, or by hand):
   ```bash
   docker compose down   # named volumes (claude_home, ssh_host_keys) are untouched
   docker compose up -d
   ```

Then retry `ssh -p ${SSH_PORT:-2222} claude@localhost`.

---

## 🔒 Security Notes

- **Key-based auth only.** `sshd_config` is patched at build time (`PasswordAuthentication no`, `PermitRootLogin no`) — there's no password to guess, only whoever's public key is in `SSH_AUTHORIZED_KEYS_PATH`.
- **`SSH_PORT` is a real network-facing port.** If this host is reachable from outside your LAN, treat `SSH_PORT` with the same care you'd give the host's own SSH port — don't forward it through your router unless you specifically mean to expose it, and keep `SSH_AUTHORIZED_KEYS_PATH` scoped to keys you actually trust with this access. If you've bootstrapped `/remote-control` (see "Using This as Your Remote Runner") and don't need direct SSH day-to-day, you can drop the `ports:` mapping in `docker-compose.yml` (or just firewall it off) and rely on `/remote-control` alone — `/remote-control` makes only outbound connections, so closing `SSH_PORT` doesn't affect it, and removes the sshd's inbound surface entirely. You'll need the port back temporarily for any future SSH-only step (rotating `GH_TOKEN` by hand, re-running `claude mcp add`, etc.) unless you do those through the `/remote-control` session itself.
- **`PUID`/`PGID` control real host-filesystem ownership.** Files `claude` creates inside `CLAUDE_WORKSPACE_PATH` are written with these UID/GID on the host side, since it's a bind mount — set them to your own `id -u`/`id -g` (not left at the container-only default) if you want files to come out owned by you rather than an arbitrary UID 1000.
- **`claude` inside this container can read/write anything under `CLAUDE_WORKSPACE_PATH`** and run arbitrary commands as the `claude` user — same trust model as running `claude` directly on your own machine in that directory, just remote. It cannot reach anything else on the host filesystem or the Docker socket (unlike NanoClaw's agent containers, this one has no `docker.sock` mount at all).
