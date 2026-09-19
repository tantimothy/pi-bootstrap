# herdr-client

[Herdr](https://herdr.dev) is a terminal multiplexer that knows what an AI
coding agent is. Same pane/tab/session model as tmux, plus a sidebar
showing each pane's real state — **blocked / working / done / idle** — and
a socket API agents can call.

This environment installs it on **this machine**, deploys a repo-managed
config, and can generate a session pointing at whatever agent environments
you have deployed.

> **Client-side.** No container runs. Nothing is deployed to a remote host.
> This is the same shape as `mac-terminal-setup`: it installs into your home
> directory and backs up anything it overwrites into
> `~/.pi-bootstrap-backups/herdr-client-<timestamp>/`.

---

## 🤝 Firstmate is not required

Firstmate is a separate thing, it is **not** installed here, and nothing on
this page depends on it.

Standalone Herdr is already a complete setup: one window over every agent
environment, the state sidebar, session persistence across detach, and —
optionally — Herdr's own bundled `skills/herdr`, which lets an agent
*already running inside a pane* create layout, start other agents and read
their output. That skill is deliberately conservative: it requires
`HERDR_ENV=1` and refuses to act if the agent is not inside a Herdr-managed
pane, so it will not quietly take over.

`collie-client` also depends only on Herdr, so **herdr + collie + the
generated session is a working phone-controlled fleet with no firstmate
anywhere**.

If you do adopt firstmate later: it controls, Herdr is the substrate. You
configure Herdr as firstmate's backend, not the reverse — and tmux is
firstmate's own hard default, which is what this repo recommends. See
`docs/future-enhancements/agent-control-environments.md`.

---

## 🔍 How it finds your agents: it doesn't, and that's fine

Worth stating plainly, because the obvious assumption is wrong in both
directions.

**There is no discovery.** Herdr knows nothing about Docker. A pane is just
a PTY running whatever command you give it. The chain is:

```
Herdr pane ──ssh -p 2222──▶ container sshd ──login shell──▶ container tmux ──▶ claude
```

What this repo contributes is the middle step: `scripts/generate-session.sh`
reads every deployed environment's own `.env` for its `SSH_PORT` and emits
the pane commands. Herdr supplies the window; this repo supplies the
knowledge of which ports exist.

**Your sessions already persist** — inside each container's own tmux, not in
Herdr. Closing a Herdr pane detaches a client; it does not stop the agent.

### The state sidebar does work through all of that

This surprised me, so it is worth recording why. Herdr's agent detection is
**screen-content matching**, not process inspection — `detect_agent(agent,
screen_content: &str)`, driven by per-agent regex manifests in
`src/detect/manifests/*.toml`. It matches the agent's rendered TUI: spinner
glyphs, `esc to interrupt`, prompt shapes.

Rendered bytes cross SSH and nested tmux unchanged. So the sidebar lights up
for a containerized agent the same as a local one. Manifests ship for
**claude, codex, pi, opencode and hermes** — every agent in this repo.

| Signal | Crosses SSH + container tmux? |
|:---|:---|
| Screen-content rules (the large majority) | ✅ Yes |
| OSC title / progress rules | ⚠️ Only with `set-titles` forwarding — see below |
| `herdr integration install` hooks | ❌ No — see below |

### Two things that genuinely don't cross

**OSC title rules, unless tmux forwards them.** tmux owns the outer terminal
title and by default reports itself, so title-region rules silently never
fire. **This repo now sets `set-titles on` plus `set-titles-string
"#{pane_title}"` in every agent environment's `.tmux.conf`**, forwarding the
inner application's title outward.

How much that matters is very uneven, and it is worth knowing which of your
environments actually depends on it:

| Environment | Without title forwarding |
|:---|:---|
| **`codex-cli`** | **Breaks.** `osc_title_idle` is its **only** idle rule, so codex could never report idle. Its `working` signal also drops from the title rule (priority 1050) to a rule literally named `screen_working_fallback` (priority 500) |
| **`claude-cli`** | Degrades, gracefully. Loses its fastest `working` path (priority 1100) and two low-priority idle fallbacks, but screen rules cover working, blocked **and** idle — `live_prompt_box` (950) outranks the OSC idle rules (250) anyway |
| `pi` | No effect — zero OSC rules of its 2 |
| `opencode` | No effect — zero OSC rules of its 3 |
| `aider` | **No effect ever — herdr ships no `aider` manifest.** Aider is not in herdr's supported-agent list, so it gets no state detection at all and shows as a plain pane. The `set-titles` line is in its `.tmux.conf` for consistency and a nicer terminal title, nothing more |

So: **`codex-cli` is the one that was actually broken**, `claude-cli` is the
one that gets meaningfully better, and the rest are unaffected.

**The hook integrations.** `herdr integration install claude` writes a hook
into the agent's own config that calls `herdr pane report-agent` back over
`HERDR_SOCKET_PATH`, using the `HERDR_PANE_ID` Herdr injects into the pane
process (`src/pane.rs:168`). Across a container boundary all three legs
break: the env var is set on the *ssh client* on this machine and our images
set no `AcceptEnv`; there is no `herdr` binary in the images; and the socket
is a Unix socket on this host.

That costs the *enhanced* signal — session IDs and faster, more reliable
state — not the basic one. See
`docs/future-enhancements/herdr-agent-state.md` for what closing that gap
would take and why it is not obviously worth it.

---

## 📋 Requirements

| Platform | Supported | Notes |
|:---|:---|:---|
| macOS (Apple Silicon or Intel) | ✅ | Installed via the official installer |
| Linux **aarch64/arm64** | ✅ | Including a 64-bit Raspberry Pi OS |
| Linux armv7l (32-bit Pi OS) | ❌ | Herdr publishes no armv7 build — `run.sh` fails with a clear message rather than letting the installer fail obscurely |
| Windows | ❌ | Out of scope for this repo |

---

## 🚀 What a deploy does

1. Detects platform and architecture, refusing anything Herdr has no build
   for.
2. Installs Herdr with the **official installer**, which resolves the
   platform from `uname -m` and then looks up both the download URL **and
   its SHA-256** in a release manifest, failing loudly if the manifest has
   no matching entry. Checksum verification is therefore already handled
   upstream.
3. Deploys `config.toml` to `~/.config/herdr/`, backing up any existing one.

It does **not** start the server. Herdr's server starts when you run
`herdr`, and restores the saved session shape on that first run.

---

## ⌨️ Nested tmux — why the prefix is `ctrl+a`

The single most important line in `config.toml`.

**Every agent environment in this repo auto-attaches you to a tmux session
inside its container.** So any Herdr pane into one of them is:

```
Herdr  →  ssh / docker exec  →  container tmux
```

Two multiplexers, stacked. Herdr's default prefix is `ctrl+b` — and so is
tmux's, which none of this repo's `.tmux.conf` files override. Herdr is
designed to be polite about this (its docs note the keymap is "prefix-first
so Herdr does not steal input from shells, editors, tmux, or terminal
apps"), but a **shared** prefix still means the outer multiplexer eats the
keystroke the inner one was waiting for.

So this repo sets Herdr's prefix to `ctrl+a` — **one file in one
environment**, rather than changing six existing environments' tmux
configs. If `ctrl+a` clashes with something you use, change it in
`config.toml` here, not in the containers.

Herdr also documents a "vetted prefix-free setup" worth evaluating if you
dislike prefixes generally.

---

## 🖥️ Multi-machine: it is not Mac *or* Pi, it is both

Herdr has a first-class Machines mode: "manage Local and saved SSH machines
from one Herdr window, with a combined agent list, machine-scoped
navigation, notifications, and automatic reconnects… a disconnected machine
does not interrupt the others."

```bash
herdr machine add pi --label "Raspberry Pi"
herdr machine list
herdr machine disable <profile-id>     # temporarily
herdr machine remove <profile-id>
```

Deploy `herdr-client` on **each** machine, then add the others from
whichever one you sit at. That divides the work cleanly:

- **Machines** — host to host. Herdr's own feature, one command.
- **The session generator** — host to containers. This repo's job, since
  only it knows the SSH ports.

### Two things to know before you run `machine add`

**Pin the same `HERDR_VERSION` everywhere.** Client and server versions need
not match, but an *incompatible* pair triggers an approval-based setup that
"asks before stopping it and its pane processes, then starts the compatible
server". The default answer is No, but the prompt exists — and a Mac-side
`machine add` can therefore offer to take down your Pi's panes.

**`machine add` is the other route to a stopped remote server.** Same cost
as the `STOP` policy below, arriving from a different direction.

---

## 🔌 The session generator

```bash
bash scripts/generate-session.sh --dry-run   # see what it would emit
bash scripts/generate-session.sh             # write it
```

Anyone can `brew install herdr`. What this repo uniquely knows is **which
agent environments are deployed and what port each listens on**. The
generator reads each deployed environment's own `.env` and emits one pane
per agent.

**Panes are labelled with the repo the workspace points at, not just the
agent name.** Six panes reading "claude", "codex", "aider" tell you nothing
about which project each is in — which is the only thing you need to know
when the sidebar says one of them is blocked.

### Why SSH panes rather than `docker exec`

The generator emits `ssh -p <port> user@host` panes **even for containers on
this same machine**, falling back to `docker exec` only where an
environment publishes no SSH port (`openclaw`, and `nanoclaw-mnemon`'s admin
session).

That costs a local SSH hop and buys two things. One pane shape covers both
local and remote, so nothing changes when you view the same fleet from the
other Mac. And **Collie inherits whatever the Herdr account can do** — so
keeping the phone-reachable path pointed at an unprivileged container
account, rather than at the container runtime, is worth the hop.

---

## 🎛️ Deployment Policies

Unlike most host-only environments, this one genuinely branches on policy —
Herdr runs a background server, so `STOP` means something.

| Policy | What it does |
|:---|:---|
| **FAST** | Install if missing or not at the pinned version; deploy `config.toml`; otherwise leave the install alone. Does not start the server. |
| **CLEAN** | Force reinstall/upgrade to the pinned version, **then stop the server**. |
| **STOP** | `herdr server stop`. |
| **TEARDOWN** | Stop the server, remove the binary and `~/.config/herdr` (config backed up first). |

### Why CLEAN also stops the server

Herdr's install docs note that package-manager updates do not get live
handoff and "the compatible old server keeps running" — you restart it with
`herdr server stop` when you want server-side changes from a new release.

A CLEAN that upgraded the binary and left the old server running would be
precisely the **silently-stale-copy** failure this repo has been bitten by
before (see `docs/lessons-learned/nanoclaw-mnemon.md`). So CLEAN does both.

### What STOP actually costs

Herdr's docs are explicit: *"if the Herdr server stops and starts again, the
original pane processes are gone. Herdr restores the saved session shape:
workspaces, tabs, panes, cwd, layout, and focus."*

**Shape survives; processes do not.** In this repo's topology that is cheap
on purpose — panes are SSH or `docker exec` clients into agent containers,
so stopping the server kills the **client connections**, not the agents,
which keep running in each container's own tmux. Relaunch and you are back.

> **Detach is not STOP.** `ctrl+a q` detaches the client while panes and
> agents keep running. That is what you want most of the time; STOP is the
> deliberate heavier action.

> **Known wording bug:** `deploy.sh`'s STOP confirmation is hardcoded
> per-policy and reads *"Pause \[env]'s running container(s)?"*. There are no
> containers here. The prompt is wrong; the behaviour above is right.

---

## 🔒 Security notes

Nothing here listens on a port and nothing is exposed. The considerations
are about what a Herdr pane can *reach*:

- **Panes inherit your shell.** A pane is a real PTY running as you.
- **Prefer SSH panes over `docker exec`** (the generator does this by
  default). On Linux, `docker exec` needs the invoking user in the `docker`
  group, which is effectively root on that host — and if you later run
  `collie-client`, that account is what your phone reaches.
- **Herdr's socket API can spawn panes and prompt agents.** Do not bind-mount
  the host's Herdr socket into a container: that hands the container control
  of your terminal multiplexer.

---

## 📚 See also

- `docs/future-enhancements/agent-control-environments.md` — the full design
  reasoning, including why firstmate uses tmux rather than Herdr as its
  backend in this repo, and the settled decisions behind these choices.
- `environments/collie-client/` — phone access to this fleet over Tailscale.
