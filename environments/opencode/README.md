# OpenCode — Batteries-Included Terminal Coding Agent

A standalone [OpenCode](https://opencode.ai) container reachable over its own
SSH server — same shape as this repo's `claude-cli`, `codex-cli`, `aider` and
`pi` environments (own sshd, persistent detachable tmux session,
bind-mounted workspace).

No custom `run.sh` — a plain `docker-compose.yml` with `build: .`, using
`deploy.sh`'s generic fallback.

---

## 🧭 Pick this when…

You want a **batteries-included terminal agent**: native MCP, LSP, a
permission system, sub-agents, custom commands, skills, plugins, themes, an
ACP/SDK surface, and a headless `serve`/`attach` mode for driving it from
elsewhere. It is powered by the [Models.dev](https://models.dev) provider
list, so most providers work straight from `opencode auth login` with no
config file at all.

| Environment | Pick it for |
|:---|:---|
| **`opencode`** | A batteries-included terminal agent, native MCP |
| `pi` | A minimal harness you extend yourself |
| `omp` | IDE-grade tooling — LSP on every file write, debugger ops (not yet built) |
| `claude-cli` / `codex-cli` | A vendor's own agent, with that vendor's subscription auth |
| `aider` | Provider-agnostic, git-commit-per-change workflow |

---

## 🔌 No `mcporter` here, deliberately

`environments/pi` installs [mcporter](https://www.npmjs.com/package/mcporter)
because Pi has **no native MCP by design** — an MCP tool schema costs 7–14k
tokens of context against Pi's ~200-token system prompt, so MCP has to become
a *command* rather than a loaded schema.

OpenCode has native MCP. An MCP client runtime on top would be redundant, so
it is not installed. Configure MCP servers in `opencode.json` the normal way.

(Node is still in the image — for MCP servers and LSP servers to run under,
not for OpenCode itself, which ships as a self-contained binary.)

---

## 📦 Two things about the installer worth knowing

Both were checked against the installer's source rather than its
documentation, and both shaped the Dockerfile.

### It does no checksum verification

It downloads the release archive and unpacks it. `herdr`'s and `collie`'s
installers both fetch a `.sha256` sidecar and refuse to install without one;
this one does not.

Nothing here can fix that, but **pinning `OPENCODE_VERSION` at least makes
what you get reproducible** — which is why `.env.example` recommends it more
strongly than for the other environments.

### `OPENCODE_INSTALL_DIR` is documented but not implemented

OpenCode's README shows `OPENCODE_INSTALL_DIR=/usr/local/bin curl … | bash`.
The installer script **never reads that variable** — line 68 hardcodes
`INSTALL_DIR=$HOME/.opencode/bin`.

That matters because `/home/opencode` is a **persistent volume**. A binary
installed there would survive a CLEAN image rebuild and keep running the old
version while every check reported the new one — the silently-stale-copy
failure recorded in `docs/lessons-learned/nanoclaw-mnemon.md`.

So the Dockerfile sets `HOME=/opt/opencode` for that one `RUN` (the only
lever the script actually honours) and copies the binary to
`/usr/local/bin`, which `/etc/profile`'s PATH already covers. It also passes
`--no-modify-path`, since the installer edits `.bashrc`/`.zshrc` by default
and that is a persistent-volume edit for the same reason.

> **On the `anomalyco` org.** Release artifacts come from
> `github.com/anomalyco/opencode`. That **is** the project's official home —
> its own README badges, Homebrew tap and download links all point there, and
> `sst/opencode` redirects to it. The thing to avoid is a *third-party Docker
> image*, not that organisation.

---

## 🔀 Routing through `llm-gateways`

OpenCode redirects a provider with a `baseURL` in `opencode.json`, not
through an environment variable:

```bash
OPENCODE_GATEWAY_BASE_URL=http://host.docker.internal:4000/v1
OPENCODE_GATEWAY_API_KEY=<llm-gateways' own LITELLM_MASTER_KEY>
```

- **The `openai` provider is the one redirected**, because LiteLLM speaks the
  OpenAI API. Models are then named `openai/<model_name from
  litellm-config.yaml>`.
- **`host.docker.internal`, not `localhost` and not a container name** —
  `opencode` and `llm-gateways` are separate Compose projects with no shared
  network, so the host is the only way through. Same reasoning as `aider`'s
  README.
- `OPENCODE_GATEWAY_API_KEY` is written into the container's
  `OPENAI_API_KEY`, since that is the provider whose `baseURL` moved. It is a
  separate variable so that pointing at the gateway does not mean overloading
  `OPENAI_API_KEY`, which means something else when the gateway is not in use.

> **Seeded, never rewritten.** `opencode.json` lives in a persistent volume
> and is the file you edit by hand — agents, permissions, MCP servers,
> formatters. The entrypoint writes it only when it does not already exist.
>
> OpenCode *does* offer `OPENCODE_CONFIG_CONTENT`, an inline runtime override
> with the **highest precedence of any config source**. This environment
> deliberately does not use it: it would silently win over whatever you later
> write into `opencode.json` — the same failure in a less visible form.

---

## 🔐 Permissions, and what `--auto` costs

OpenCode's permission system is the main thing distinguishing it from `pi`'s
YOLO-by-default posture. `opencode agent create` can scope an agent down to a
named set (`bash`, `read`, `edit`, `glob`, `grep`, `webfetch`, `task`,
`todowrite`, `websearch`, `lsp`, `skill`) with everything omitted denied.

Setting `OPENCODE_AUTO_APPROVE=1` passes `--auto`, which approves every
permission not explicitly denied — **turning that off**. The container
boundary and a scoped `GH_TOKEN` are then the only things doing that job, as
they are for `pi`. That may well be what you want in a container; it should
just be a decision rather than a default.

---

## 🚀 Connecting

```bash
ssh -p 2225 opencode@localhost
```

Each interactive login attaches to a client-specific tmux session **grouped**
with the persistent `opencode` base session, so two clients share history
while viewing different windows. The base session starts `opencode -c`
(continue the last session), falling back to a bare `opencode` on the very
first launch.

```bash
opencode auth login       # add a provider credential — do this first
opencode auth list        # what is authenticated
/models                   # model picker, in the TUI
opencode agent create     # build a scoped sub-agent
opencode run "..."        # one-shot, non-interactive
```

---

## 🗑️ Removal

| Policy | What it does |
|:---|:---|
| **STOP** | Stop the container; everything persists |
| **TEARDOWN** | Remove the container; the volumes survive |
| **WIPE** | Remove the four volumes — state, config, home, SSH host keys |

**WIPE does not touch `OPENCODE_WORKSPACE_PATH`.** That is your repository on
the host, not this environment's data.

⚠️ The `state` volume holds `auth.json` — every credential saved by
`opencode auth login` — plus all session history. Wiping means logging in
again.

---

## 📚 See also

- `docs/future-enhancements/agent-control-environments.md` — why this
  environment exists, how it compares to the other coding CLIs, and the
  settled decisions behind these choices.
- `environments/pi/` — the minimal-harness counterpart, and the one that
  gets `mcporter`.
- `environments/herdr-client/` — one window over every agent environment.
  Its session generator will emit a pane for this container labelled
  `opencode:<your-repo>`.
- `environments/llm-gateways/` — the LiteLLM proxy the gateway section above
  points at.
