# Aider — Provider-Agnostic Terminal Coding Agent

A standalone [Aider](https://aider.chat) container reachable directly over its own SSH server — same shape as this repo's own `claude-cli` environment (own sshd, persistent detachable tmux session, bind-mounted workspace), but provider-agnostic instead of Anthropic-only. Where `claude-cli` is Claude Code specifically, Aider can target Anthropic directly, this repo's own `llm-gateways` environment (Claude, DeepSeek, or a local Ollama model — switchable per session), or any other OpenAI-compatible endpoint, without changing which client you're running.

No custom `run.sh` — this is a plain `docker-compose.yml` with `build: .`, using `deploy.sh`'s generic fallback directly, same as `claude-cli` and `llm-gateways`.

**New to this stack? See [`docs/aider-provider-stack.md`](../../docs/aider-provider-stack.md) first** — a single walkthrough covering this environment plus `llm-gateways` and (optionally) `chat-frontends` together, in deploy order. Everything below is this environment's own detailed reference.

---

## 📝 Why This Exists, and What It Deliberately Doesn't Rebuild

This environment started from a real question: *"if I wanted an experience similar to claude-cli with remote-control, but mediated through an LLM gateway so I could switch models — Claude, other vendors, even local Ollama — for a specific chat, what would that look like?"* The answer settled on **Aider as the terminal client, this repo's existing `llm-gateways` environment as the gateway** — not a new LiteLLM+Postgres stack of its own.

That matters because an earlier exploration of this idea (an AI-assisted brainstorming session, not verified documentation) proposed building a brand-new `docker-compose.yml` with its own LiteLLM proxy and Postgres container from scratch. This repo already has exactly that — `llm-gateways`, with LiteLLM (config-driven model routing, optional Postgres for virtual keys/spend tracking) already built, tested, and documented. Duplicating it here would mean two LiteLLM instances to keep in sync for no benefit, so this environment is deliberately just the client half: Aider itself, pointed at `llm-gateways` when you want gateway routing, or straight at a provider's own API when you don't.

**One thing from that brainstorming session was wrong and is corrected here, not carried forward:**

- **The claim that "the official claude-cli (Claude Code) is hardcoded to force automated tool parameters and auto-upgrade to Sonnet 5"** doesn't match how Claude Code actually works — model selection is fully configurable there too (`--model`, `/model`, `ANTHROPIC_MODEL`, settings — see `claude-cli`'s own `CLAUDE_MODEL` support, added alongside this environment). Aider is still a genuinely good fit for provider-agnostic routing (Anthropic doesn't build Claude Code to talk to arbitrary third-party vendors or local Ollama models), just not because Claude Code is artificially restricted.

(An earlier version of this note also claimed the session's model names — `claude-sonnet-4-6` specifically — were invented. That was itself a mistake, caught and corrected: `claude-sonnet-4-6` and `claude-opus-4-6` are real, current model IDs — see [Claude Code's own model configuration docs](https://code.claude.com/docs/en/model-config), which list them as what the `sonnet`/`opus` aliases currently resolve to on Claude Platform on AWS and Microsoft Foundry respectively, and both are directly nameable on the Anthropic API too. Only the session's own LiteLLM alias name for it, `claude-legacy-46`, was arbitrary — that's just a user-chosen `model_name` label in LiteLLM, not a real Anthropic model ID, and picking your own label there is completely normal LiteLLM usage. `scripts/choose-model.sh` and `llm-gateways`' own `litellm-config.yaml` now include `claude-sonnet-4-6`/`claude-opus-4-6`/`claude-sonnet-4-5` alongside the current `-5` lineup.)

Also **not** carried forward from that brainstorming session: pointing NanoClaw itself at a gateway (NanoClaw's own remote-control/tool-execution loop needs a native Anthropic-format backend and doesn't benefit from an OpenAI-translation layer — see that session's own conclusion, which agreed). The brainstorming session's three Aider frontend options (its own browser GUI, OpenVSCode Server, Open WebUI) *are* built — see "Frontend Options" below — except Open WebUI specifically stays in the separate `chat-frontends` environment rather than getting duplicated here, since Aider itself has zero use for a passive chat UI it can't execute shell commands through anyway.

---

## 🔑 Before Your First Deploy: You Need a Real API Key

Unlike `claude-cli`, there's no browser `/login` OAuth flow here — **Aider is not Claude Code**, and needs an actual, billed API key from whichever provider you point it at. See "Choosing a Provider" below before deploying.

---

## 🧭 How Login Works

SSH in and you land straight into a **persistent, detachable `tmux` session** running `aider` in your workspace — not a fresh shell each time:

```bash
ssh -p ${SSH_PORT:-2223} aider@<host>
```

Identical grouped-session mechanism to `claude-cli`'s own login shell (see that environment's README's "How Login Works" for the full explanation): each SSH connection creates its own tmux session grouped onto a shared `aider` base session — same window list/history, independent current-window pointer per connection, so multiple simultaneous logins don't force each other to watch the same window. The very first connection ever (or the first since a restart) creates the base session; `destroy-unattached on` cleans up each connection's own grouped session the moment it detaches.

`ssh host some-command` (non-interactive) skips this entirely, same as `claude-cli`.

### Getting a Plain Shell Instead of the `aider` Conversation

Same three options as `claude-cli` (see that README for the full writeup) — the short version: **`Ctrl-b c`** for a new tmux window with a normal shell (recommended), a second non-interactive SSH connection (`ssh -p ${SSH_PORT:-2223} aider@<host> '<command>'`), or `docker exec -it -u aider ${CONTAINER_NAME:-aider} bash` from the Docker host directly.

---

## 🔀 Choosing a Provider

Set exactly one of these two modes in `.env` (see `.env.example` for the full field-by-field comments):

### Mode A: Direct Anthropic API

```bash
ANTHROPIC_API_KEY=sk-ant-...
AIDER_MODEL=claude-sonnet-5
```

Get a key from [console.anthropic.com/settings/keys](https://console.anthropic.com/settings/keys) — **this is billed API usage, a separate account/billing relationship from a Claude.ai subscription**, not the same key or login `claude-cli`'s `/login` uses. `AIDER_MODEL` accepts any real Claude model ID: `claude-sonnet-5`, `claude-opus-5`, `claude-haiku-4-5`, `claude-fable-5` (current, on the Anthropic API), or a still-current pinned version like `claude-sonnet-4-6`, `claude-opus-4-6`, or `claude-sonnet-4-5` (what `sonnet`/`opus` currently resolve to on other providers — see `scripts/choose-model.sh` for all seven as quick picks).

### Mode B: Route Through `llm-gateways` (Claude, DeepSeek, Ollama — switchable)

Deploy this repo's own `llm-gateways` environment first if you haven't (its LiteLLM proxy is what actually reaches each provider). Then:

```bash
OPENAI_API_BASE=http://host.docker.internal:4000/v1
OPENAI_API_KEY=<llm-gateways' own LITELLM_MASTER_KEY>
AIDER_MODEL=openai/<model_name from llm-gateways' litellm-config.yaml>
```

- **`host.docker.internal`, not a container name or `localhost`** — `aider` and `llm-gateways` are separate Compose projects with no shared Docker network, so the only way this container reaches `llm-gateways`' published port is through the host itself. Same reasoning `claude-cli`'s own README gives for its gateway option.
- **The `openai/` prefix on `AIDER_MODEL` is required, not decorative.** Aider is built on the `litellm` Python library internally; setting `OPENAI_API_BASE` tells it an OpenAI-compatible endpoint exists, but it still needs the model string itself to say "treat this as an OpenAI-format request" — the prefix does that, and LiteLLM strips it back off before matching against its own `model_list`. Without it, Aider may try to route the request through a different provider's SDK entirely rather than hitting your gateway at all.
- **Which models are available**: whatever `llm-gateways`' own `litellm-config.yaml` registers under `model_list`. It ships with `ollama/*` (every model already pulled on your host's Ollama) plus seven Claude entries enabled by default (`claude-sonnet-5`/`opus-5`/`haiku-4-5`/`fable-5` and `claude-sonnet-4-6`/`opus-4-6`/`sonnet-4-5`) — set `ANTHROPIC_API_KEY` in `llm-gateways`' own `.env` for those to work. See that environment's own README for the full config format.

Leave both `OPENAI_API_BASE`/`OPENAI_API_KEY` empty to skip the gateway and use `ANTHROPIC_API_KEY` directly (Mode A). Setting both modes at once is not a documented, tested configuration — pick one.

**Other providers directly** (DeepSeek, OpenAI itself, etc.), without going through `llm-gateways`: Aider's own `litellm` backend recognizes the standard per-provider env var for each (e.g. `DEEPSEEK_API_KEY`, a plain `OPENAI_API_KEY` with no `OPENAI_API_BASE` override) — add whichever one you need directly to `docker-compose.yml`'s `environment:` block (and `.env`) by hand; this environment only wires up the two modes above out of the box.

---

## 🧠 Choosing a Model

"Choose Model" in this environment's own `deploy.sh` action menu (`scripts/choose-model.sh`) writes `AIDER_MODEL` to `.env` and restarts the container (`FAST` — no rebuild needed). Its quick picks are direct-Anthropic Claude models only (Mode A above) — for a gateway-routed alias, DeepSeek, or a local Ollama model, use its "Custom" option and type the exact model string (see "Choosing a Provider" above for the `openai/` prefix requirement under Mode B).

---

## 🖥️ Frontend Options

The SSH/tmux terminal above is the default, always-on way to run `aider` here. Two more ways to reach the same workspace and provider config exist, both opt-in; a third some setups add (Open WebUI) is deliberately not built here at all.

### Option A: Aider's Own Built-In Browser GUI — `EXPERIMENTAL`

Same container as the SSH/tmux service, not a separate one — this is the same `aider` process launched with a different flag (`--gui`), not different software. Launch it via **"Launch Aider (Browser GUI, EXPERIMENTAL)"** in `deploy.sh`'s menu (`scripts/aider-gui.sh`), then browse to `http://<host>:${AIDER_GUI_PORT:-8501}`. It runs in its own detached tmux session (`aider-gui`, separate from the SSH login session's own `aider` session), so it keeps running in the background — you don't need to keep the launching connection open.

**Flagged experimental deliberately, not just as a formality**: Aider's own documentation ([aider.chat/docs/usage/browser.html](https://aider.chat/docs/usage/browser.html)) calls this an experimental feature, and this wiring hasn't been independently confirmed against a live deploy in this repo (see `docs/future-enhancements/aider.md`). If it doesn't work, `docker logs ${CONTAINER_NAME:-aider}` and Aider's own GitHub issues are the first places to check — that's Aider's own feature behaving unexpectedly, not necessarily a bug in how this environment invokes it.

Stop it: `docker exec ${CONTAINER_NAME:-aider} tmux kill-session -t aider-gui`.

### Option B: OpenVSCode Server — a Full Browser-Based IDE

A genuinely separate container ([`lscr.io/linuxserver/openvscode-server`](https://github.com/linuxserver/docker-openvscode-server), `Dockerfile.ide`), with `aider` pre-installed so its integrated terminal can run it immediately — unlike Option A, this is different software, not just a different flag, so it gets its own image rather than reusing the SSH service's. Shares the same `AIDER_WORKSPACE_PATH` bind mount, and the same provider env vars (`ANTHROPIC_API_KEY`/`OPENAI_API_KEY`/`OPENAI_API_BASE`), so `aider` run from its terminal works with no separate setup.

Opt-in via `COMPOSE_PROFILES` (see `.env.example`) — off by default so a plain `docker compose up -d` doesn't pull/build a second, heavier image nobody asked for:

```bash
# in .env:
COMPOSE_PROFILES=ide
# then:
docker compose up -d
```

Browse to `http://<host>:${AIDER_IDE_PORT:-8443}` once it's up, open the integrated terminal, and run `aider` directly.

### Option C: Open WebUI — Deliberately Not Built Here

This repo already has Open WebUI, in the separate `chat-frontends` environment — building a second one here would duplicate it for no benefit, the same reasoning that kept this environment from rebuilding `llm-gateways`' own LiteLLM+Postgres stack (see "Why This Exists" above). `chat-frontends`' own README now has a "Connecting Open WebUI to `llm-gateways`" section covering exactly this.

**Worth being precise about what that actually gets you**: pointing Open WebUI at `llm-gateways` gives you a browser chat window against the *same models* Aider can use, through the *same gateway* — genuinely useful for quick questions or brainstorming without opening a terminal. It does **not** let Open WebUI drive Aider's own file-editing session. Open WebUI is a passive chat interface with no shell or file-system access of its own; it can't intercept and execute the edit commands Aider's own agent loop produces, even when both are pointed at the identical model. If you want a *browser-based way to run Aider itself* — not just chat with the same model Aider happens to use — that's what Options A and B above are for. A real "Aider Pipeline" plugin that lets Open WebUI drive Aider directly may exist in the wider ecosystem, but nothing confirming one actually works was verified before writing this — not built here on that basis.

---

## 🎛️ Deployment Policies

Same generic-Compose policy set as `claude-cli`/`llm-gateways` — select from `deploy.sh`'s menu:

| Policy | Action |
|--------|--------|
| `FAST` | Start the container if stopped; reconcile against `docker-compose.yml`/`.env` otherwise (no rebuild) |
| `STOP` | Stop the container |
| `TEARDOWN` | Stop + remove the container; SSH host key volume untouched |
| `CLEAN` | Rebuild the image, then swap in the fresh container |
| `INFO` | List data directories with sizes and useful commands |
| `WIPE` | Delete the SSH host key volume (irreversible — next connection needs re-trusting the new fingerprint) |

---

## 💾 Data Directories

| Location | Contents |
|----------|---------|
| `${CONTAINER_NAME:-aider}_ssh_host_keys` (named volume) | This container's own SSH host keys |
| `AIDER_WORKSPACE_PATH` (host bind mount) | Your own pre-existing git repo/directory — not owned by this environment, `WIPE`/`TEARDOWN` never touch it |

Aider itself keeps no separate persistent state beyond your workspace's own `.git` history — no OAuth session, no separate database, unlike `claude-cli`'s `claude_cli_home`/`claude_cli_json` volumes.

---

## 🖥️ Desktop Integration

```bash
./install-desktop-entries.sh
# or just this environment on its own:
./environments/aider/install-desktop.sh
```

Installs an **Aider** entry that SSHes in and attaches to the live tmux session, same as `claude-cli`'s own desktop entry.

---

## 💡 Useful Commands

```bash
ssh -p ${SSH_PORT:-2223} aider@localhost                          # attach to the live tmux "aider" session
docker exec -it ${CONTAINER_NAME:-aider} tmux attach -t aider     # same thing, from the host directly (no SSH key needed)
docker logs -f ${CONTAINER_NAME:-aider}                           # sshd logs
```

---

## 🔒 Security Notes

- **`SSH_PORT` is a real network-facing port** — same caution as `claude-cli`'s own README: don't forward it through your router unless you specifically mean to expose it, and keep `SSH_AUTHORIZED_KEYS_PATH` scoped to keys you actually trust.
- **Aider auto-commits by default.** Unlike `claude-cli`, where committing is something you ask Claude for explicitly, Aider commits its own changes to your workspace's git history automatically after each edit (its own `--auto-commits` default) — make sure `GIT_USER_NAME`/`GIT_USER_EMAIL` are set, and that `AIDER_WORKSPACE_PATH` is a repo you're comfortable with an agent committing to unsupervised. Aider does still prompt before running arbitrary shell commands.
- **`OPENAI_API_KEY`/`ANTHROPIC_API_KEY` are real, billed credentials, not placeholders to skip.** Treat `.env` here the same as any other secrets file in this repo — never commit it.
