# Aider + LiteLLM Provider Stack — Full Setup Across 3 Environments

A single walkthrough for a setup that spans three separate `environments/` folders in this repo — `llm-gateways`, `aider`, and (optionally) `chat-frontends` — because none of them depend on each other at the code level (each can be deployed alone, and is documented alone), so there's no single environment's README that covers the whole picture end to end. This document is that missing piece: deploy in this order, and you end up with a terminal coding agent (Aider) that can swap between Claude, DeepSeek, and local Ollama models per session, with two optional browser-based ways to reach it, and an optional browser chat window onto the same models.

**Not itself a fourth environment, and not a substitute for each one's own README** — this is a map connecting three real, independent `deploy.sh` entries; the authoritative details for any one step still live in that environment's own docs, linked at each step.

## Origin and Corrections

This stack traces back to a real question about replicating a `claude-cli`-like remote-control experience but mediated through a swappable model gateway. An AI-assisted brainstorming session explored the idea first and got most of the architecture right (Aider as the terminal client, LiteLLM as the router, is exactly what got built) but contained real, since-corrected inaccuracies worth knowing before you read anything else about this stack:

- **It proposed rebuilding LiteLLM+Postgres from scratch.** This repo already had that — `llm-gateways` — so nothing new was built there; `aider` is the client half only.
- **It claimed `claude-sonnet-4-6` was an invented model name.** That was *this session's own mistake*, caught and corrected: `claude-sonnet-4-6` and `claude-opus-4-6` are real, current model IDs (verified against [Claude Code's own model configuration docs](https://code.claude.com/docs/en/model-config)) — what the `sonnet`/`opus` aliases resolve to on Claude Platform on AWS and Microsoft Foundry respectively. Only the session's own vanity LiteLLM alias name for it (`claude-legacy-46`) was arbitrary, which is normal, expected LiteLLM usage.
- **It claimed Claude Code is "hardcoded" to force Sonnet 5 with no way to change models.** Not true — see `claude-cli`'s own `CLAUDE_MODEL` support. Aider is still a good fit for provider-agnostic routing, just not because Claude Code is artificially restricted.
- **Open WebUI can't drive Aider's edit loop**, even routed through the same gateway — it's a passive chat UI with no shell/file access. Don't expect step 4 below to give you "Aider in a browser, driven by chat" — for that, see step 3's Frontend Options B/A instead.

## The Three Environments, What Each One Owns

| Environment | Owns | You need it because |
|---|---|---|
| `llm-gateways` | LiteLLM proxy (model routing), optional Postgres | The actual place model requests get routed to Claude/DeepSeek/Ollama — both `aider` and `chat-frontends` are just clients of this |
| `aider` | The Aider terminal client (SSH+tmux), plus two opt-in frontends (browser GUI, OpenVSCode Server) | Where you actually do coding work |
| `chat-frontends` | Open WebUI (and other chat UIs) | Optional — casual browser chat against the same models, no coding/execution capability |

---

## Step 1: Deploy `llm-gateways`, Enable Claude Models

```bash
cd environments/llm-gateways
cp .env.example .env
# Set a real LITELLM_MASTER_KEY (openssl rand -base64 32) and ANTHROPIC_API_KEY
# (a real Anthropic Console key — console.anthropic.com/settings/keys)
```

Or use `deploy.sh`'s menu (**LLM Gateways**, under **AI Assistants**). Claude models are enabled by default in `litellm-config.yaml` (`claude-sonnet-5`/`opus-5`/`haiku-4-5`/`fable-5`, plus `claude-sonnet-4-6`/`opus-4-6`/`sonnet-4-5`) — they just need `ANTHROPIC_API_KEY` set to actually work. See that environment's own README for DeepSeek/other providers, and for Ollama (enabled out of the box, no key needed, assuming Ollama's already running on the host).

Deploy it (`docker compose up -d`, or `FAST` from `deploy.sh`), then confirm it works:

```bash
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer <your LITELLM_MASTER_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model": "claude-sonnet-5", "messages": [{"role": "user", "content": "Hello"}]}'
```

A real response back means `llm-gateways` is ready. Keep `LITELLM_MASTER_KEY` handy — every downstream step needs it.

**Skip this step entirely** if you only want Aider talking to Anthropic directly (no model-switching) — go straight to Step 2, Mode A.

---

## Step 2: Deploy `aider`

```bash
cd environments/aider
cp .env.example .env
```

Pick one provider mode in `.env` (see that environment's own README's "Choosing a Provider" for the full explanation):

**Mode A — direct Anthropic, no gateway:**
```bash
ANTHROPIC_API_KEY=sk-ant-...
AIDER_MODEL=claude-sonnet-5
```

**Mode B — routed through `llm-gateways` (needs Step 1 done first):**
```bash
OPENAI_API_BASE=http://host.docker.internal:4000/v1
OPENAI_API_KEY=<llm-gateways' own LITELLM_MASTER_KEY>
AIDER_MODEL=openai/claude-sonnet-5
```

`host.docker.internal`, not a container name or `localhost` — `aider` and `llm-gateways` are separate Compose projects with no shared Docker network, so this has to route through the host itself. `AIDER_MODEL`'s `openai/` prefix is required in Mode B (see the README for why — it forces Aider's own litellm backend to treat this as an OpenAI-compatible request rather than trying a different provider's SDK).

Set `AIDER_WORKSPACE_PATH` to the repo you want Aider working in, and `SSH_AUTHORIZED_KEYS_PATH` (defaults to your own host's `~/.ssh/authorized_keys`). Deploy:

```bash
docker compose up -d
ssh -p ${SSH_PORT:-2223} aider@<host>
```

That's the default, always-on frontend: SSH in, land in a persistent tmux session running `aider`. Two more ways to reach it — both opt-in, see the environment's own README's "Frontend Options" section for the full detail:

- **Browser GUI** (same container, `EXPERIMENTAL`): "Launch Aider (Browser GUI)" in `deploy.sh`'s menu, then browse to `http://<host>:${AIDER_GUI_PORT:-8501}`.
- **OpenVSCode Server** (separate container, full IDE, Aider pre-installed): set `COMPOSE_PROFILES=ide` in `.env`, redeploy, browse to `http://<host>:${AIDER_IDE_PORT:-8443}`.

---

## Step 3 (Optional): Deploy `chat-frontends` for Casual Browser Chat

Only worth doing if you want a browser chat window against the same models — not required for Aider itself to work.

```bash
cd environments/chat-frontends
cp .env.example .env
```

Add to `.env` (alongside its existing `OLLAMA_BASE_URL`, which you can leave as-is):

```bash
OPENAI_API_BASE_URL=http://host.docker.internal:4000/v1
OPENAI_API_KEY=<llm-gateways' own LITELLM_MASTER_KEY>
```

Deploy (`docker compose up -d`, or `FAST` from `deploy.sh`), browse to `http://<host>:${OPEN_WEBUI_PORT:-3010}`. The model dropdown now shows both your Ollama models and whatever `llm-gateways` registers (Claude, DeepSeek, etc.), merged into one list.

Remember: this is chat only. It cannot see or edit files, run commands, or drive Aider's own agent loop — for that, use `aider` directly (Step 2) or one of its own frontends.

---

## End-to-End Checklist

- [ ] `llm-gateways` deployed, `ANTHROPIC_API_KEY` set, `curl` test against port 4000 returns a real response
- [ ] `aider` deployed, provider mode chosen (A or B) and confirmed working (`ssh` in, send Aider a message, get a real response)
- [ ] (Optional) `AIDER_MODEL` set via "Choose Model" to whichever model you actually want by default
- [ ] (Optional) Browser GUI or OpenVSCode Server enabled, reachable in a browser
- [ ] (Optional) `chat-frontends` deployed and pointed at `llm-gateways`, model dropdown shows Claude/DeepSeek alongside Ollama

## Known Gaps

Nothing in this stack has been exercised against a real, live deploy end-to-end yet — see each environment's own `docs/future-enhancements/` entry (`aider.md`, and the relevant sections of `llm-gateways`' and `chat-frontends`' own docs where applicable) for the specific unverified assumptions. Written and syntax/config-checked only.
