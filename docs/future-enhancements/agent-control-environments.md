# Agent Control Environments — Herdr, Collie, Coding CLIs, Hermes, Executor

**Status:** partly built. This started as a design proposal for seven
candidate environments plus a menu regrouping, worked out against each
upstream project's own repository rather than secondary write-ups. Every
factual claim below was checked against a primary source except where
explicitly marked inferred.

Built so far: the menu regrouping, `herdr-client` (with its session
generator), `collie-client`, `pi` and `opencode`. Still proposals:
`hermes`, `executor`, the skills experiment, and `omp`.

**Nothing built has been run against real Docker, a real Herdr or a real
Tailscale.** Each was verified by `bash -n`, YAML parsing, offline
exercise of the generator and config emitters, and reading upstream
source — not by a deploy. See "Build pass — 2026-09-11" for what reading
that source changed, including two corrections to this document.

**Posture:** this is a *research* exercise first. The goal is to find out
which of these tools earn a place; several will not. It becomes tooling
only if it proves practical in use.

---

## Scope

Most environments run on **one Mac** (Apple Silicon, OrbStack), with a
few instantiated on a **second Mac** specifically to exercise
multi-machine working. The **Raspberry Pi** continues to host some
containers, with the explicit option to shut it down if it proves too
much.

Three consequences that shape everything below:

- **The container host is a Mac, not the Pi.** Aggregate resource
  pressure is therefore not the binding constraint; port allocation is.
- **arm64 is uniform** — Apple Silicon throughout, plus a 64-bit Pi where
  it participates. The `armv7l` caveat only applies if the Pi hosts
  something itself.
- **bash 3.2 is now the primary path**, not a portability nicety, since
  it is macOS's shipped default. The repo's existing no-`mapfile`,
  no-associative-arrays rule was written for exactly this.

### The Pi must remain removable

Because shutting the Pi down is explicitly on the table, **nothing on a
Mac may depend on something running on the Pi.** Do not put Executor, or
any shared credential or gateway service, on the Pi while Mac-hosted
agents would call it. Keep the Pi leaf-shaped — environments that are
self-contained, or used only by other Pi-hosted things — so that
switching it off stays a one-line decision rather than an untangling
exercise.

The Pi does earn its keep as a third participant in the multi-machine
test: Mac one, Mac two and the Pi exercise `herdr machine add` more
honestly than two machines would.

### OrbStack is the runtime, and this repo has been bitten by it

`docs/lessons-learned/nanoclaw-mnemon.md` records that a named-volume
version of a single-file mount **broke deploys outright on OrbStack**.
The fix was a real bind mount onto a pre-existing file, which is also
why `claude-cli` ships a `pre-deploy.sh` creating a valid-JSON
placeholder before the mount attaches — Docker's own "create if missing"
behaviour for a bind-mount source always makes a *directory*, never a
file.

**Rule for every new environment: any single-file mount needs a real
bind mount plus a `pre-deploy.sh` that creates the file first.** Named
volumes remain fine for directories (Executor's `/data`, Hermes's
`~/.hermes`, the SSH host-key volumes are all unaffected). It is
specifically config-file-shaped mounts to check, at build time rather
than after a deploy fails on one machine and not another.

---

## Settled decisions

Recorded here so they are not re-litigated:

1. **No shared GitHub tokens.** Each agent environment gets its own
   fine-grained PAT scoped to only the repos that environment works on.
   The reasoning is not primarily blast radius — these environments work
   on *different repos*, so a shared token would grant every agent access
   to every other agent's work for no reason. Yields a clean invariant:
   **an environment's token reaches exactly the repos its workspace
   contains.** See "Secrets" below for the one deliberate exception.
2. **`STOP` kills the Herdr server** (`herdr server stop`), so
   `herdr-client/run.sh` must reference `$REBUILD_POLICY`.
3. **Collie is in scope**, with its security posture designed in rather
   than deferred.
4. **Firstmate uses the tmux backend** — its own hard default and
   verified reference backend.
5. **The menu regrouping is approved** (see "Presentation").
6. **`nanoclaw-mnemon` stays.** Hermes is evaluated alongside Pi and
   OpenCode as a possible daily driver, not as a replacement for it.
7. **`aider` gets no MCP, and that is deliberate.** See below.

### Decision 7 in full: aider stays without MCP

Recorded at length because the gap will look like an oversight to anyone
who notices it later, and because the reasoning is the interesting part.

**The mechanics.** Executor exposes every integration as MCP tools behind
one endpoint. Agents that speak MCP point at it directly; `pi` and `omp`
reach it through `mcporter`, which turns an MCP tool into a shell
command. That is free for them because both are npm-distributed and want
a Node base anyway. **`aider` is `python:3.12-slim`** — no Node at all —
so the same one-line addition means putting a second language runtime
into a Python image: larger image, two ecosystems to keep current, one
more update surface, for a single tool.

**The sidecar does not help, but not for the reason first given.** An
earlier draft of this decision claimed no HTTP bridge existed. That was
wrong, and the correction matters. `mcporter serve --http <port>` does
exist: it "exposes daemon-managed keep-alive servers as one MCP server
for clients that consume MCP over stdio or Streamable HTTP", with `/mcp`
as an aggregate namespacing tools `server__tool` and `/mcp/<server>`
preserving original names.

The reason it does not help is subtler. **`serve` exposes MCP *to MCP
clients* — and aider is not one.** A sidecar running it would hand aider
an endpoint it cannot consume. mcporter has two halves, and the sidecar
offers the wrong one: `serve` is the server side, while `call`/`list` —
the half that turns an MCP tool into a shell command a non-MCP agent can
run — has to execute *inside* the agent's own container.

**The route that should work is `generate-cli --compile`.** mcporter can
"produce a standalone CLI for a single MCP server", and `--compile`
"invokes `bun build --compile` to create the native executable". So a
multi-stage Docker build could generate and compile the CLI in a
Bun-equipped builder stage and `COPY` a **static binary** into aider's
final image — no Node runtime in the Python image at all, exactly the way
`gh` is just a binary.

**Designed, not demonstrated.** That paragraph is read from mcporter's
documentation, not from a working build. Nobody has compiled this binary,
pointed it at anything, or run it inside a Python image. It cannot be
demonstrated yet either, since Executor is phase 8 and does not exist to
point it at. Treat it as a plausible implementation sketch rather than a
proven escape hatch — the difference matters, because the whole argument
for reopening this decision rests on the cost being near zero, and an
untested route could yet prove otherwise.

**So the cost objection largely collapses, and this decision now rests on
one argument rather than two.** Three caveats remain, the last of which
could reverse that:

- The generated CLI "embeds the resolved server definition and always
  targets that snapshot (no external `--config` or `--server` overrides
  at runtime)", so the binary is pinned at build time and must be
  regenerated when the catalogue changes.
- It is one CLI *per MCP server*. Since Executor is a single endpoint
  fronting everything, that should mean one binary — worth confirming
  rather than assuming.
- The docs note generated CLIs register views with the single-user
  daemon for embedded stdio servers. **Whether an HTTP-backed target like
  Executor needs that daemon at runtime is unverified.** If it does, the
  static binary quietly reacquires a dependency, "no Node in the final
  image" stops being true, and the cost objection this decision just
  discarded comes back. This is the one caveat that is not merely
  bookkeeping.

**The question underneath is not "can we" but "would it use it".** Aider
is a git-native pair programmer — architect/editor modes, auto-commits,
working the repo in front of it. Its loop is read files, propose edit,
commit. Executor's catalogue is issue trackers, APIs, browser
automation: value for agents doing tasks *around* code, not agents making
edits *to* it. Aider is the most specialised of the six, and that
specialisation is the reason to keep it rather than a deficiency to
correct.

**The asymmetry that settles it.** `aider` already exists and works. This
plan adds six new environments; `aider` is not one of them. Doing nothing
costs zero, while adding Node modifies a working environment in service
of a capability its paradigm may not want.

**Still declined, but on narrower grounds.** With the cost reduced to a
builder stage and a `COPY`, this is no longer "too expensive" — it is
"probably unwanted". That is a weaker position and the doc should say so
rather than lean on an objection that no longer holds.

**Revisit on a concrete trigger** — wanting aider to file an issue or
check CI and being annoyed it cannot — not on noticing the gap. The
implementation is now known, so revisiting is cheap: a Bun builder stage,
`generate-cli --compile` against Executor, `COPY` the binary. Note also
that Executor is phase 8, so there is nothing to point it at yet; this
cannot be settled empirically until then. And this is an evaluation — if
`aider` does not survive as a daily driver the work was never worth
doing, and if it does, there will be a real use case by then instead of a
hypothetical one.

---

## The catalogue

| Tool | What it is | Licence | Delivery | Verdict |
|:---|:---|:---|:---|:---|
| **executor** | MCP proxy — one endpoint fronting all integrations, credentials held server-side, per-tool allow / require-approval / block | MIT | Official image `ghcr.io/rhyssullivan/executor-selfhost` | Host service |
| **opencode** | Terminal coding agent, native MCP | open source | Official installer, detects amd64/arm64 | Coding CLI environment |
| **omp** | Coding agent with the IDE wired in — LSP on every file write, DAP debugger ops, 31 tools, 60+ providers. Substantially **Rust** — 462 `.rs` files, ~258k lines | MIT | `omp.sh` installer, brew tap, bun, nix | Coding CLI environment |
| **pi** | Agent harness/SDK in TypeScript (`pi-agent-core`, `pi-ai`, `pi-tui`) plus the coding-agent CLI this environment deploys | MIT | npm or standalone binaries | Coding CLI environment |
| **hermes** | Personal agent with a learning loop — writes its own skills from successful runs, persistent memory, ~20 channels, cron, subagents. One core across CLI, TUI, gateway and desktop app | MIT | Official image `nousresearch/hermes-agent`, multi-arch | Agent platform |
| **herdr** | Rust terminal multiplexer aware of agent state — a PTY pane per agent, sidebar showing blocked / working / done / idle | Apache 2.0 | Official installer publishes `herdr-linux-aarch64` (musl, static); also brew, mise, cargo. No official image | Client environment |
| **collie** | Mobile PWA control surface — bridges Herdr's Unix socket, served over Tailscale, push when an agent blocks | MIT | Release tarball + sha256, or Bun source build | Client environment |
| **mcporter** | MCP *client* runtime and CLI — `list`, `call`, `resource`, plus `generate-cli` | MIT | `npm install -g mcporter` (Node 24+) | Installed into agent images |

### Two pairs that get conflated

**Pi and omp are different products.** omp began as a fork of Pi but has
diverged at the language level — Pi is TypeScript and designed to be
embedded; omp is a standalone coding agent whose core is Rust (462
`.rs` files, ~258k lines measured on a fresh clone) alongside a large
TypeScript surface.
Installing one does not give you the other.

> **Footgun, and worse than it first looks.** Four scopes are live on npm
> simultaneously, all installing without error:
>
> | Package | Version | What it is |
> |:---|:---|:---|
> | `@earendil-works/pi-coding-agent` | 0.85.1 | **current canonical Pi** |
> | `@mariozechner/pi-coding-agent` | 0.73.1 | pre-acquisition Pi, still published, twelve minors behind |
> | `@oh-my-pi/pi-coding-agent` | 18.1.16 | omp — a different product |
> | `@badlogic/pi` | 0.1.1 | — |
>
> The dangerous one is not omp — its version scheme is so different that a
> pinned version is unambiguous. It is **`@mariozechner/…`**, which older
> guides still name: it installs cleanly and silently gives you a Pi
> twelve minor versions stale, with nothing to catch it. Pin the scope
> *and* the version explicitly in each Dockerfile.

**Hermes has a CLI but is not a coding CLI.** It runs the same agent core
across a terminal CLI, a TUI, a messaging gateway spanning roughly twenty
platforms, and an Electron app. Its distinguishing feature is a learning
loop. It belongs under "personal agent platforms" because that is how you
deploy and live with it, but its `info.yaml` notes should say plainly
that it also works as a terminal agent — the categorisation is a menu
convenience, not a claim about the software.

### Pi's environment and OpenClaw's harness are separate concerns

`environments/pi/` deploys the standalone Pi coding-agent CLI. Separately,
`environments/openclaw/Dockerfile` builds `FROM
ghcr.io/openclaw/openclaw:latest`, and OpenClaw embeds Pi's SDK
internally as its agent harness — its gateway calls `createAgentSession()`
from `pi-agent-core`. **That is OpenClaw's own business and stays
untouched.**

The practical consequence, worth stating once in both READMEs: **the two
can run different Pi versions and that is expected, not a bug.** They are
independent installs that happen to share an upstream project; neither
should ever be "aligned" to the other.

Worth recording in `docs/lessons-learned/general.md`: **`nanoclaw-mnemon`
does not use Pi** — NanoClaw runs on Anthropic's Claude Agent SDK. The
repo's two "claw" environments sit on different harnesses and nothing
currently documents that.

---

## Mechanisms already in place

Four findings from reading the dispatcher layer. Together they mean these
environments need **no changes to `lib/`** — the main risk in adding a new
*kind* of environment.

- **Policy menu.** `deploy.sh` decides whether to offer
  `STOP`/`TEARDOWN`/`CLEAN` by *grepping `run.sh` for any `POLICY`
  reference* — deliberately name-agnostic, with a comment saying it stays
  correct "if another host-only environment is added later".
- **Deployed check.** `desktop-entries.yaml` supports
  `deployed_check.kind` of `container | marker | systemd`. A **marker**
  check — a path that exists once installed — covers a native binary
  install exactly.
- **OS branching.** An `info.sh` override is the documented escape hatch
  for OS-dependent values. Template: `environments/internet-pi/info.sh`.
- **Backup manifest.** `maintenance.yaml` is optional and
  containerised-only — the two existing host-only environments
  (`mac-terminal-setup`, `pi-barebones`) are exactly the ones without it.
  `lib/maintenance-lib.sh` also honours an executable
  `scripts/is-deployed.sh` as a first-choice override.

---

## Environment specs

### `environments/executor/` — host-side MCP gateway

Official image, no build, no host access, no security caveat.

| Field | Value |
|:---|:---|
| Archetype | `docker-compose.yml`, generic path via `deploy_environment()` |
| Container | `container_name: ${CONTAINER_NAME:-executor}` |
| Port | `${EXECUTOR_PORT:-4788}:4788` |
| Volume | `${CONTAINER_NAME:-executor}_data:/data` — SQLite plus generated encryption keys; losing it loses every stored credential |
| Env | `EXECUTOR_DATA_DIR`, `EXECUTOR_DB_PATH` — both default sanely |

**First-run behaviour to document:** the first account created becomes
owner and open signup then closes; further users join by single-use
invite from the Admin page. A one-shot decision on first deploy, so it
belongs in the README and the `info.yaml` notes.

**Host it on the Mac, not the Pi** — the moment Mac-hosted agents depend
on it, the Pi stops being something you can switch off.

### `environments/opencode/` · `environments/omp/` · `environments/pi/`

All three follow `aider` and `codex-cli` exactly: Dockerfile installs the
agent, SSH server, entrypoint drops you into a persistent tmux session
against a bind-mounted repo. The infrastructure (`entrypoint.sh`,
`bashrc-tmux-attach.sh`, `.tmux.conf`, SSH host-key volume keyed on
`CONTAINER_NAME`) is identical regardless of which agent binary runs
inside. Three separate folders, three menu entries.

| Field | Value |
|:---|:---|
| Packages | `pi` installs **`@earendil-works/pi-coding-agent`**; `omp` installs **`@oh-my-pi/pi-coding-agent`**. Those two are the correct scopes. Pin scope *and* version in each Dockerfile — see the footgun table above for why the scope alone is not enough. `opencode` uses its official installer, not npm |
| Base image | **Node 24 for `pi` and `omp`**, which lack native MCP and therefore want `mcporter`. `opencode` has native MCP and needs neither — choose its base on its own merits |
| SSH ports | Next free after 2224 — 2225, 2226, 2227 |
| Install | Official installers inside the image; `openclaw/Dockerfile` already sets this precedent |
| Avoid | The `anomalyco/opencode` Docker Hub image is **third-party** — build from the official installer |
| Providers | All three take an `OPENAI_API_BASE`-style override, so each should document routing through this repo's `llm-gateways`, as `aider`'s README already does |

**Pi specifics.** Two confirmed behaviours worth building to. **Pi does
not auto-load `.env`** — keys must already be in the shell environment
when it launches, which the existing `/etc/environment` + PAM mechanism
delivers exactly, so no new plumbing is needed. And **Pi is "YOLO by
default — no permissions, no sandbox"**, its author arguing that
"security in coding agents is mostly theater; if it can write and run
code, it's game over". That is firstmate's `--yolo` posture as a
*default* rather than an opt-in, so for `pi` the container boundary and
the per-environment scoped token are load-bearing from day one, with or
without firstmate.

**Disambiguate.** Six coding CLIs in one submenu is the real cost here.
Each `info.yaml` needs a one-line "pick this when…" — omp for IDE-grade
tooling (LSP, debugger), Pi for a minimal harness, OpenCode for a
batteries-included terminal agent.

### `mcporter` — per-image dependency, not an environment

mcporter is a system dependency, so it belongs in each agent image's
**Dockerfile** — the same treatment `gh` already gets. It gets no
`environments/` folder and no menu entry. It is only worth installing
where the agent has no MCP of its own:

| Agent | Native MCP | Needs mcporter | Cost |
|:---|:---|:---|:---|
| `pi` | No — by design, *available via extension* | **Yes, and preferably** | Free on a Node 24 base |
| `omp` | Not evidenced (inferred) | **Likely** | Free on a Node 24 base |
| `aider` | No | Declined | Would need Node in `python:3.12-slim` — see decision 7 |
| `opencode` | Yes | No | — |
| `claude-cli` | Yes | No | — |
| `codex-cli` | Yes | No | — (base is already `node:24`) |

**Pi can have MCP via an extension — and that is the argument for
mcporter, not against it.** Pi's own stated reason for omitting MCP is
context cost (a community comparison puts it at 7–14k tokens), which is
why a ~200-token-prompt agent refuses to ship it. An MCP extension puts
that overhead straight back. **mcporter costs nothing until invoked** —
it is a command, not an always-loaded tool schema.

The OpenCode row is self-confirming: mcporter's own config autodiscovery
reads MCP server definitions from OpenCode, alongside Claude Code, Cursor
and Codex — a tool only imports config from something that has config to
import.

**`aider` deliberately gets no MCP — see settled decision 7 below.** It
lacks MCP and mcporter would supply it, but `aider` is a Python image and
that means adding a whole Node runtime for one tool. The decision is to
leave it alone.

### `environments/hermes/` — personal agent platform

A sibling to `openclaw` and `nanoclaw-mnemon` — and **easier than
`nanoclaw-mnemon`**, because an official multi-arch image means none of
the source-patching machinery that environment needs. Compose archetype,
not `run.sh`.

| Field | Value |
|:---|:---|
| Image | `nousresearch/hermes-agent:latest` — pin a version tag if one exists, since `check-updates.sh` compares running image IDs |
| State | `~/.hermes` — memory and self-written skills. This is the whole value of the thing; back it up |
| Dashboard | Protect with `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` / `_PASSWORD` — document as **required**, since the dashboard drives a real terminal |
| Channels | Telegram, Discord, Slack and others — tokens in `.env`, same shape as `nanoclaw-mnemon` |

Because Hermes writes its own skills and accumulates memory, its
`maintenance.yaml` matters more than most: an environment whose value is
entirely accumulated state deserves a backup path from day one, not after
the first loss.

### `environments/herdr-client/` — client-side, Mac or Pi

**Standalone by default. Firstmate is not a dependency and is not
installed here.** This environment installs the Herdr binary, deploys a
config, and generates a session pointing at whatever agent environments
are deployed — nothing else. Everything below works with no firstmate
anywhere on the machine.

Follows `mac-terminal-setup`, which is already a client-side environment:
`run.sh` archetype, no container, installs into `$HOME`, backs up
anything it overwrites into
`~/.pi-bootstrap-backups/<env>-<timestamp>/`.

| Field | Value |
|:---|:---|
| Archetype | `run.sh` sourcing `lib/deploy-lib.sh`, then `_selflog_start "$SCRIPT_DIR" "${REBUILD_POLICY:-FAST}"` |
| OS handling | Detect and branch, not guard-and-exit — first dual-platform environment in this space |
| Install | The official installer on both platforms; it resolves the platform from `uname -m` and **verifies the download's SHA-256 against the release manifest itself**. Pin a version. Precheck `uname -m` for `aarch64` and fail clearly on 32-bit (`armv7l`), which upstream does not build |
| Config | Repo-managed `config.toml` → `~/.config/herdr/config.toml`. **Must set a non-default prefix** — see below |
| Deployed check | `kind: marker`, value = installed binary path |

#### Machines: it is not Mac *or* Pi, it is both

Herdr has a first-class multi-machine mode: `herdr machine add <host>
--label "…"`, plus `list`, `rename`, `enable`, `disable`, `remove`. Its
changelog describes "a combined agent list, machine-scoped navigation,
notifications, and automatic reconnects… a disconnected machine does not
interrupt the others."

So the intended shape is `herdr-client` deployed on **both Macs and the
Pi**, dividing the work cleanly:

- **Machines** — host to host. Herdr's own feature, one command, nothing
  for this repo to build.
- **Session generator** — host to containers. Still this repo's job,
  since only it knows the ports.

Two operational details from Herdr's own docs:

- **Pin the same version on every machine.** Client and server versions
  need not match, but an incompatible one triggers approval-based setup
  which "asks before stopping it and its pane processes, then starts the
  compatible server", defaulting to No.
- **`machine add` can stop the remote server**, killing its panes — the
  same cost as the STOP policy, arriving from a different direction.
  State this in the README next to the STOP semantics.

#### Every pane here is nested tmux — deconflict the prefix

Not a nanoclaw quirk, a universal one: **every agent environment in this
repo auto-attaches you to a tmux session inside its container.** So any
Herdr pane into any of them is Herdr → ssh or docker exec → tmux. Two
multiplexers, stacked.

They collide out of the box: Herdr's default prefix is `ctrl+b`, and none
of this repo's `.tmux.conf` files override tmux's own `ctrl+b` default.
Herdr is designed to be polite — its docs note the keymap is
"prefix-first so Herdr does not steal input from shells, editors, tmux,
or terminal apps" — but a shared prefix still means the outer
multiplexer consumes the keystroke the inner one was waiting for.

**Fix it in one place: the repo-managed `config.toml`.** `[keys] prefix =
"…"` sets it, and Herdr also documents a "vetted prefix-free setup" worth
evaluating. One file in one new environment; not a single existing
environment is touched.

#### Policy semantics

`STOP` kills the Herdr server, so `run.sh` must reference
`$REBUILD_POLICY`. That obliges every branch to do something distinct:

| Policy | Behaviour |
|:---|:---|
| `FAST` | Install if missing, deploy `config.toml`, no-op if already at the pinned version. Does not start the server — Herdr's server starts when the user runs `herdr`, restoring the saved session shape |
| `CLEAN` | Force reinstall/upgrade to the pinned version, **then stop the server**. Herdr's install docs note package-manager updates do not get live handoff and the compatible old server keeps running, so a `herdr server stop` is how server-side changes take effect. A CLEAN that upgrades the binary and leaves the old server running would be the silent-stale-copy failure this repo has been bitten by before |
| `STOP` | `herdr server stop` — documented first-class, alongside `herdr session stop <name>` |
| `TEARDOWN` | Server stop, then remove the binary and `~/.config/herdr`, backing the config up first |

**What STOP actually costs.** Herdr's docs: "if the Herdr server stops
and starts again, the original pane processes are gone. Herdr restores
the saved session shape: workspaces, tabs, panes, cwd, layout, and
focus." Shape survives; processes do not. Because panes are SSH or
`docker exec` clients into agent containers, stopping the server kills
the *client connections*, not the agents, which keep running in each
container's own tmux.

Worth documenting alongside: **detach is not STOP.** `ctrl+b q` detaches
the client while panes and agents keep running.

**Small presentation gap this exposes:** `deploy.sh`'s STOP confirmation
is hardcoded per-policy and reads "Pause [env]'s running container(s)?
They'll stop responding until resumed with FAST." For a host-only
environment with no containers that wording is wrong. Either accept it as
a known inaccuracy or let an environment supply its own confirm text —
worth deciding once, since `collie-client` hits the same thing.

### `environments/collie-client/` — client-side, phone access

Same shape as `herdr-client`, with preconditions checked *before*
anything is touched — the repo's "anchors are checked before use, never
guessed" rule. Missing any precondition fails loudly with the reason and
installs nothing.

| Field | Value |
|:---|:---|
| Preconditions | herdr installed · tailscale installed · tailscale logged in |
| Front door | `tailscale serve` — tailnet-only HTTPS |
| Never | `tailscale funnel` — publishes to the open internet. `run.sh` should actively check nothing is funnelling Collie's port and refuse, rather than merely avoiding configuring it |
| Binaries | v1.8.0 ships `linux-arm64`, `macos-arm64` and `linux-x64`, each with a `.sha256`. No macOS x86_64 build — not a constraint here, both Macs are Apple Silicon |
| Policy | Branches on `$REBUILD_POLICY`: FAST installs and configures; CLEAN reinstalls at the pinned version; STOP stops the bridge **and** withdraws the `tailscale serve` mapping, so "stopped" means genuinely unreachable; TEARDOWN also removes binary and config |
| Depends on | A running Herdr server — Collie bridges its Unix socket. Since `herdr-client`'s STOP kills that server, Collie's FAST should report the dependency clearly rather than failing obscurely |

**The privilege chain.** Collie acts with the full shell privileges of
whoever runs it — functionally remote shell access from a phone. Chained
with Herdr, that is: **phone → Collie → Herdr → agent sessions.**

The mitigation is already in the design and is free: have Herdr's panes
reach agents over **SSH to the published ports (2222–2227)** rather than
via `docker exec`, even on the machine hosting the containers. Every
agent environment already exposes SSH with read-only `authorized_keys`.
The phone-reachable path then lands in an unprivileged container account
rather than at the container runtime.

Per repo convention the residual caveat belongs in three places —
refused in `run.sh`, stated in the README where it applies, carried in
`info.yaml`'s notes — plus an explicit interactive confirm before
install, the same mechanism `mac-terminal-setup` uses for its whimsy
prompt but for a security decision.

---

## The session generator

Anyone can `brew install herdr`. What this repo uniquely knows is which
agent environments are deployed and what port each listens on — and that
is why `herdr-client` earns a folder.

| Environment | SSH port | Attach |
|:---|:---|:---|
| `claude-cli` | 2222 | tmux session over ssh |
| `aider` | 2223 | tmux session over ssh |
| `codex-cli` | 2224 | tmux session over ssh |
| `opencode` | 2225 (proposed) | tmux session over ssh |
| `omp` | 2226 (proposed) | tmux session over ssh |
| `pi` | 2227 (proposed) | tmux session over ssh |
| `openclaw` | — | `openclaw-cli-tmux` via docker exec |
| `nanoclaw-mnemon` | — | admin session only; group containers are dynamic |

A custom action — "Generate herdr session from deployed environments" —
reads each deployed environment's `.env` and emits a herdr workspace with
one pane per agent.

**Generate SSH panes rather than `docker exec` panes**, falling back to
`docker exec` only where no SSH port exists. One pane shape then covers
both local and remote, and it keeps the phone-reachable path pointed at
an unprivileged container account.

With Herdr Machines carrying the host-to-host hop, **each machine
generates panes for its own local containers** and Herdr stitches the
machines together. No cross-host SSH wiring to synthesise.

**Because environments work on different repos, this is a portfolio view,
not a fleet view.** Each pane should be labelled with the repo its
workspace points at, not just the agent name — six panes reading
"claude", "codex", "aider" tell you nothing about which project each is
in, which is the only thing you need when the sidebar says one is
blocked.

**This is the one genuinely new coupling in the design:** environments
here are self-contained, and this would be the first that reads *other*
environments' `.env` files. If deferred,
`docs/refactoring-opportunities.md` is where it gets recorded.

---

## Skills and distros: persistence exists, provisioning doesn't

Four things in this catalogue are not environments at all — they are
content that installs *into* an agent.

The repo half-supports this already. `codex-cli` mounts
`codex_cli_user_home:/home/codex`, whose comment explicitly names
"personal `~/.agents` guidance/skills" among what it preserves, and
`claude-cli` mounts `claude_cli_home:/home/claude/.claude`, so
`~/.claude/skills/` persists the same way. **Anything dropped into those
homes already survives rebuilds. What is missing is a repo-managed,
reproducible way to declare that an environment should have a given skill
or distro** — so a fresh deploy starts empty.

### The four cases

- **firstmate** — an agent *distro*: `AGENTS.md`, bundled skills, helper
  scripts, policies. There is no app; the cloned repo is the distro.
  Agent-agnostic, so it applies across several environments at once.
- **pstack** — a Cursor plugin by poteto (23 workflow skills, 22
  playbooks, 21 principles, entered through the sticky `/poteto-mode`).
  **Cursor is the distribution mechanism, not the boundary:** community
  ports carry it to Claude Code, Codex and OpenCode
  ([pstack-claude](https://github.com/michael-denyer/pstack-claude),
  [open-pstack](https://github.com/ericlitman/open-pstack)). A port means
  tracking upstream through a third party. Note
  [backnotprop/pstack](https://github.com/backnotprop/pstack) is a
  straight mirror with no translation — Cursor-only despite looking
  standalone. **The name is a trap**: an unrelated
  [no-session/pstack](https://github.com/no-session/pstack) (a fork of
  [gstack](https://github.com/garrytan/gstack)) shares it exactly.
- **mattpocock/skills** — "Skills For Real Engineers", MIT. Most useful
  here for what it demonstrates about distribution (below).
- **herdr's own** — Herdr ships a `skills/herdr` directory. Upstream
  projects are now shipping agent skills alongside their binaries, so
  this category will keep growing.

### Pi's extension ecosystem is a third provisioning mechanism

Pi has a large community extension ecosystem installed with `pi install`
— roughly 27 packs. Spot-checking nine of the named repositories, all
nine exist. **So `pi install` sits alongside Claude Code plugins and
`npx skills add`: the hope of one mechanism covering the repo is already
gone.**

Four of those packs intersect decisions made here, and are worth knowing
about rather than adopting:

- **signetai** — syncs memory, identity docs, session logs *and secrets*
  across Pi, Hermes, Claude Code, Codex and OpenCode. **Directly
  conflicts with "no shared tokens."** If ever wanted, that decision must
  be revisited deliberately, not undone by installing a convenience.
- **pi-web** — `/web` and `/remote`, phone and browser controlling the
  same terminal agent. **Overlaps Collie**; two phone-reachable surfaces
  with two exposure models.
- **cc-safety-net** — intercepts destructive git/filesystem operations
  across seven harnesses. A counterweight to firstmate's `--yolo` posture
  worth knowing exists.
- **pi-dispatch** — runs Pi as a service with cron and GitHub issue/PR
  triggers, its own container, persistent queue and spending cap. The
  only item that is environment-shaped rather than extension-shaped, and
  a genuinely different product from the interactive `pi` environment.
  Out of scope for now.

### Subscribe or vendor — the axis this turns on

Matt Pocock's repo states the choice most clearly because it ships both:

- **Subscribe** — `claude plugins install mattpocock-skills`, "a managed,
  read-only bundle that updates when I ship, so you subscribe rather than
  fork".
- **Vendor** — `npx skills@latest add mattpocock/skills`, which "writes
  the skills into your repo as ordinary files you own and can edit.
  Nothing updates behind your back".

**Vendoring is the better fit here**, on this repo's own precedent: it
already vendors config it could have fetched, pins versions deliberately,
and treats "the deploy reproduces exactly what is in the repo" as the
point. A bundle that updates itself between deploys would reintroduce the
class of problem `nanoclaw-mnemon`'s version-marked patches exist to
prevent.

**Firstmate corroborates that `npx skills add` is the ecosystem's
mechanism**, and shows how to live with it: it splits `skills/` ("public,
installer-facing skills meant to be installed standalone into any
project") from `.agents/skills/`, which assume a live firstmate home and
would be "meaningless, or actively misleading, installed anywhere else".
The internal ones carry `metadata.internal: true` specifically to hide
them from installer discovery.

### Firstmate is heavier than "a repo you clone"

Two findings from its `bin/` and tests that change what adopting it costs:

- **Crewmates run with permissions skipped, by design.** Its own test
  harness asserts the launch line contains `--yolo` and comments that it
  "is what makes a crewmate pane viable at all". Safety is deliberately
  relocated from the input gate to the *environment*. That means the
  container boundary and the per-environment token scope stop being
  belt-and-braces and become **the actual safety mechanism**.
- **It expects a whole toolchain.** References across `bin/`:
  `tasks-axi` (246), `no-mistakes` (203), `treehouse` (104), `axi` (77),
  `quota-axi` (44), `gh-axi` (25). And the first mate "detects and offers
  to install supported missing tools after you approve" — it
  **self-provisions at runtime, inside the container**, which is in
  tension with a reproducible image.

### Firstmate and Herdr: independent, and layered when combined

Neither requires the other, and the normal configuration uses only one:

- **Herdr alone** *(recommended start)* — what `herdr-client` installs.
  A multiplexer with the agent-state sidebar, plus Herdr's own optional
  `skills/herdr`, which requires `HERDR_ENV=1` and refuses to act if the
  agent is not inside a Herdr-managed pane.
- **Firstmate alone** — the normal configuration. tmux is its hard
  default and verified reference backend.
- **Both** — and the direction matters: **firstmate controls, Herdr is
  the substrate.** `fm-spawn.sh` creates crewmates into whichever backend
  is configured; the zero-token bash watcher reads the resulting pane
  state. You configure Herdr as firstmate's backend, not the reverse.

**Upstream's composition assumes both live on the same machine. Here they
do not** — firstmate runs *inside* an agent container; Herdr runs
*outside* it. Firstmate's herdr backend drives Herdr through its Unix
socket, which a container cannot reach unless that socket is mounted in.

**Settled: firstmate uses the tmux backend inside the container.** It is
firstmate's hard default and the configuration upstream verifies, so this
is running it the ordinary way rather than compromising. Running Herdr
inside the containers too would need a second multiplexer per image and
would put crewmates in Herdr's panes where STOP kills them. The only
thing that buys is per-crewmate sidebar state. Bind-mounting the host's
Herdr socket into a container is **advised against** — Herdr's socket API
can spawn panes and prompt agents, so it hands a container control of the
host's terminal multiplexer.

**Option A fits the existing tmux design.** The first SSH login creates a
long-lived session (`claude`, `aider`) running the agent in window 0;
every later login creates a *grouped* session `client_$$` with
`destroy-unattached on`. Grouped sessions **share the window list** while
keeping an independent current window — so crewmate windows firstmate
creates appear in every attached client's window list automatically.

### Recommendation

Record the provisioning question in `docs/future-enhancements/` as an open
design question, but a narrower one than it first looked: **vendor rather
than subscribe, evaluate `npx skills add` before building anything
bespoke**, and treat per-image system dependencies (Chromium, bun,
treehouse) as a separate second problem. It gates none of the
environments above.

---

## Secrets, scope and GitHub access

### How secrets work today

| Aspect | Mechanism |
|:---|:---|
| Storage | `environments/*/.env`, gitignored repo-wide; `.env.example` stays tracked. The gitignore comment records this was a *fix* — only `openclaw`'s was ignored originally, leaving others "untracked-but-not-ignored" |
| Entry | `deploy.sh` builds a dialog form from `.env.example` and writes `.env` |
| Into the container | The `/etc/environment` mechanism: PAM applies that file to **every future SSH login shell**, whereas docker-compose's `environment:` block only reaches PID 1. Entrypoints strip the old line before appending. Deliberately **no token file under `~/.ssh` or `~/.claude`** |
| Backup | `backup.sh` includes `.env` by default, offers `--no-env`, warns the archive is sensitive |
| Log leakage | `environments/*/logs/` is gitignored because ".env values a run echoes back could end up in here" |

### How scope works today

Scope is expressed **structurally, not as policy** — what you mounted is
what the agent can reach.

- **Filesystem:** exactly one workspace bind mount per agent. That single
  path is the blast radius.
- **User:** non-root throughout (uid 1000, PUID/PGID remap).
- **Docker socket:** mounted by only three environments — `portainer`,
  `pihole-wireguard`, `nanoclaw-mnemon`.
- **SSH:** `authorized_keys` mounted read-only.

### GitHub access

`claude-cli`'s README documents the canonical pattern, lightest first, and
new environments should copy it:

1. **SSH agent forwarding** — gets you `git` over SSH, but not the
   GitHub API.
2. **A fine-grained PAT in `GH_TOKEN`**, scoped to just the repos you
   want reachable. The entrypoint writes it to `/etc/environment` and runs
   `gh auth setup-git` once, wiring `gh`'s credential helper into git — so
   plain `git push`/`clone` over HTTPS pick it up too. Changing it needs
   only `FAST`.

> **Pre-existing bug, found while checking this and fixed in the same
> change.** `aider`'s entrypoint wrote `GH_TOKEN` into
> `/etc/environment` using the same mechanism as `claude-cli` — but the
> image did **not** install `gh` and never ran `gh auth setup-git`. Since
> git has no native notion of `GH_TOKEN`, nothing wired a credential
> helper and the token sat in every login shell unused: exposure without
> function. `aider` now installs `gh` from the same official apt repo the
> other CLI environments use, runs `setup-git`, and documents the whole
> path in its README's "Connecting to a GitHub Repo". Existing installs
> need one `CLEAN` to pick up the binary. This also unblocks `aider` for
> firstmate, which requires an authenticated `gh`.

### What none of this hides from the model

The secrets model hides values from git, optionally from backups, and
from other environments. **It does not hide them from the agent.** The
`/etc/environment` mechanism puts every value into the agent's own login
shell; an agent with a bash tool reads them with `env`. Pi's entire
toolset is read, write, edit and bash, and firstmate crewmates run with
per-call approval deliberately disabled.

Some of that is irreducible — a provider key has to be in the process
that calls the provider. Three things change the exposure:

- **Agent forwarding** is **the only mechanism here that genuinely hides
  a credential from the agent**. The private key never enters the
  container; the agent can *use* it through the forwarded socket but
  cannot read it. It deserves to be described as such, not merely as the
  "lightest" option.
- **Executor** gives real hiding for everything behind it, but not for
  the credential used to reach Executor. The win is **one revocable
  credential instead of N provider keys** — a blast-radius argument.
- **Per-environment scope** is the mitigation that actually holds.
  Exposure is assumed; containment is the defence.

### Can it be fixed, or is scoping the answer?

Both, for different threats:

- **Accidental leak** (agent prints its environment, value lands in a
  provider-held transcript): scoping does not help at all. Only expiry
  and rotation shorten the window.
- **Hostile or injected agent**: scoping is exactly the right defence.

The general principle: **a secret the agent's own process can use is a
secret the agent can read.** The only way out is keeping it in a
different process and handing the agent a channel:

1. **Agent forwarding, for git over SSH** — already in the plan.
2. **GitHub through Executor, for the API** — the strongest available
   fix, needing no new component. Executor holds the credential and
   exposes GitHub as MCP tools under per-tool policy, so **the agent
   never holds a PAT**.
3. **Do not give the agent a push-capable credential at all** — the agent
   commits locally; a separate process pushes and opens PRs. Already the
   shape firstmate argues for.

**OneCLI** ([onecli/onecli](https://github.com/onecli/onecli)) implements
the most general form: a Rust gateway that "intercepts outbound requests
(HTTPS included, via MITM) and injects credentials", with agents holding
only a proxy token. That is strictly more general than Executor, since it
reaches anything making an HTTP request rather than only MCP-speaking
agents. **But it is a platform, not a component** — migrations, api, web,
gateway, runner, ssh-terminator and channel-adapter against Postgres and
Redis, with its *own* agent sandboxes that overlap this repo's entire
container model. Open-core, and MITM means installing its CA into every
agent container. **Take the design, not the dependency.**

**Proportionate recommendation:** scope tightly (settled), add an expiry
and rotate, use agent forwarding wherever git-over-SSH suffices, and put
GitHub behind Executor once Executor is deployed.

### The evaluation exception

Comparing agents means running several against the **same** repo, which
is a deliberate exception to "token scope mirrors workspace scope": one
token scoped to a shared comparison repo, used by several environments at
once. Worth writing down as an exception rather than letting it quietly
erode the rule.

### One small gap

Nothing does `chmod 600` on `.env`, so default umask leaves it group- and
other-readable. Low impact on a single-user machine, a one-line fix, and
three READMEs already discuss file permissions.

---

## How this touches `nanoclaw-mnemon`

### The derived-image trap applies to everything installed

NanoClaw gives any conversation group with custom packages **its own
derived image**, `nanoclaw-agent-v2-<slug>:<group-id>`, built from the
base. `run.sh` states the consequence flatly: "a derived image is never
rebuilt by anything in this repo. CLEAN rebuilds the BASE image and stops
there — upstream treats derived images as operator-managed, rebuilt only
via `ncl groups restart --rebuild`."

**So anything baked into an agent image — `mcporter`, a skills package, a
firstmate distro — reaches only groups that have no derived image, and
every group that does keeps the old copy indefinitely.** Anything added
must go through the existing post-rebuild sweep, not around it.

This is the concrete reason the skills-provisioning question cannot be
answered once for the whole repo: what works for `claude-cli` — a named
volume persisting `~/.claude/skills/` — has no equivalent where
containers are spawned per group from per-group images.

### MCP is the proven path here — not mcporter

NanoClaw's agents already speak MCP, and this repo already registers a
server into them: `/add-ollama-tool` wires an Ollama MCP server "into
every agent-group container's MCP config on every deploy" through the
same idempotent, version-marked text-splice mechanism as the other
patches.

**So the way to give NanoClaw agents Executor's catalogue is to register
Executor as an MCP server using that proven pattern** — not to install
`mcporter` into the image, which would walk into the derived-image trap
for no benefit.

The repo has already reasoned this out elsewhere: its README, weighing
llm-wiki implementations, prefers the one that "uses an MCP server rather
than a Claude Code plugin, which sidesteps the open question the other
four share — *whether Claude Code's plugin-install mechanism even works
inside NanoClaw's agent-runner container*". **That open question applies
verbatim to pstack and the other skills packages.**

Any such patch inherits the repo's patch discipline: a version-marked
block, an anchor checked before use, `|| true` at the call site, and **a
version bump whenever the block's text changes**.

### Herdr can drive the orchestrator, and only watch the crew

- **Admin session — yes, fully.** `docker exec -it nanoclaw-mnemon tmux
  attach -t claude` lands in a real Claude Code TUI, and `claude` is on
  Herdr's list of detected agents — so the sidebar shows genuine
  blocked/working/done state.
- **Group agents — watch, not control.** `docker ps --filter
  name=nanoclaw-agent` enumerates them, but what runs inside is a
  headless Claude Agent SDK process driven by chat messages, with no
  terminal UI. Herdr would report a generic shell, and there is nothing
  to type at.
- **Logs** — `docker logs -f` in a pane is honest observation.

A generated workspace should carry **one pane for the admin session** and
treat group containers as ad-hoc opens; the set changes as conversation
groups come and go, so a generated list would be stale by design.

### Firstmate does not apply

Firstmate's model is a terminal orchestrator dispatching crewmates into
panes and git worktrees to produce PRs. NanoClaw's agents are
chat-driven, per-conversation-group and long-lived. Treat the two as
disjoint.

### Shared Ollama is the resource question

NanoClaw reaches Ollama over `host.docker.internal:11434` — shared with
`chat-frontends` and `llm-gateways`, and already the subject of a
documented past bug. Adding coding-CLI environments that may also route
through it is a contention question worth answering before it is
discovered under load.

---

## Presentation

`config/environments.yaml` currently puts 8 entries under "AI
Assistants". These candidates would make it 15, mixing an SSH-in coding
CLI with an always-on channel bot with an MCP proxy. **Regroup by what
you do with it, not by vendor:**

| Category | Environments |
|:---|:---|
| **Coding CLIs** | `claude-cli`, `codex-cli`, `aider`, `opencode`, `omp`, `pi` |
| **Personal Agent Platforms** | `openclaw`, `nanoclaw-mnemon`, `hermes` |
| **Model & Routing** | `ollama`, `llm-gateways`, `chat-frontends` |
| **Agent Control** | `executor`, `herdr-client`, `collie-client` |

**This is a data-only change.** `config/environments.yaml` is pure
display metadata: `deploy.sh` omits categories that end up empty and
appends anything unlisted to "Other" alphabetically. No code, fully
reversible, and an environment can never be hidden by getting it wrong.

Three further moves, in descending value:

1. **Show deployed state in the environment menu.** `deploy.sh` does not
   today — the `deployed_check` machinery exists but only feeds desktop
   entries. At 25-plus environments "which of these do I actually have
   running?" becomes the primary question. It is a `deploy.sh` change
   rather than data, and carries a performance trap: check with one
   `docker ps` and match names, never per-environment on every render.
2. **Disambiguate, don't just list.** Six coding CLIs need a one-line
   "pick this when…" each. The repo already does this well in `aider`'s
   `info.yaml` notes.
3. **Client-versus-host has no visual channel.** Cheapest honest answer
   is the `-client` name suffix plus category placement. A
   machine-readable `target:` field costs a schema doc plus
   `lib/info-lib.sh` and is only worth it if the menu should behave
   differently.

The README's `## 🗂️ Environments` table is the second surface this
catalogue lives on and should carry the same grouping, or the two drift.

---

## Sequence

Ordered by **value soonest**, not risk lowest. An earlier draft led with
Executor because it was easiest to build — but its whole pitch is
consolidating credentials across agents that do not exist yet, and for a
single operator evaluating candidates it is the *last* thing that pays.

1. **Regroup the menu.** Approved, data-only. Doing it before six
   environments arrive means they land in a structure that already fits.
2. **`herdr-client` on both Macs and the Pi.** The control layer first,
   because it makes evaluating everything else bearable. Install,
   repo-managed `config.toml` with a deconflicted prefix, and `herdr
   machine add` linking the three. Pin the **same version everywhere**.
   Check `uname -m` reports `aarch64` on the Pi first.
3. **The session generator.** Its own step, so the cross-environment read
   reverts cleanly if it proves a mistake.
4. **`collie-client`.** Phone reach over a blocked agent is a daily-life
   change. Needs the SSH-not-`docker exec` pane rule in place, plus
   `tailscale serve`, the funnel refusal and the pre-install confirm.
5. **The evaluation cohort — `pi`, then `opencode`.** Build `pi` first
   and confirm the template end to end. Node 24 plus `mcporter` for
   `pi`; `opencode` needs neither. Add `omp` only if Pi proves
   interesting enough to want its IDE-wired cousin.
6. **`hermes`.** The third daily-driver candidate, and the heaviest. Its
   value is entirely accumulated state, so design the backup path in from
   the start.
7. **Skills experiment.** Start with the vendor path — `npx skills add`
   into one environment — because it is pinned, editable and reversible.
   Keep it to a single environment until the mechanism is understood.
8. **`executor`.** Last, deliberately. Host it on the Mac, not the Pi.

### What "good" means under a research posture

- **Cheap removal matters more than polish.** Most of what gets built
  will be deleted. TEARDOWN and WIPE correctness, and honest
  `no_delete_msg` text, are the features that pay off.
- **Avoid shared infrastructure until the survivors are known.** Wiring
  six coding CLIs into a common credential store creates coupling that
  has to be unpicked when four are removed.
- **Breadth is the point, temporarily.** "Why six coding CLIs" has an
  answer: to find out. The question returns once one is obviously the
  daily driver.

---

## Build pass — 2026-09-11

Things that turned out differently once the environments were actually
built and each upstream was read at the source rather than the doc. Both
corrections below were wrong *in this document* first.

### `pi` has no `OPENAI_API_BASE`-style override — the spec table was wrong

The environment specs table above says all three new coding CLIs "take an
`OPENAI_API_BASE`-style override". **That is false for Pi.** Pi has no
base-URL environment variable at all. A non-built-in provider is declared
in `~/.pi/agent/models.json` — a top-level `providers` object, each
provider carrying `baseUrl`, `api`, `apiKey` and a `models` **array** of
`{ id }` objects — and that is the only route.

Two details that only show up in Pi's own `docs/models.md`:

- **`apiKey` is required even when the endpoint ignores it.** Pi treats a
  model as unavailable until auth is configured, so a keyless local
  server's models would load and then stay invisible in `/model` with
  nothing saying why. `environments/pi`'s entrypoint uses the placeholder
  `gateway`.
- **`compat.supportsDeveloperRole` / `compat.supportsReasoningEffort`**
  exist for OpenAI-compatible servers that reject the `developer` role —
  Ollama, vLLM, SGLang. Worth knowing before concluding a gateway is
  broken.

`opencode` does have a redirect, but also not an env var: a provider
`baseURL` inside `opencode.json`. It additionally offers
`OPENCODE_CONFIG_CONTENT`, an inline runtime override with the **highest
precedence of any config source** — which is exactly why the environment
does *not* use it. It would silently win over whatever the operator later
writes into `opencode.json`.

Only `aider` and `claude-cli` take the env-var form. The habit does not
transfer, and both new environments seed a config file instead — **only
when one does not already exist**, since both files live in persistent
volumes and are edited by hand.

### `anomalyco` is OpenCode's official home, not a third party

The catalogue above says to avoid "the **third-party** `anomalyco/opencode`
Docker image". The org part of that is wrong: `github.com/anomalyco/opencode`
is where OpenCode's own README badges, Homebrew tap (`brew install
anomalyco/tap/opencode`) and download links point, where its installer
fetches release artifacts from, and where `sst/opencode` redirects to.

The operative rule is unchanged — **build from the official installer
rather than pulling someone's prebuilt image** — but it should not be
justified by calling the upstream org third-party.

### Two installer facts that changed the Dockerfiles

- **OpenCode's installer does no checksum verification.** It downloads the
  release archive and unpacks it. Herdr's and Collie's both fetch a
  `.sha256` sidecar and refuse to install without one — which is why those
  two environments deliberately add no verification of their own, and why
  this one recommends pinning `OPENCODE_VERSION` more strongly than
  elsewhere.
- **`OPENCODE_INSTALL_DIR` is documented but not implemented.** OpenCode's
  README shows it; the installer never reads it and hardcodes
  `INSTALL_DIR=$HOME/.opencode/bin`. Since `/home/opencode` is a persistent
  volume, `HOME` is the only lever that keeps the image-owned binary out of
  it — and keeping it out is what stops a CLEAN rebuild leaving the old
  version running while every check reports the new one.

### `maintenance.yaml` globs are first-match across all environments

`lib/maintenance-lib.sh` walks `environments/*/maintenance.yaml` in
directory order and the **first matching glob wins**. A loose pattern in an
early-sorting directory therefore captures a later environment's images.
`environments/pi` is exactly that hazard: `"*pi*"` would have hijacked
`pihole-wireguard`. Both new environments match on the Compose-derived
image name instead (`pi-pi*`, `opencode-opencode*`); `deploy-lib.sh` passes
no `-p`, so the project name is the directory name.

---

## Review pass — 2026-09-10

An external review checked this doc against a separate knowledge base and
flagged eight claims as unverified. Most were verified here originally by
cloning the upstream repository; the review was measuring against its own
wiki, not against primary sources. Re-checking the genuinely open ones
against upstream produced three corrections and two rejections.

### Corrections

- **omp's size was wrong, and understated.** A fresh clone measures **462
  `.rs` files, ~258k lines** — not the ~80k an earlier draft claimed. The
  language claim holds; the number did not. Corrected above.
- **The Pi npm footgun is worse than described.** Four scopes are live
  simultaneously and the dangerous one is the *pre-acquisition* scope,
  still published at v0.73.1 — twelve minors behind current — which older
  guides still name. See the table above.
- **Executor's image is confirmed, and is arm64.** An anonymous ghcr
  manifest request for `ghcr.io/rhyssullivan/executor-selfhost:latest`
  returns an OCI image index containing a `linux/arm64` manifest. That is
  new information, not just confirmation.

### Two suggestions from the review that do not survive checking

- **`npm i hunk` installs the wrong package** — but the tool is real and
  the suggestion survives under its correct name. The npm name `hunk`
  resolves to `shannonmoeller/hunk`, "Multipart files, one hunk at a
  time", unrelated to any of this. The actual tool is
  [modem-dev/hunk](https://github.com/modem-dev/hunk), published as
  **`hunkdiff`** (`npm i -g hunkdiff`, `engines: node >=22`), also
  available via `brew install hunk` or `mise use -g hunk`.

  The name is genuinely crowded: alongside the unrelated npm package there
  are several forks carrying an identical description, and a *different*
  `smolcars/hunk` that is a GPUI diff viewer and Codex orchestrator. This
  is the **third** name collision in this research after two unrelated
  `pstack` projects, and the lesson is now unavoidable: **resolve a tool
  to a repository URL before putting its name in a Dockerfile.** Every
  one of these collisions installs cleanly and silently gives you
  something else.
- **A cross-container mcporter sidecar does not help — though the first
  reason given for that was wrong.** `mcporter serve --http <port>` does
  exist and does bridge over Streamable HTTP; an earlier note here said
  otherwise, based on reading the daemon docs rather than `serve` itself.
  The real objection is that `serve` exposes MCP **to MCP clients**, and
  `aider` is not one, so a sidecar hands it an endpoint it cannot
  consume. See decision 7, which also records the route that *does* work
  — `generate-cli --compile` into a static binary — and revises the
  decision accordingly.

### Follow-ups worth adopting

1. **Start the Pi evaluation from a curated config, not bare.**
   [disler/pi-vs-claude-code](https://github.com/disler/pi-vs-claude-code)
   ships working extensions — `damage-control.ts`, `agent-team.ts`,
   `coms.ts`, `pi-pi.ts`, `purpose-gate.ts` — as a collection of
   customised Pi harnesses. Evaluating Pi against a bare install
   under-represents it, since its whole design is "everything else is
   opt-in".
2. **Time-box the evaluation-exception PAT.** Set its expiry to the
   evaluation window itself, so the shared-comparison-repo token fails
   loudly rather than quietly outliving the exception that justified it.
3. **Hunk (`hunkdiff`) is a good fit for the evaluation specifically.**
   A "review-first terminal diff viewer for agentic coders" built on
   OpenTUI — multi-file review stream, inline agent annotations beside
   the code, watch mode for Git-backed reviews, and difftool support.
   Comparing six coding agents means reading a great many
   agent-authored diffs, which is exactly its use case. Free on the
   Node 24 images (`pi`, `omp`); check the base before assuming it for
   `opencode`, and it is a non-starter in `aider`'s Python image for the
   same reason mcporter is.

   It also ships an agent skill of its own — `hunk skill path` returns a
   file you point an agent at so it can drive the live session. That
   makes **four** upstream projects in this catalogue shipping agent
   skills alongside their binaries (herdr, firstmate, pstack, hunk),
   which is further evidence the provisioning question is not optional
   for long.
4. **`pi-dispatch` versus Hermes cron is a duplicate-scheduling trap.**
   Hermes has native cron; `pi-dispatch` brings its own. Decide the daily
   driver before building scheduling infrastructure twice.
5. **Crewmate windows will appear in Herdr panes whether or not that is
   intended.** Grouped tmux sessions share the window list, so firstmate
   crewmates spawned inside a container become visible to any attached
   client. Decide at design time whether that is useful visibility or
   noise — it is not opt-in.
6. **`no-mistakes` is effectively required for firstmate's full
   automation**, not merely adjacent to it — consistent with the 203
   references to it across firstmate's `bin/`. Any firstmate adoption
   should treat it as part of the package rather than an optional extra.

### Already covered, noted for completeness

The review also raised the Executor-plus-SSH-forwarding combination,
repo-name pane labels, SSH forwarding's status as the only mechanism that
hides a credential from the agent, and signetai's conflict with the
no-shared-tokens rule. All four are already in this document — the last
two as findings this research produced rather than inherited.

### Not adopted

- **CMux as a Herdr fallback.** Herdr pinning has not proved difficult,
  so this solves a problem that has not appeared.
- **Magnitude for local model selection.** Redundant: `environments/ollama/`
  already does this, and does it better. `models.tsv` is a catalog
  carrying `active_gb` (weights read per generated token), RAM min/max and
  hardware tiers; `scripts/manage-models.sh` profiles the host through
  `sysctl` (`hw.memsize`, `hw.pagesize`, `machdep.cpu.brand_string`),
  returns a FITS / CAUTION / EXCEEDS verdict that accounts for **macOS
  memory pressure** rather than free RAM alone, and estimates tokens per
  second from memory bandwidth divided by active weight bytes. A "Pull a
  Recommended Model" action is already wired into the menu.

  It is also broader than Magnitude, which is Apple-Silicon-only. That
  environment's own code comments explain why the extra dimension was
  needed: the `mac8` and `pi8` tiers have byte-identical membership
  because both are "8 GB", but an 8 GB M2 runs `qwen3:4b` at
  conversational speed while an 8 GB Pi 5 runs it at walking pace — so a
  pure RAM-fit answer was addressing the wrong question. Nothing in
  Magnitude's pitch improves on that, and adopting it would add an
  unverified third-party dependency to replace something already tested
  in-repo.

---

## Verify before writing code

- `uname -m` on the Pi reports `aarch64`, not `armv7l`.
- Which of the new environments need a **single-file mount** at all —
  that is the OrbStack tripwire, and each one needs a `pre-deploy.sh`
  placeholder on `claude-cli`'s pattern. Directory volumes are
  unaffected.
- **A port map**, now that roughly eight services co-locate on one Mac:
  SSH 2222–2227, Executor 4788, whatever Hermes publishes, plus the
  existing environments.
- Is `brew install herdr` the official tap or a third-party formula? (The
  installer path is confirmed; the brew path is not.)
- Which Herdr release version to pin — the installer tracks latest by
  default.
- Do Executor and Hermes publish version tags, or only `latest`?
  `check-updates.sh` compares running image IDs. (Both images are
  confirmed to exist and to carry `linux/arm64`; only the tagging
  practice is open.)
- Herdr's `session.json` schema — can a session be generated as a file,
  or must panes be created through the socket/CLI API at runtime? Decides
  whether the generator writes a file or drives a command.
- `omp`'s installer behaviour on arm64, and whether the brew tap or the
  bun package is the better fit inside a container.
- Confirm at build time that `omp` really has no MCP — the only inferred
  cell in the mcporter matrix.
- That `mcporter` runs cleanly on arm64 under Node 24.
- Whether `npx skills@latest add` can run non-interactively with a pinned
  skill selection — decides whether skills provisioning is an existing
  tool or a bespoke build.
- Whether firstmate's crewmate worktrees can be pointed somewhere other
  than inside the bind-mounted workspace — decides how it interacts with
  `backup.sh`. Also means understanding `treehouse`.
- Herdr's version floor for firstmate's "presentation spaces" projection.
- How many concurrent crewmates a machine actually sustains, before
  designing anything around parallel agents.
- Whether Executor can hold the provider keys the coding CLIs currently
  read from their own `.env`.
- **Whether `mcporter generate-cli --compile` actually yields a
  dependency-free binary** — specifically whether an HTTP-backed target
  needs the single-user daemon at runtime. This is the escape hatch
  decision 7 leans on to call its own cost objection obsolete, and it is
  read from documentation rather than tested. Not testable until Executor
  exists at phase 8.
- Whether GitHub-behind-Executor covers what the agents actually need (PR
  create, review, CI status) — decides whether `GH_TOKEN` can leave the
  container environment entirely or only shrink.
- What a fine-grained PAT must be scoped to for firstmate to work end to
  end — the minimum set, not a convenient superset.
- **Restore has never been exercised.** Executor's `/data` holds
  credentials and Hermes's `~/.hermes` *is* the value; `backup.sh` covers
  them, but `restore.sh` has not been tested against either.
