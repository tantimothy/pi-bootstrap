# Pi — Minimal Terminal Coding Harness

A standalone [Pi](https://pi.dev) container reachable over its own SSH
server — same shape as this repo's `claude-cli`, `codex-cli` and `aider`
environments (own sshd, persistent detachable tmux session, bind-mounted
workspace).

No custom `run.sh` — a plain `docker-compose.yml` with `build: .`, using
`deploy.sh`'s generic fallback.

---

## 🧭 Pick this when…

You want a **minimal harness you extend yourself**. Pi gives the model four
tools — `read`, `write`, `edit`, `bash` — behind a system prompt of roughly
200 tokens, and *deliberately omits* sub-agents and plan mode. Its pitch is
that you add what you need as TypeScript extensions, skills, prompt
templates and themes, or install someone else's as a **pi package** from npm
or git.

| Environment | Pick it for |
|:---|:---|
| **`pi`** | A minimal harness you extend yourself |
| `opencode` | A batteries-included terminal agent, native MCP |
| `omp` | IDE-grade tooling — LSP on every file write, debugger ops (not yet built) |
| `claude-cli` / `codex-cli` | A vendor's own agent, with that vendor's subscription auth |
| `aider` | Provider-agnostic, git-commit-per-change workflow |

---

## ⚠️ What "YOLO by default" costs you

Pi has **no permission prompts and no sandbox**, by design. Its author's
argument is direct: *"security in coding agents is mostly theater; if it can
write and run code, it's game over."*

That is a coherent position, and it means two things here are load-bearing
rather than nice-to-have:

1. **The container boundary.** Pi runs as an unprivileged user inside a
   container whose only host access is the one directory you bind-mount. No
   Docker socket, no host filesystem.
2. **A scoped `GH_TOKEN`.** Six coding CLIs working on *different repos* is
   the expected shape here. A token shared across all of them means any of
   them can push to any of the others' projects. **Give this environment its
   own token, scoped to the repos you actually mount.**

Pi does ask before trusting a project folder that carries project-local
settings or extensions (`/trust`, `~/.pi/agent/trust.json`) — but that gates
*Pi's own config loading*, not what the model's `bash` tool may run.

---

## 🔑 Credentials: Pi does not read a `.env` file

This is the one genuine difference from every other agent environment here,
and it fails **silently** — a provider whose key is missing simply does not
appear in `/model`, with nothing saying why.

A key has to already be in the **shell environment** when `pi` launches. The
entrypoint writes the ones you set into `/etc/environment`, which PAM loads
into every SSH login — and the SSH login is where the tmux session, and
therefore Pi, is started. No new plumbing; the mechanism was already here.

Each variable is **deleted before being re-added**, so clearing it in `.env`
and redeploying really clears it. An append-only version would leave a
revoked key working until the volume was wiped.

The alternative is Pi's own `/login` for a subscription (Anthropic Pro/Max,
ChatGPT Plus/Pro, GitHub Copilot), which writes `~/.pi/agent/auth.json`
inside the persistent volume. Leave the API-key variables unset if you use
that.

---

## 🔀 Routing through `llm-gateways`

**Pi has no base-URL environment variable.** No `OPENAI_API_BASE`, no
equivalent — worth stating plainly because `aider` and `claude-cli` both
have one and the habit does not transfer. A non-built-in provider is
declared in `~/.pi/agent/models.json`, and that is the only route.

Set these in `.env` and the entrypoint writes that file for you:

```bash
PI_GATEWAY_BASE_URL=http://host.docker.internal:4000/v1
PI_GATEWAY_API_KEY=<llm-gateways' own LITELLM_MASTER_KEY>
PI_GATEWAY_MODELS=claude-sonnet-5,claude-opus-5,ollama/qwen2.5-coder:7b
```

- **`host.docker.internal`, not `localhost` and not a container name** — `pi`
  and `llm-gateways` are separate Compose projects with no shared network, so
  the host is the only way through. Same reasoning as `aider`'s README.
- **`PI_GATEWAY_MODELS` entries are `model_name` values from
  `llm-gateways`' own `litellm-config.yaml`**, not provider model IDs.
- **An `apiKey` is required even when the endpoint ignores it.** Pi treats a
  model as unavailable until auth is configured, so a keyless local server's
  models would load and then stay invisible in `/model`. The entrypoint uses
  the placeholder `gateway` when you leave `PI_GATEWAY_API_KEY` unset.

> **Written once, never rewritten.** `models.json` lives in a persistent
> volume and is a file you edit by hand — extra models, `modelOverrides`,
> `compat` flags for servers that reject the `developer` role. The entrypoint
> seeds it only when it does not already exist, so a redeploy cannot discard
> your edits.

---

## 📦 The npm scope is a real trap

Four scopes publish a package called `pi-coding-agent`, and **all four
install without error**:

| Package | Version | What it is |
|:---|:---|:---|
| `@earendil-works/pi-coding-agent` | 0.85.1 | **current canonical Pi** — what this image installs |
| `@mariozechner/pi-coding-agent` | 0.73.1 | pre-acquisition Pi, still published |
| `@oh-my-pi/pi-coding-agent` | 18.1.16 | **omp — a different product** |
| `@badlogic/pi` | 0.1.1 | — |

The dangerous one is **not** omp: its version scheme is so different that a
pinned version is unambiguous. It is **`@mariozechner`**, which older guides
still name, which installs cleanly, and which silently gives you a Pi twelve
minor versions stale with nothing to catch it.

The Dockerfile hardcodes the scope and pins the version via the
`PI_PACKAGE_VERSION` build arg. Check what actually landed:

```bash
docker exec pi npm ls -g --depth=0 | grep pi-coding-agent
```

> **`pi update --self` is the wrong lever here.** It updates Pi *inside the
> container*, where the change lives in a volume and is silently discarded by
> the next CLEAN rebuild. Bump `PI_PACKAGE_VERSION` in `.env` and run CLEAN —
> that is the change that survives.

---

## 🔌 Why `mcporter` is in this image

Pi has **no native MCP, by design**. Upstream's stated reason is context
cost: an MCP tool schema runs 7–14k tokens, against a system prompt of
roughly 200. An MCP *extension* exists, and installing it puts that overhead
straight back.

[mcporter](https://www.npmjs.com/package/mcporter) is an MCP **client**
runtime — `list`, `call`, `resource` — so MCP becomes a **command** the
`bash` tool runs rather than a tool schema loaded into every prompt. **It
costs nothing until it is invoked.** That is the whole argument for putting
it here and not in `opencode` or `claude-cli`, which have native MCP already.

```bash
mcporter list
mcporter call <server> <tool> '{"arg": "value"}'
```

It gets no `environments/` folder and no menu entry — it is a per-image
dependency, the same treatment `gh` gets.

---

## 🆚 This is not OpenClaw's Pi

`environments/openclaw` also contains Pi — as its **internal agent harness**,
via the `pi-agent-core` SDK, called from OpenClaw's own gateway. That is
OpenClaw's business and stays untouched.

**The two can run different Pi versions, and that is expected, not a bug.**
They are independent installs that happen to share an upstream project.
Neither should ever be "aligned" to the other.

(For completeness, since the names invite the assumption: **`nanoclaw-mnemon`
does not use Pi at all** — NanoClaw runs on Anthropic's Claude Agent SDK.
The repo's two "claw" environments sit on different harnesses.)

---

## 🚀 Connecting

```bash
ssh -p 2227 pi@localhost
```

Each interactive login attaches to a client-specific tmux session **grouped**
with the persistent `pi` base session, so two clients share history while
viewing different windows. The base session starts `pi -c` (continue the most
recent session for the workspace), falling back to a bare `pi` on the very
first launch.

| Inside Pi | |
|:---|:---|
| `/model`, `Ctrl+L` | Switch model. `Ctrl+S` in the picker saves one as the startup default |
| `/login` | Subscription auth |
| `/trust` | Save a project-trust decision |
| `/settings` | Edit `settings.json` interactively |
| `/hotkeys` | The full keymap |

---

## 🛰️ Network calls Pi makes on its own

Two, both disableable, both documented because a self-hosted environment
should not surprise you:

| | What | Off switch |
|:---|:---|:---|
| Update check | `GET https://pi.dev/api/latest-version` at startup | `PI_SKIP_VERSION_CHECK=1` |
| Install telemetry | Anonymous version ping after install/update | `PI_TELEMETRY=0` |
| Both, plus package update checks | — | `PI_OFFLINE=1` |

---

## 🗑️ Removal

| Policy | What it does |
|:---|:---|
| **STOP** | Stop the container; everything persists |
| **TEARDOWN** | Remove the container; the volumes survive |
| **WIPE** | Remove the three volumes — Pi's state, the home directory, the SSH host keys |

**WIPE does not touch `PI_WORKSPACE_PATH`.** That is your repository on the
host, not this environment's data.

⚠️ The `agent_home` volume holds any subscription credential saved by
`/login`, plus every saved session. Wiping means logging in again and losing
the session history.

---

## 📚 See also

- `docs/future-enhancements/agent-control-environments.md` — why this
  environment exists, how it compares to the other five coding CLIs, and the
  settled decisions behind these choices.
- `environments/herdr-client/` — one window over every agent environment,
  with per-pane blocked/working/done state. Its session generator will emit a
  pane for this container labelled `pi:<your-repo>`.
- `environments/llm-gateways/` — the LiteLLM proxy the gateway section above
  points at.
