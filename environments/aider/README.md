# Aider — Provider-Agnostic Terminal Coding Agent

A standalone [Aider](https://aider.chat) container reachable directly over its own SSH server — same shape as this repo's own `claude-cli` environment (own sshd, persistent detachable tmux session, bind-mounted workspace), but provider-agnostic instead of Anthropic-only. Where `claude-cli` is Claude Code specifically, Aider can target Anthropic directly, this repo's own `llm-gateways` environment (Claude, DeepSeek, or a local Ollama model — switchable per session), or any other OpenAI-compatible endpoint, without changing which client you're running.

No custom `run.sh` — this is a plain `docker-compose.yml` with `build: .`, using `deploy.sh`'s generic fallback directly, same as `claude-cli` and `llm-gateways`.

---

## 📝 Why This Exists, and What It Deliberately Doesn't Rebuild

This environment started from a real question: *"if I wanted an experience similar to claude-cli with remote-control, but mediated through an LLM gateway so I could switch models — Claude, other vendors, even local Ollama — for a specific chat, what would that look like?"* The answer settled on **Aider as the terminal client, this repo's existing `llm-gateways` environment as the gateway** — not a new LiteLLM+Postgres stack of its own.

That matters because an earlier exploration of this idea (an AI-assisted brainstorming session, not verified documentation) proposed building a brand-new `docker-compose.yml` with its own LiteLLM proxy and Postgres container from scratch. This repo already has exactly that — `llm-gateways`, with LiteLLM (config-driven model routing, optional Postgres for virtual keys/spend tracking) already built, tested, and documented. Duplicating it here would mean two LiteLLM instances to keep in sync for no benefit, so this environment is deliberately just the client half: Aider itself, pointed at `llm-gateways` when you want gateway routing, or straight at a provider's own API when you don't.

**Two things from that brainstorming session were wrong and are corrected here, not carried forward:**

- **The model names it invented — `claude-sonnet-4-6`, `claude-legacy-46` — don't exist.** They don't match Anthropic's actual model lineup at all (confirmed against [Claude Code's own model configuration docs](https://code.claude.com/docs/en/model-config)). This README and `scripts/choose-model.sh` use real, verified model IDs only: `claude-sonnet-5`, `claude-opus-5`, `claude-haiku-4-5`, `claude-fable-5` (current), and `claude-sonnet-4-5` (an older but genuinely real model, still valid to pin explicitly).
- **The claim that "the official claude-cli (Claude Code) is hardcoded to force automated tool parameters and auto-upgrade to Sonnet 5"** doesn't match how Claude Code actually works — model selection is fully configurable there too (`--model`, `/model`, `ANTHROPIC_MODEL`, settings — see `claude-cli`'s own `CLAUDE_MODEL` support, added alongside this environment). Aider is still a genuinely good fit for provider-agnostic routing (Anthropic doesn't build Claude Code to talk to arbitrary third-party vendors or local Ollama models), just not because Claude Code is artificially restricted.

Also **not** carried forward from that brainstorming session, as out of scope for this round: pointing NanoClaw itself at a gateway (NanoClaw's own remote-control/tool-execution loop needs a native Anthropic-format backend and doesn't benefit from an OpenAI-translation layer — see that session's own conclusion, which agreed), and a bundled web frontend (Open WebUI) — `llm-gateways`' own README already points at this repo's separate `chat-frontends` environment for that, and Aider itself has zero use for a passive chat UI it can't execute shell commands through anyway.

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

Get a key from [console.anthropic.com/settings/keys](https://console.anthropic.com/settings/keys) — **this is billed API usage, a separate account/billing relationship from a Claude.ai subscription**, not the same key or login `claude-cli`'s `/login` uses. `AIDER_MODEL` accepts any real Claude model ID: `claude-sonnet-5`, `claude-opus-5`, `claude-haiku-4-5`, `claude-fable-5` (current), or an older pinned version like `claude-sonnet-4-5`.

### Mode B: Route Through `llm-gateways` (Claude, DeepSeek, Ollama — switchable)

Deploy this repo's own `llm-gateways` environment first if you haven't (its LiteLLM proxy is what actually reaches each provider). Then:

```bash
OPENAI_API_BASE=http://host.docker.internal:4000/v1
OPENAI_API_KEY=<llm-gateways' own LITELLM_MASTER_KEY>
AIDER_MODEL=openai/<model_name from llm-gateways' litellm-config.yaml>
```

- **`host.docker.internal`, not a container name or `localhost`** — `aider` and `llm-gateways` are separate Compose projects with no shared Docker network, so the only way this container reaches `llm-gateways`' published port is through the host itself. Same reasoning `claude-cli`'s own README gives for its gateway option.
- **The `openai/` prefix on `AIDER_MODEL` is required, not decorative.** Aider is built on the `litellm` Python library internally; setting `OPENAI_API_BASE` tells it an OpenAI-compatible endpoint exists, but it still needs the model string itself to say "treat this as an OpenAI-format request" — the prefix does that, and LiteLLM strips it back off before matching against its own `model_list`. Without it, Aider may try to route the request through a different provider's SDK entirely rather than hitting your gateway at all.
- **Which models are available**: whatever `llm-gateways`' own `litellm-config.yaml` registers under `model_list`. It ships with `ollama/*` (every model already pulled on your host's Ollama) enabled by default, and a commented-out Anthropic example (`anthropic/claude-sonnet-4-5`) — uncomment that (or add a `claude-sonnet-5`/`claude-opus-5` entry) and redeploy `llm-gateways` to make Claude available through this path too. See that environment's own README for the full config format.

Leave both `OPENAI_API_BASE`/`OPENAI_API_KEY` empty to skip the gateway and use `ANTHROPIC_API_KEY` directly (Mode A). Setting both modes at once is not a documented, tested configuration — pick one.

**Other providers directly** (DeepSeek, OpenAI itself, etc.), without going through `llm-gateways`: Aider's own `litellm` backend recognizes the standard per-provider env var for each (e.g. `DEEPSEEK_API_KEY`, a plain `OPENAI_API_KEY` with no `OPENAI_API_BASE` override) — add whichever one you need directly to `docker-compose.yml`'s `environment:` block (and `.env`) by hand; this environment only wires up the two modes above out of the box.

---

## 🧠 Choosing a Model

"Choose Model" in this environment's own `deploy.sh` action menu (`scripts/choose-model.sh`) writes `AIDER_MODEL` to `.env` and restarts the container (`FAST` — no rebuild needed). Its quick picks are direct-Anthropic Claude models only (Mode A above) — for a gateway-routed alias, DeepSeek, or a local Ollama model, use its "Custom" option and type the exact model string (see "Choosing a Provider" above for the `openai/` prefix requirement under Mode B).

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
