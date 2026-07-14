# NanoClaw + Mnemon — Persistent Memory AI Assistant

The same self-hosted [NanoClaw](https://github.com/nanocoai/nanoclaw) AI assistant as the plain `nanoclaw` environment, with [mnemon](https://github.com/mnemon-dev/mnemon) — a real, independent, third-party persistent-memory tool — patched into NanoClaw's own per-conversation-group agent sandbox for cross-session graph memory. Three extras layer on top of that core: mnemon's own built-in optional Ollama embeddings for hybrid graph+vector recall (opt-in via `.env`, off by default), a scaffolding script for NanoClaw's own Karpathy-pattern wiki skill (`scaffold-wiki.sh`, run manually per group), and a bundled [Open WebUI](https://github.com/open-webui/open-webui) chat frontend for that same Ollama daemon (on by default — see "🌐 Bundled Open WebUI" below).

**Fully independent of the plain `nanoclaw` environment**: its own install path, its own container name, its own port. Both can be deployed on the same machine without colliding. The plain `nanoclaw` environment is intentionally left untouched by this one — see "Coexistence" below.

**Credit**: this environment follows the architecture described in a public gist by GitHub user [VivianBalakrishnan](https://gist.github.com/VivianBalakrishnan/a7d4eec3833baee4971a0ee54b08f322), which describes NanoClaw combined with mnemon, local embeddings, a wiki layer, and a personal Obsidian sync into a "second brain." **Worth reading with some skepticism**: the gist claims wiki pages are synthesized *from* mnemon's extracted facts (raw sources → mnemon → wiki), but that specific pipeline has no corroborating implementation anywhere — not in the gist author's own public GitHub work (their only repo is an untouched, zero-commits-ahead fork of mnemon), and not in any of the five independently-built "Karpathy pattern" wiki tools surveyed in `GIST-PARITY.md`, all of which compile wikis directly from raw sources with no memory-tool intermediary. This environment implements each piece the gist names against real upstream sources — NanoClaw's own [`.claude/skills/add-mnemon/SKILL.md`](https://github.com/nanocoai/nanoclaw/blob/main/.claude/skills/add-mnemon/SKILL.md), mnemon's own genuinely-real optional embeddings feature (`MNEMON_EMBED_ENDPOINT`/`MNEMON_EMBED_MODEL`, opt-in via `.env`, defaulting to `nomic-embed-text`), and [`/add-karpathy-llm-wiki`](https://github.com/nanocoai/nanoclaw/blob/main/.claude/skills/add-karpathy-llm-wiki/SKILL.md) for the wiki layer — but mnemon and the wiki run as independent systems here, which the evidence above suggests is the architecture matching real-world practice, not a shortfall relative to the gist's specific claim. **See [`GIST-PARITY.md`](./GIST-PARITY.md) for the full analysis** — what's built and verified, what's still missing, and the credibility caveat in full. **See [`MANUAL-STEPS.md`](./MANUAL-STEPS.md)** if you'd rather not use this environment's automation — it's the exact same result (starting from a plain `nanoclaw` deploy), spelled out by hand.

---

## How It Works

Identical to the plain `nanoclaw` environment's architecture — a host-level orchestrator (containerized here) spawns an isolated Docker container per conversation group. The only difference: each group's agent container also runs `mnemon`, a single Go binary providing persistent, cross-session graph memory (temporal/entity/causal/semantic graphs), supervised by the agent's own Claude Code session rather than embedding its own LLM.

```
Messaging apps → orchestrator (router) → agent container (Claude Agent SDK + mnemon) → orchestrator (delivery) → messaging apps
```

Mnemon's `remember`/`link`/`recall` primitives are invoked automatically via Claude Code hooks (`SessionStart`, `UserPromptSubmit`, `Stop`) that `mnemon setup` registers inside each agent container — the agent doesn't need to be told to use it.

---

## 🧩 What Runs Where

A quick reference for "which of these lives on my Mac, and which is inside a container":

| Component | Where it actually runs | Notes |
|---|---|---|
| **NanoClaw orchestrator** (router, channel listeners, container-runner) | Docker container (`nanoclaw-mnemon`, this environment's own top-level container) | The one thing `docker ps` shows you directly; everything else it spawns is one level down |
| **Claude CLI / Claude Agent SDK** | Three separate places, not one: (1) natively on your Mac, if you've installed it there yourself — entirely independent of this environment; (2) pre-installed inside the orchestrator container, used for `docker exec -it nanoclaw-mnemon ... claude` (see "Launching Claude CLI Directly" below); (3) inside every dynamically-spawned per-group **agent** container, running the actual conversation | These are independent installations — signing in on your Mac doesn't sign in the orchestrator's copy, and vice versa. Each agent container gets its own OAuth session via OneCLI (see "Security Notes") |
| **Ollama** | Native host process — **not** containerized, deliberately (see "Mnemon Integration" above) | Reached from inside containers via `host.docker.internal:11434` |
| **mnemon** | Compiled into and running inside every per-group **agent** container (never the orchestrator itself) | One mnemon process per active conversation group, each scoped to that group's own memory graph |

### What Are the Spawned Agent Containers Actually Doing?

The orchestrator itself never has a conversation — it's a router. The moment a message arrives for a conversation group with no live agent container yet, its `container-runner.ts` builds/starts one (image `nanoclaw-agent:latest`, name pattern `nanoclaw-agent-v2-*`), bind-mounted to that group's own folder under `groups/<group>/`. Inside, a real Claude Agent SDK session (this environment's patched image also carries mnemon and its Claude Code hooks) reads the incoming message, does whatever the conversation calls for, calls mnemon's `remember`/`recall`/`link` along the way, and replies — the orchestrator then delivers that reply back out over the original channel. Idle agent containers are eventually stopped/reaped by NanoClaw itself; the next message to that group just spins one back up. Each group gets its own container, so groups can't see each other's memory, files, or history.

### Why Can Claude Open a Browser on My Mac, But Not Inside Docker?

Claude CLI running natively on your Mac can shell out to open a URL because it's a normal process with access to your Mac's own GUI session — an actual Desktop, an actual Safari, an actual window server, all directly reachable. The orchestrator and every agent container are headless Linux containers: no GUI session exists inside them at all, by design, and even if a browser binary were installed in one, there's no display for it to draw to — the container sits on the other side of a VM boundary (Docker Desktop/OrbStack's own Linux VM) from your Mac's screen. That's why the OAuth sign-in step (see "First-Time Setup" below) prints a URL and asks you to copy-paste it into your own browser instead of trying to open one itself — there's genuinely nowhere for a container-side browser to display to, not a missing feature. See "SSH'ing in from Another macOS Machine" below for what this means if you're also remote.

---

## 🔒 Deployment Modes

**Container mode only.** Unlike the plain `nanoclaw` environment, there's no host/systemd/launchd mode here — this environment exists specifically for the Mac-first, filesystem-sandboxed use case, so there's no second mode to keep in sync with the mnemon patch. See the plain `nanoclaw` environment's README for the full host-vs-container tradeoff (iMessage support, filesystem access scope) if you want that instead.

---

## ⚙️ Why This Needs a Custom `run.sh`

Same reasons as the plain `nanoclaw` environment (`deploy.sh`'s generic fallback has no concept of Docker-outside-of-Docker, interactive setup wizards, or dynamically-spawned per-group containers — see that environment's README for the full breakdown), plus one more specific to this environment:

- **Idempotent source patching** — `run.sh` patches `mnemon` into NanoClaw's own `container/Dockerfile` and `container/entrypoint.sh` on every deploy, checking first whether it's already applied (matching the upstream skill's own idempotency contract exactly). No generic archetype has any notion of "patch a freshly-cloned third-party repo's own build files before building them."

---

## 🧠 Mnemon Integration

`run.sh`'s `apply_mnemon_patch()` function does exactly what NanoClaw's own `/add-mnemon` Claude Code skill documents, applied automatically instead of interactively:

1. Inserts a block into `container/Dockerfile` (immediately above the `# ---- Bun runtime` section) that downloads the pinned `mnemon` release binary and installs it into the agent-sandbox image.
2. Adds `mnemon setup --target claude-code --yes --global` to `container/entrypoint.sh`, run on every agent container start.

Both steps are applied **before** NanoClaw's own setup wizard builds the agent image for the first time, so the very first build already includes mnemon — no separate rebuild step needed, unlike applying this skill to an already-running install.

**Version pinning**: `MNEMON_VERSION` in `.env` (default `0.1.1`) controls exactly which mnemon release gets installed. A `CLEAN` redeploy re-clones NanoClaw from scratch and reapplies the patch with whatever `MNEMON_VERSION` is currently set — bump it deliberately, it won't drift on its own.

**Memory storage**: mnemon writes to `/home/node/.claude/mnemon/` inside each agent container, which maps onto that conversation group's own `.claude/` directory under `$NANOCLAW_INSTALL_PATH/groups/<group>/` — memory is per-group by default (mnemon also supports an optional shared/global read-only store; this environment doesn't configure that, it's mnemon's own default per-agent behavior).

**Optional hybrid graph+vector recall**: mnemon has this built in (`MNEMON_EMBED_ENDPOINT`/`MNEMON_EMBED_MODEL`, defaulting to `nomic-embed-text`) — set `MNEMON_EMBED_ENDPOINT` in `.env` (see `.env.example`'s own comment, commented out by default) to bake it into the Dockerfile as a plain `ENV` line. Left unset, mnemon runs graph-only — its own documented default, not a degraded mode. Requires `CLEAN` to take effect on an already-deployed install, same as bumping `MNEMON_VERSION`. The patch also bakes in `NO_PROXY`/`no_proxy` for that endpoint's host, so OneCLI's own unconditional `HTTPS_PROXY` injection (see "Security Notes" below) doesn't end up intercepting mnemon's embeddings traffic if you point it at an HTTPS endpoint.

When set, `run.sh`'s `ensure_ollama_ready()` checks whether that endpoint is reachable before proceeding, and — only for a local address (`host.docker.internal`/`localhost`/`127.0.0.1`) — offers to install Ollama itself (Homebrew on macOS, the official installer on Linux, gated behind an explicit y/N prompt), starts it if it's installed but not running, and pulls the model if it's missing. A remote `MNEMON_EMBED_ENDPOINT` is left alone entirely — that's your own infrastructure, not something this script manages. Every failure here is a warning, not a hard stop: the rest of the deploy proceeds regardless, with mnemon simply running graph-only until you resolve it.

**This already runs on every deploy, not just the first one** — `ensure_ollama_ready()` is called unconditionally from `run.sh` regardless of policy (`FAST` or `CLEAN`), so if Ollama shows up on the host *after* the fact — e.g. you declined the y/N install prompt above the first time and installed it yourself later — the very next `./run.sh` picks it up and pulls `nomic-embed-text` automatically. There's no separate "go set up Ollama's model" step to run by hand, and no need to force a `CLEAN` just to retrigger this check.

**Provider compatibility**: mnemon's Claude Code hooks only fire for groups running the default Claude provider. If you've configured a group with `"provider": "opencode"` or similar in its `container.json`, mnemon's hooks won't run for that group — check with `grep -H '"provider"' groups/*/container.json` inside the install path.

---

## 🕐 Container Timezone

A plain Docker container has no timezone of its own and defaults to UTC — `run.sh` fixes this by reading the host's own timezone (`readlink /etc/localtime`, which resolves to an IANA zone like `America/Los_Angeles` on both macOS and Linux) and passing it into the orchestrator container as both a `TZ` environment variable and a read-only `/etc/localtime` bind mount.

This one fix covers the whole system, not just the orchestrator: NanoClaw's own `src/config.ts` already resolves a `TIMEZONE` constant from `process.env.TZ` (falling back to its own `.env`'s `TZ`, then `Intl`'s guess, then `UTC`), and its `container-runner.ts` already passes `-e TZ=${TIMEZONE}` to every spawned per-group agent container. That logic was already correct upstream — it just had nothing but UTC to work with before, since the orchestrator container itself had no timezone set. Giving the orchestrator a real one is enough for every agent container it spawns to inherit it too.

**Only takes effect on container creation**, not a running container — a plain `FAST` redeploy of an already-running orchestrator won't pick this up. Recreate it once (`REBUILD_POLICY=TEARDOWN ./run.sh && REBUILD_POLICY=FAST ./run.sh`, or `CLEAN`) to apply it to an existing install.

---

## 🧭 First-Time Setup: What to Expect

The wizard is interactive and pauses for your input several times. None of what follows is a bug — every invisible-prompt issue below has since been fixed in `run.sh` itself — this is the real, sequential walkthrough of a fresh `CLEAN` deploy, including the parts most likely to trip you up the first time, straight from an actual deploy.

**1. "You are running as root" warning.** NanoClaw's own wizard opens with this. Answer **`2` (continue as root)** — this container has no `USER` directive by design, so it's expected and safe here; the Docker socket it needs is already root-equivalent regardless of which user runs inside the container. See "Security Notes" below for the full reasoning.

**2. Claude CLI sign-in (OAuth).** The Claude CLI is pre-installed in the image now, so this step should just show "already-installed" and move straight to sign-in. It tries to open a browser automatically — that fails silently inside this headless container, so it prints a URL instead, with a `c` shortcut to copy it. Two gotchas worth knowing before you hit them:

- **Don't copy the URL by selecting the wrapped terminal text.** A long URL gets soft-wrapped across several lines by your terminal; copying the *displayed* wrapped text (rather than the real single line) inserts a literal space or newline right in the middle of the `client_id` value, breaking the OAuth request (`OAuth Request Failed: client_id: Input should be a valid UUID...`). Widen your terminal window so the URL prints on one unwrapped line before copying it, or use the `c` shortcut instead.
- **`c` to copy may put nothing on your clipboard.** It works via OSC 52, a terminal escape sequence that lets a process running in a container/remote shell write to your *local* clipboard without needing `pbcopy` inside the container. Not every terminal honors this by default — Terminal.app has historically had weak support; iTerm2 needs Preferences → General → Selection → "Applications in terminal may access clipboard" enabled; tmux needs `set -g set-clipboard on`. If `c` silently does nothing, fall back to widening the terminal and selecting the single unwrapped line by hand.

Paste the (correctly copied) URL into a real browser, sign in, and paste the resulting code back into the wizard.

**3. Ollama install prompt — only if `MNEMON_EMBED_ENDPOINT` is set.** You'll see `⚠️ Ollama isn't installed on this host.` followed by a `[y/N]` question asking whether to install it via Homebrew (macOS) or the official installer (Linux). Answer **`y`** to have it installed automatically now; anything else skips it, and mnemon simply runs graph-only until you install Ollama yourself later — never a hard stop either way.

**4. Chat works — everything after this is optional.** Once the wizard finishes and you've paired a first channel (e.g. Telegram), required setup is done. From here: enable/verify Ollama embeddings (below), scaffold a Karpathy wiki (further down), add more channels, or just use it.

---

## 🔍 Verifying Ollama & Mnemon Are Actually Being Used

Two independent things to check — one being fine doesn't guarantee the other.

**Ollama itself works:**

```bash
ollama list
curl -s http://localhost:11434/api/embeddings -d '{"model": "nomic-embed-text", "prompt": "test"}' | head -c 200
```

The second command should return real JSON with an `"embedding": [...]` array — not `{"error":"model ... not found, try pulling it first"}` (run `ollama pull nomic-embed-text`) and not a connection error (Ollama itself isn't running — `brew services start ollama`, or `ollama serve &`).

**Mnemon is actually using it** — the authoritative check, straight from mnemon's own CLI, run from inside a *live agent container* (not the orchestrator itself):

```bash
docker ps --filter "name=nanoclaw-v2-" --format '{{.Names}}'
docker exec -it <that-container-name> mnemon embed --status
```

```json
{
  "total_insights": 87,
  "embedded": 87,
  "coverage": "100%",
  "ollama_available": true,
  "model": "nomic-embed-text"
}
```

`ollama_available` is a **live reachability check at the moment you run this** (2-second timeout, per mnemon's own docs) — not "is Ollama installed." It can read `false` even with Ollama fully installed and running, if the model isn't pulled yet, the endpoint's misconfigured, or Ollama just isn't running right now — the three cases above cover all of those. If `coverage` is stuck below 100% from conversations that happened before Ollama was ready, backfill once: `mnemon embed --all` (same `docker exec -it <container>` form).

**What's actually generating your replies, regardless of the above: always Claude, never Ollama.** Ollama only scores *which* past memories mnemon surfaces during recall — mnemon's own architecture doc is explicit about the division of labor: *"The LLM decides WHAT to remember and link. Mnemon handles HOW to store, index, and retrieve."* Turning Ollama off just makes recall fall back to keyword/graph-only scoring; it never changes who's replying to you.

### Talking to Ollama directly

Everything above only exercises the embeddings API, since that's all mnemon uses. `nomic-embed-text` itself is an **embedding-only model — it can't hold a conversation at all**, by design (text in, a fixed-length vector out, nothing else). To actually chat with something via Ollama, pull a separate chat-capable model and use it directly, independent of mnemon or NanoClaw entirely:

```bash
# Pull any chat model (small example — pick whatever fits your hardware)
ollama pull llama3.2

# Simplest: interactive CLI chat
ollama run llama3.2

# Or via the API directly — one-shot completion
curl -s http://localhost:11434/api/generate -d '{
  "model": "llama3.2",
  "prompt": "Why is the sky blue?",
  "stream": false
}'

# Or the chat-style endpoint (multi-turn, message array)
curl -s http://localhost:11434/api/chat -d '{
  "model": "llama3.2",
  "messages": [{"role": "user", "content": "Why is the sky blue?"}],
  "stream": false
}'
```

This is entirely separate infrastructure from your NanoClaw conversation — a different model, reachable the same way (same `ollama serve` instance on `localhost:11434`), but nothing here touches mnemon, the wiki, or anything Claude-side. Useful for confirming Ollama itself is healthy beyond just the embeddings path, or just for local experimentation.

**Want a proper chat UI instead of raw `curl`/CLI?** This environment already bundles one — see "🌐 Bundled Open WebUI" below.

### Can NanoClaw Itself Talk to Ollama?

Yes — two separate, opt-in upstream NanoClaw skills do this, distinct from both mnemon's own embeddings (above) and from each other. Neither is enabled by this environment by default; run either yourself against a live install (see "Launching Claude CLI Directly" below).

**`/add-ollama-tool` — Claude keeps orchestrating; Ollama becomes a callable tool.** Registers an MCP server exposing `ollama_list_models` and `ollama_generate`, plus opt-in admin tools (`ollama_pull_model`, `ollama_delete_model`, `ollama_show_model`, `ollama_list_running`, gated behind `OLLAMA_ADMIN_TOOLS=true`). Claude remains the one holding the conversation; Ollama is just another tool it can reach for, the same way it reaches for mnemon or any other MCP tool.

**`/add-ollama-provider` — swaps an entire group's conversation over to Ollama, no Claude involved for that group.** Ollama exposes an Anthropic-compatible `/v1/messages` endpoint, so this works by overriding `ANTHROPIC_BASE_URL` in that group's own `container.json`, with `NO_PROXY`/`no_proxy=host.docker.internal` set so OneCLI's own proxy (see "Security Notes" below) doesn't intercept the traffic, and `blockedHosts: ["api.anthropic.com"]` (resolved to `0.0.0.0` via Docker's `--add-host`) so a misconfigured group can't silently fall through to a real, billed Anthropic call. One gotcha worth knowing if you use this: the Claude Agent SDK stamps a per-request cache-busting nonce (`cch=<hash>`) that defeats Ollama's own prompt-prefix cache, making repeated responses slower than talking to Ollama directly — upstream's documented workaround is a small (~40 line) local Node proxy that normalizes that nonce to a constant before forwarding to Ollama; see NanoClaw's own `docs/ollama.md` for the full script if you go this route.

---

## 🌐 Bundled Open WebUI

A browser chat UI for the same host Ollama daemon this environment's `MNEMON_EMBED_ENDPOINT` uses/installs — deployed automatically alongside the orchestrator, not a separate step. `run.sh`'s `ensure_open_webui()` runs right after `ensure_ollama_ready()` on every deploy: pulls `ghcr.io/open-webui/open-webui:main` (a prebuilt image — no build step, unlike the orchestrator) and starts it if it isn't already running.

**On by default.** `ENABLE_OPEN_WEBUI=true` in `.env.example`. Visit `http://<host-ip>:${OPEN_WEBUI_PORT:-3011}` (deliberately a different default port than the standalone `open-webui` environment's `3010` — see below) and sign up; the first account created becomes admin.

**Needs a chat-capable model, separately from mnemon's own embedding model.** `nomic-embed-text` (mnemon's default) is embedding-only — it can't hold a conversation. Pull one yourself: `ollama pull llama3.2`.

**To disable it**: set `ENABLE_OPEN_WEBUI=false` in `.env`. This only stops `run.sh` from *creating* it — an already-running instance needs `REBUILD_POLICY=TEARDOWN ./run.sh` (or `CLEAN`) afterward to actually go away, same as any other policy-driven change here.

**Relationship to the standalone `open-webui` environment**: that one still exists, for anyone who wants a chat UI for their host's Ollama *without* deploying NanoClaw at all — it's a plain Docker Compose environment with its own independent lifecycle. The two are deliberately namespaced apart (`nanoclaw-mnemon-open-webui` vs `open-webui` container names, port `3011` vs `3010`, separate data volumes) so both can run on the same machine at once without colliding, if you ever want that for some reason.

---

## Security Notes

Worth being precise about what this environment does and doesn't change, relative to the plain `nanoclaw` environment's own security model (see its README's "Deployment Modes" section, and the point that Docker socket access is inherently root-equivalent on the host — that discussion applies identically here). That includes the first-run wizard's "you are running as root" warning: this environment's orchestrator image has no `USER` directive either, and the same reasoning applies — see the plain `nanoclaw` README's "Notes" section for why answering "continue as root" is fine here too.

- **This does not expand the orchestrator's own trust boundary.** Mnemon runs inside the per-conversation-group agent containers, which — verified directly against NanoClaw's own `src/container-runner.ts` — never hold the Docker socket, never run `--privileged`, and have tightly group-scoped bind mounts to begin with. Adding mnemon inside that same sandbox doesn't give it any access the agent container didn't already have.
- **It does add a new third-party dependency.** `mnemon-dev/mnemon` is a real, independent, Apache-2.0-licensed project (377 stars at last check) — a separate trust relationship from `nanocoai/nanoclaw` itself, running as a single Go binary with filesystem access scoped to whatever the agent container already has (its own group's mounts).
- **The patch mechanism itself is text-editing NanoClaw's own build files** (`container/Dockerfile`, `container/entrypoint.sh`) inside your local clone — verify the patch output yourself after first deploy if you want to confirm exactly what changed, or diff against upstream's own `/add-mnemon` skill output.
- **Credential handling is unchanged from plain NanoClaw** — this environment doesn't touch it at all. `setup/register-claude-token.sh` (verified directly) hard-requires the `onecli` binary with no fallback; your Anthropic token is registered into OneCLI's own vault by the wizard and never lands in `.env` or gets held directly by an agent container. `/add-ollama-provider`'s `NO_PROXY`/`no_proxy` env vars exist specifically to bypass OneCLI's proxy for Ollama traffic, which is a good pointer to what OneCLI actually does day to day — it's a local HTTP proxy sitting in front of outbound API calls, injecting credentials at request time rather than handing them to the container outright. Same mechanism, same trust model, as the plain `nanoclaw` environment's own README documents.

---

## Coexistence with the Plain `nanoclaw` Environment

Both environments can run on the same machine. Two things were specifically handled for this:

- **Separate install paths, container names, and ports** (`nanoclaw-mnemon` vs `nanoclaw`, `$HOME/nanoclaw-mnemon` vs `$HOME/nanoclaw`, port `3081` vs `3080`) — set via this environment's own `.env.example` defaults.
- **Agent-container sweeps are scoped by bind-mount path, not by name pattern.** NanoClaw names every conversation group's agent container/image `nanoclaw-agent-v2-*` regardless of which install spawned it — a plain name-prefix filter (which is what the plain `nanoclaw` environment's `run.sh` uses, since it never needed to worry about a second coexisting install) would sweep up the *other* environment's agent containers too during `TEARDOWN`/`CLEAN`. This environment's `run.sh` instead inspects each candidate container's actual bind mounts via `docker inspect` and only touches ones that trace back to `$NANOCLAW_INSTALL_PATH` — verified against synthetic mount data covering exactly this cross-environment collision case before being considered correct.

---

## 📖 Optional: Karpathy LLM Wiki

The gist's Obsidian-facing piece splits into two parts, only one of which is custom:

- **Generating the wiki content is a first-party NanoClaw skill**, [`/add-karpathy-llm-wiki`](https://github.com/nanocoai/nanoclaw/blob/main/.claude/skills/add-karpathy-llm-wiki/SKILL.md) (bundled in the main `nanocoai/nanoclaw` repo, following [Karpathy's public LLM Wiki gist](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f)) — an LLM-maintained, cross-linked markdown knowledge base per conversation group (`wiki/`, `sources/`, `index.md`, `log.md`), explicitly designed as "a git-backed markdown directory." Nothing about the output format is Obsidian-specific — any markdown reader works (VS Code, Logseq, GitHub's own renderer, plain `cat`) — Obsidian is just the pattern doc's suggested viewer (it name-drops Web Clipper, graph view, the Dataview plugin).
- **Only the sync leg is genuinely custom**: the gist author's own iCloud + `rsync` pipeline from a personal Mac Mini to their own Obsidian vault. That's inherently tied to one person's device setup — not something pi-bootstrap can generically automate. If you want the wiki synced somewhere specific, that's a manual step on top of the plain markdown files this skill produces.

**What this environment scaffolds vs. what stays interactive**: `./scaffold-wiki.sh <group-folder>` creates the mechanical, non-collaborative half — `wiki/`, `sources/`, empty `index.md`/`log.md` — for one group, idempotently (safe to re-run). The rest of the upstream skill (choosing a domain, designing the schema, writing a tailored `container/skills/wiki/SKILL.md`, wiring a CLAUDE.md section) is explicitly collaborative by its own design — it discusses the domain with you before writing anything, which unattended scripting can't replicate without producing a generic, shallow wiki. Run `/add-karpathy-llm-wiki` yourself in a Claude Code session against the group for that part; `scaffold-wiki.sh`'s own output prints the exact command.

**Note on how this differs from the gist's own wiki**: `/add-karpathy-llm-wiki` compiles wiki pages straight from raw sources you feed it. In the gist's actual pipeline, the wiki is downstream of mnemon instead — pages are synthesized from mnemon's already-extracted facts, not raw sources directly (see `GIST-PARITY.md`'s embeddings section for the full breakdown, quoted from the gist). Both produce a markdown wiki; the gist's version has an extraction step (mnemon) in between that this environment's scaffolding doesn't replicate.

**A discrepancy worth knowing about**: the skill's Step 3c, as currently documented upstream, edits the group's `CLAUDE.md` directly. But NanoClaw's `container-runner`/`claude-md-compose.ts` now regenerates `CLAUDE.md` fresh on every container spawn (its own header comment: *"Composed at spawn — do not edit. Edit CLAUDE.local.md for per-group content."*) — so a marker-based edit landing in `CLAUDE.md` would silently vanish on the next restart. This looks like the skill doc predates that compose refactor. `scaffold-wiki.sh` flags this in its own output; verify which file the skill actually wrote to afterward, and move the wiki section into `CLAUDE.local.md` if it landed in `CLAUDE.md`.

**"Add sources via Telegram" doesn't mean the file has to travel through Telegram.** The pattern's own doc literally says *"drop new sources into the raw collection; the LLM processes them"* — `sources/` is a plain directory at `$NANOCLAW_INSTALL_PATH/groups/<group>/sources/`, bind-mounted to your host filesystem like everything else here, so `cp`-ing a file straight into it works fine. The catch: NanoClaw's agent only acts on inbound messages — there's no background process watching `sources/` for new files and reacting on its own (verified against both the pattern doc and NanoClaw's own architecture; neither describes a file-watcher). So the real workflow is: drop the file into `sources/` yourself, then send a message on whichever channel the group uses — e.g. *"I just added `report.pdf` to sources/, please ingest it"* — since that message, not the file's arrival, is what actually wakes the agent up to go read and process it. Telegram is just the natural place to have that conversation, not a requirement on how the file itself gets there.

**More complete alternatives exist — it's an ecosystem, not one project**: at least five independent implementations of the same Karpathy pattern exist outside NanoClaw (`nvk/llm-wiki`, `praneybehl/llm-wiki-plugin`, `ussumant/llm-wiki-compiler`, `lucasastorian/llmwiki`, `Pratiyush/llm-wiki`), none built on each other. See `GIST-PARITY.md` for the full comparison — including the one that matters most if you want to actually integrate one here: `lucasastorian/llmwiki` uses an MCP server rather than a Claude Code plugin, which sidesteps the open question the other four share (whether Claude Code's plugin-install mechanism even works inside NanoClaw's agent-runner container) by reusing the same MCP-server-registration pattern NanoClaw's own `/add-ollama-tool` already proves out.

---

## 🚀 Launching Claude CLI Directly (Skills, Ad-Hoc Questions, etc.)

Beyond the setup wizard, you can start an interactive Claude Code session against the orchestrator's own NanoClaw checkout at any time — this is how you run skills like `/add-karpathy-llm-wiki` (above), re-run `/add-mnemon` (already applied automatically by this environment, but useful to know it's there), or just ask Claude something about the codebase directly:

```bash
docker exec -it nanoclaw-mnemon bash -lc "cd \$NANOCLAW_INSTALL_PATH && claude"
```

**Discovering what's available**: NanoClaw ships its own skills under `.claude/skills/` in its checkout — list them directly from outside the session:

```bash
docker exec nanoclaw-mnemon ls "$NANOCLAW_INSTALL_PATH/.claude/skills/"
```

Or, once inside an interactive `claude` session, type `/` on its own — Claude Code's own command palette lists every available slash command, built-in and skill-provided alike, with a one-line description each, and autocompletes as you keep typing.

---

## 🌐 SSH'ing in from Another macOS Machine

Yes, this works — it's just Docker underneath, so the normal remote-Docker approach applies once you can reach the host machine at all:

**SSH to the host, then `docker exec` from there**: `ssh you@<host>` followed by the exact same command from "Launching Claude CLI Directly" above (`docker exec -it nanoclaw-mnemon bash -lc "cd \$NANOCLAW_INSTALL_PATH && claude"`) — no different from running it locally, since you're now just a normal shell session on the host itself.

**Would Claude then be able to open a browser back on your own Mac (the one you SSH'd *from*)?** No. Even a Claude session running natively on the host (not in a container) can only open a browser on a display *that host* can reach, and a plain SSH session has no display at all by default — no `DISPLAY`, no GUI forwarding, unless you specifically set it up. X11 forwarding (`ssh -Y`) can pipe a *Linux* GUI app's window back to your Mac via XQuartz, but that solves the wrong problem here: Safari is a native macOS app, not something X11 forwards, and Claude's own copy-paste-the-URL flow (see "First-Time Setup" above, and "Why Can Claude Open a Browser on My Mac, But Not Inside Docker?" further up) is exactly the same mechanism whether you're local or remote — it prints a URL, you paste it into whichever browser is actually in front of you on the machine you're physically sitting at.

**In short**: SSH in, `docker exec` in, use the printed-URL copy-paste flow the same way you would sitting at the host directly — don't expect a browser to pop up on your remote Mac's own screen either way.

---

## 💾 Data Directories

Persistent data lives inside the install path and survives `TEARDOWN` **and** `CLEAN` (see the callout below — this wasn't always true):

| Directory | Contents |
|-----------|---------|
| `$NANOCLAW_INSTALL_PATH/groups/` | Per-group files: conversation history, mnemon's persistent memory graph (nested under each group's `.claude/mnemon/`), transcripts, CLAUDE.md, and — if scaffolded — each group's `wiki/`/`sources/` (see "Optional: Karpathy LLM Wiki") |
| `$NANOCLAW_INSTALL_PATH/data/` | Sessions, message database, task scheduler database, IPC streams |
| `$NANOCLAW_INSTALL_PATH/.env` | Anthropic/channel credentials NanoClaw's own wizard collected |
| `$NANOCLAW_INSTALL_PATH/store/` | Channel session state (e.g. WhatsApp pairing) |
| `${CONTAINER_NAME:-nanoclaw-mnemon}_open_webui_data` (named Docker volume, not a bind mount) | Bundled Open WebUI's own accounts, chat history, per-model settings — only exists if `ENABLE_OPEN_WEBUI` is true (the default) |

> **Fixed bug, worth knowing about if you deployed before this fix**: `CLEAN` used to `rm -rf` the entire install path and re-clone from scratch, destroying `groups/`, `data/`, `store/`, and `.env` right along with it — including any scaffolded wiki. That's since been fixed (`run.sh` now hard-resets NanoClaw's git-tracked source with `git reset --hard` instead of deleting the directory, which by construction never touches the paths above — they're all in NanoClaw's own `.gitignore`, so `.env`/`groups/`/`data/`/`store/`/`dist/` are simply invisible to git operations). If you hit the old behavior and lost data, there's no recovery path here — this note is so it doesn't happen again, not a way to undo it.

The install directory's own NanoClaw source is safe to treat as disposable (`CLEAN` keeps it in sync with upstream); the directories above are the actual state worth backing up separately regardless, since a fixed `CLEAN` is not a substitute for real backups.

---

## 🎛️ Deployment Policies

| Policy | Action |
|--------|--------|
| `FAST` | Start the orchestrator container if stopped; skip if already active. Clones NanoClaw and applies the mnemon patch on first deploy only. Also starts Open WebUI if `ENABLE_OPEN_WEBUI` is true and it isn't already running |
| `STOP` | Stop the orchestrator container and Open WebUI (agent containers keep running) |
| `TEARDOWN` | Stop the orchestrator + Open WebUI + remove this install's agent containers (scoped by mount path — see "Coexistence" above); data, Open WebUI's own volume, and install path untouched |
| `CLEAN` | Rebuild the orchestrator image, remove this install's agent containers, hard-sync the install path's NanoClaw source to latest upstream (git-tracked files only — `.env`/`groups/`/`data/`/`store/`/`dist/` untouched, see "Data Directories" above), reapply the mnemon patch, rebuild and restart if this was an existing install (skips the wizard entirely — it only ever runs when `dist/index.js` doesn't exist yet). Also recreates Open WebUI (its own data volume untouched) so a toggled `ENABLE_OPEN_WEBUI`/`OPEN_WEBUI_PORT`/`WEBUI_AUTH` takes effect |
| `INFO` | List data directories with sizes and useful commands (scrollable via `less` in an interactive terminal) |
| `WIPE` | Delete `groups/` and `data/` only (install dir and Open WebUI's own volume preserved) |

---

## ⬆️ Upgrading NanoClaw Without Redoing Setup

Two different things can look like "upgrading" — worth being precise about which is which, though as of the `CLEAN` fix above, neither one forces you to redo setup on an existing install anymore:

- **`CLEAN` hard-syncs NanoClaw's source to latest upstream** (`git fetch` + `git reset --hard @{u}`, replacing an earlier version that `rm -rf`'d and re-cloned the whole install path — see the fixed-bug callout under "Data Directories" above), then reapplies pi-bootstrap's own patches (mnemon, the OrbStack gateway fix, the nohup-autostart fix) to that tree, and rebuilds/restarts if this was an existing install. It's still the mechanism for pi-bootstrap's own patch maintenance (a `MNEMON_VERSION` bump, a fix to `run.sh` itself), but you can now also reach for it as a general "get me on latest" button — it no longer discards your groups, data, credentials, or wiki, and no longer forces the wizard to run again on an existing install. What it does *not* do: preserve any manual edits you made directly inside the NanoClaw checkout yourself — `reset --hard` discards those, since it forces the tree to exactly match upstream's latest commit.
- **NanoClaw's own `/update-nanoclaw` skill is the more careful upgrade path**, for when you specifically want that carefulness: run it from an interactive Claude Code session against the orchestrator (see "Launching Claude CLI Directly" above). It fetches upstream changes, creates a backup branch + tag first, shows a diff preview before touching anything, then merges/cherry-picks/rebases them into your *existing* checkout and validates the result (`pnpm run build`/`pnpm test`) — which matters if you've made local changes inside the checkout you want kept, or just want to review what's changing before it lands.

**In short**: both are now safe to run without losing your setup. `CLEAN` is the "just get me on latest, I don't need to review it" button (and remains the one to reach for after a `MNEMON_VERSION` bump or a `run.sh` change); `/update-nanoclaw` is the "show me a diff first, and don't discard any local edits" button. Pick based on how much you want to review, not out of fear of losing anything — that fear was legitimate before the fix above, it no longer is.

> **Not yet independently re-verified end-to-end** (i.e. an actual `CLEAN` run against a real existing install, confirming data survives and the wizard is correctly skipped) — the fix was validated via `bash -n` syntax checking and direct reasoning against NanoClaw's own `.gitignore` and `run.sh`'s existing `dist/index.js` check, not a live re-run in this session. Worth confirming yourself on your first `CLEAN` after upgrading.

---

## 🖥️ Desktop Integration

On a Pi with a desktop environment, run once from the repo root:

```bash
./install-desktop-entries.sh
# or just this environment on its own:
bash lib/run-install-desktop.sh environments/nanoclaw-mnemon
```

This installs a **NanoClaw + Mnemon AI** entry, in its own submenu, separate from the plain `nanoclaw` environment's entry. Skipped entirely on macOS (Linux-only, like every environment's desktop entries in this repo — see the main README's "Desktop Menu Integration" section).

---

## 💡 Useful Commands

```bash
# Orchestrator status and live logs
docker ps --filter name=nanoclaw-mnemon
docker logs -f nanoclaw-mnemon

# Restart after a config change
docker restart nanoclaw-mnemon

# Add messaging channels / update the Anthropic API key
docker exec -it nanoclaw-mnemon bash -lc "cd \$NANOCLAW_INSTALL_PATH && bash setup/add-whatsapp.sh"
docker exec -it nanoclaw-mnemon bash -lc "cd \$NANOCLAW_INSTALL_PATH && bash setup/add-telegram.sh"
docker exec -it nanoclaw-mnemon bash -lc "cd \$NANOCLAW_INSTALL_PATH && bash setup/register-claude-token.sh"

# List this install's agent containers (and the plain nanoclaw environment's, if also deployed — both share the nanoclaw-agent-v2-* name pattern)
docker ps --filter name=nanoclaw-agent

# Find a specific group's own live agent container (needed for the mnemon commands below)
docker ps --filter "name=nanoclaw-v2-" --format '{{.Names}}\t{{.Status}}'

# Confirm mnemon is installed in the agent sandbox image
docker exec nanoclaw-mnemon docker run --rm --entrypoint mnemon nanoclaw-agent:latest --version

# Check mnemon's own embedding coverage / whether Ollama is actually reachable right now
# (see "Verifying Ollama & Mnemon Are Actually Being Used" above)
docker exec -it <agent-container-name> mnemon embed --status
docker exec -it <agent-container-name> mnemon embed --all      # backfill after enabling Ollama late
docker exec -it <agent-container-name> mnemon status            # general memory statistics

# Ollama itself (runs on the host, not in a container — see "Mnemon Integration" above)
ollama list
ollama pull nomic-embed-text
curl -s http://localhost:11434/api/embeddings -d '{"model": "nomic-embed-text", "prompt": "test"}'

# Bundled Open WebUI (see "Bundled Open WebUI" above)
docker logs -f nanoclaw-mnemon-open-webui
ollama pull llama3.2      # a chat-capable model — nomic-embed-text is embedding-only

# Scaffold a Karpathy LLM Wiki for one group (see "Optional: Karpathy LLM Wiki" above)
./scaffold-wiki.sh <group-folder>

# Launch an interactive Claude Code session against the orchestrator's own
# checkout — run skills (/add-karpathy-llm-wiki, /add-mnemon), or just ask
# Claude something directly (see "Launching Claude CLI Directly" above)
docker exec -it nanoclaw-mnemon bash -lc "cd \$NANOCLAW_INSTALL_PATH && claude"

# List every skill NanoClaw ships (or type `/` inside an interactive claude
# session for the same list with descriptions and autocomplete)
docker exec nanoclaw-mnemon ls "$NANOCLAW_INSTALL_PATH/.claude/skills/"
```

NanoClaw itself still has no web UI of its own (see the plain `nanoclaw` environment's README) — there's no `http://<host-ip>:3081` to visit unless you've separately added its optional `/add-dashboard` skill. `http://<host-ip>:3011` (bundled Open WebUI, on by default) is a genuine web UI, just not NanoClaw's own — see "Bundled Open WebUI" above.

---

## What's Verified vs What Isn't

Verified directly against a real deploy, not assumed:
- The mnemon patch's exact text output, byte-for-byte, against the *actual current* `container/Dockerfile` and `container/entrypoint.sh` fetched live from `nanocoai/nanoclaw` — both insertions land exactly where and as the upstream skill file specifies.
- Idempotency — reapplying the patch against already-patched files correctly detects and skips both steps, no duplication.
- The full `FAST`/`CLEAN` control flow end-to-end, including a real `git clone`, real patch application, real `docker build`/`run`/mount/port sequence, the interactive `nanoclaw.sh` wizard running to completion inside a real container (Anthropic OAuth sign-in, root warning, Telegram channel pairing), and a real chat message getting a real model response.
- The cross-environment agent-container sweep filtering, against synthetic mount data covering exactly the "both environments deployed at once" collision case.
- Mnemon's own `mnemon embed --status`/`mnemon setup --target claude-code` steps, working correctly inside this containerized agent sandbox — including the Ollama install prompt and reachability checks. `ollama_available: true` specifically (i.e. mnemon's embed pipeline actually succeeding end-to-end) was not directly confirmed in this environment's own build/test process — `mnemon embed --status` is exactly how to check it yourself after pulling the embedding model.
- Several genuine, non-obvious bugs found and fixed only by testing against a real OrbStack/macOS deploy rather than synthetic stubs — see the git history for `run.sh`, `patch-host-gateway.cjs`, and `patch-nohup-autostart.cjs` if you want the full diagnostic trail for any of them: NanoClaw's own nohup-fallback service-start step (writes but never runs its own wrapper), `systemctl`-based channel-installer restarts silently no-op'ing (no real systemd in this container), OrbStack's `host.docker.internal`/`host-gateway` resolving to a different address than the one its own port-publishing actually uses, and `/tmp` not being shared between this container and the host (breaking OneCLI's own certificate hand-off to spawned agent containers).

**Not yet independently re-verified, added most recently, worth confirming on your own next `CLEAN`:**
- `CLEAN` no longer wiping `.env`/`groups/`/`data/`/`store/` — found via a real deploy losing exactly this data (including a scaffolded wiki), fixed by replacing the `rm -rf`+re-clone with `git reset --hard` against NanoClaw's own `.gitignore`, and confirmed only via `bash -n` + direct reasoning in this session, not a live re-run of `CLEAN` against an existing install with real data in it.
- Container timezone now following the host — confirmed the mechanism exists correctly upstream (`config.ts`'s `TIMEZONE` resolution, `container-runner.ts`'s `-e TZ=${TIMEZONE}` passthrough to spawned agent containers) and that `run.sh` now feeds it a real value, but not confirmed against an actual running container's `date` output in this session.
- Bundled Open WebUI (`ensure_open_webui()`) — reasoned through against the same upstream image and flags the standalone `open-webui` environment already uses, and syntax-checked, but not confirmed against a real deploy in this session: that it actually reaches the host's Ollama daemon, that `FAST`/`STOP`/`TEARDOWN`/`CLEAN` all behave as described above, and that the two environments' differing ports/container/volume names actually avoid a collision if both are ever deployed together.

Same caveat as the plain `nanoclaw` environment: this covers what's been tested, not a guarantee against everything upstream might change — treat your own first deploy as the real test, and see `MANUAL-STEPS.md` if you ever want to understand or reproduce any of this by hand.

---

## 📚 Further Reading

- **NanoClaw** — [nanocoai/nanoclaw](https://github.com/nanocoai/nanoclaw): the orchestrator and per-group agent sandbox this environment wraps. Its own `.claude/skills/` directory documents every skill referenced above (`/add-mnemon`, `/add-karpathy-llm-wiki`, `/add-telegram`, `/add-ollama-tool`, `/add-ollama-provider`, `/add-dashboard`, and more).
- **Claude Code** — [code.claude.com/docs](https://code.claude.com/docs): the CLI/SDK NanoClaw's agent containers run on — slash commands, skills, hooks, MCP servers, and the OAuth/subscription sign-in flow covered above.
- **Mnemon** — [mnemon-dev/mnemon](https://github.com/mnemon-dev/mnemon): the persistent-memory tool patched into the agent sandbox here. Its own `docs/USAGE.md` has the full CLI reference (`remember`, `recall`, `link`, `forget`, `gc`, `embed --status`, `embed --all`) and `docs/design/` covers the four-graph model.
- **Ollama** — [ollama.com](https://ollama.com): the optional local inference server mnemon's hybrid recall uses purely for embeddings, never for chat (see "Verifying Ollama & Mnemon" above). [ollama.com/download](https://ollama.com/download) for manual installs; [ollama.com/library](https://ollama.com/library) for browsing models beyond the default `nomic-embed-text`.
- **Karpathy's LLM Wiki pattern** — [the original gist](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f): the source pattern `/add-karpathy-llm-wiki` implements. `GIST-PARITY.md` in this directory compares this environment's implementation against it and five other independent implementations of the same pattern.
- **The gist this environment follows** — [VivianBalakrishnan's gist](https://gist.github.com/VivianBalakrishnan/a7d4eec3833baee4971a0ee54b08f322): NanoClaw + mnemon + local embeddings + wiki + Obsidian sync as a "second brain," with the credibility caveat discussed at the top of this README.
