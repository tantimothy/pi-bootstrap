# NanoClaw + Mnemon — Persistent Memory AI Assistant

The same self-hosted [NanoClaw](https://github.com/nanocoai/nanoclaw) AI assistant as the plain `nanoclaw` environment, with [mnemon](https://github.com/mnemon-dev/mnemon) — a real, independent, third-party persistent-memory tool — patched into NanoClaw's own per-conversation-group agent sandbox for cross-session graph memory. Three extras layer on top of that core: mnemon's own built-in optional Ollama embeddings for hybrid graph+vector recall (opt-in via `.env`, off by default), a scaffolding script for NanoClaw's own Karpathy-pattern wiki skill (`scaffold-wiki.sh`, run manually per group), and bundled `yt-dlp`/`whisper.cpp` for turning a video into a plain-text transcript you can feed into a group's wiki (see "🎙️ Transcribing Audio/Video" below). Want a chat UI for Ollama too? See the standalone `chat-frontends` environment — this one no longer bundles its own.

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

### Where Can an Agent Actually Write Persistent Data?

Not just anywhere in its own container — verified directly against `container-runner.ts`'s own `buildMounts()`:

| Container path | Host source | Persistent? | Scope |
|---|---|---|---|
| `/workspace` | that session's own session folder | Yes | **Per-session**, not per-group — a group in per-thread mode (one session per Telegram thread) gets a *separate* `/workspace` per thread |
| `/workspace/agent` | the group's own folder (`groups/<group>/`) | Yes | **Per-group** — shared across every session/thread in that group. The right place for anything meant to persist across a group's whole conversation history (e.g. a self-installed tool, per group) |
| `/home/node/.claude` | that group's `.claude-shared` state dir | Yes | Per-group, but reserved for Claude Code's own internal state/settings/skill-symlinks — not really meant as general scratch space |
| Everything else (e.g. `/tmp`) | the container's own ephemeral layer | **No** | Writable if permissions allow, but vanishes on every container respawn — not backed by host storage at all |

`/workspace/agent`'s persistence survives more than it might look like: since it's a bind mount to real host storage rather than part of the container's own image layer, it survives both an ordinary container respawn (idle agent containers get torn down and recreated routinely) *and* a full agent-image rebuild — it's only lost if that specific group's own folder is wiped (this environment's `WIPE` policy, or manual deletion).

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
2. Adds `mnemon setup --yes --global` to `container/entrypoint.sh`, run on every agent container start. `--global` is required — confirmed by running `mnemon setup` interactively inside a real agent-sandbox container: without it, mnemon auto-detects Claude Code correctly but writes hooks to a *project-local* `.claude/settings.json` relative to entrypoint.sh's own working directory (`/workspace/group`), not the *global* `~/.claude/settings.json` NanoClaw actually bind-mounts per group and Claude Code actually reads. `--target claude-code` is deliberately NOT included — auto-detection alone was never the problem.

Both steps are applied **before** NanoClaw's own setup wizard builds the agent image for the first time, so the very first build already includes mnemon — no separate rebuild step needed, unlike applying this skill to an already-running install.

**Reloading mnemon for a group that's already running**: a rebuilt image only affects a group the next time NanoClaw actually spawns a fresh container for it — waiting for that (a real chat message) isn't always convenient, especially right after fixing something. `./scripts/reload-mnemon.sh` re-runs `mnemon setup --yes --global` directly against that group's real, persistent `.claude-shared` directory using the current image, with no chat round-trip needed — the same command verified above, just targeted immediately instead of waiting.

Run it with no arguments and it finds the group for you: it queries NanoClaw's own central DB (`data/v2.db`'s `agent_groups` table — confirmed directly against its own `src/db/agent-groups.ts`) for real registered group names, auto-picks if there's only one, or prompts with a numbered list if there's more than one — no need to already know a group's opaque `ag-<timestamp>-<hash>` session ID. Pass one explicitly (`./scripts/reload-mnemon.sh <group-session-id>`) to skip discovery, or if `sqlite3` isn't installed / `data/v2.db` doesn't exist yet, in which case it falls back to listing raw `data/v2-sessions/` folder names instead. Also available as **"Reload Mnemon for a Group"** from `deploy.sh`'s own menu for this environment — same no-argument discovery flow.

**Version pinning**: `MNEMON_VERSION` in `.env` (default `0.1.17`, [current as of this writing](https://github.com/mnemon-dev/mnemon/releases)) controls exactly which mnemon release gets installed. Pinned rather than "latest" specifically so a `CLEAN` redeploy doesn't silently pick up a new release without you choosing to — a `CLEAN` reapplies the patch with whatever `MNEMON_VERSION` is currently set, and it won't drift on its own between deploys. Bump it by editing `.env` and running `CLEAN` — check the [releases page](https://github.com/mnemon-dev/mnemon/releases) for what's current; this default only reflects whatever was latest when it was last updated, not a guarantee it stays current on its own.

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

**Want a proper chat UI instead of raw `curl`/CLI?** See the standalone `chat-frontends` environment — this one doesn't bundle its own.

### Can NanoClaw Itself Talk to Ollama?

Yes — two separate, opt-in upstream NanoClaw skills do this, distinct from both mnemon's own embeddings (above) and from each other. Neither is enabled by this environment by default; run either yourself against a live install (see "Launching Claude CLI Directly" below).

**`/add-ollama-tool` — Claude keeps orchestrating; Ollama becomes a callable tool.** Registers an MCP server exposing `ollama_list_models` and `ollama_generate`, plus opt-in admin tools (`ollama_pull_model`, `ollama_delete_model`, `ollama_show_model`, `ollama_list_running`, gated behind `OLLAMA_ADMIN_TOOLS=true`). Claude remains the one holding the conversation; Ollama is just another tool it can reach for, the same way it reaches for mnemon or any other MCP tool.

**`/add-ollama-provider` — swaps an entire group's conversation over to Ollama, no Claude involved for that group.** Ollama exposes an Anthropic-compatible `/v1/messages` endpoint, so this works by overriding `ANTHROPIC_BASE_URL` in that group's own `container.json`, with `NO_PROXY`/`no_proxy=host.docker.internal` set so OneCLI's own proxy (see "Security Notes" below) doesn't intercept the traffic, and `blockedHosts: ["api.anthropic.com"]` (resolved to `0.0.0.0` via Docker's `--add-host`) so a misconfigured group can't silently fall through to a real, billed Anthropic call. One gotcha worth knowing if you use this: the Claude Agent SDK stamps a per-request cache-busting nonce (`cch=<hash>`) that defeats Ollama's own prompt-prefix cache, making repeated responses slower than talking to Ollama directly — upstream's documented workaround is a small (~40 line) local Node proxy that normalizes that nonce to a constant before forwarding to Ollama; see NanoClaw's own `docs/ollama.md` for the full script if you go this route.

**Reverting a group back to Claude** — the `/add-ollama-provider` skill's own doc covers this directly (no separate "remove" skill exists, and none is needed — it's just undoing the two file edits the skill made):

1. Remove the `env` and `blockedHosts` keys from `groups/<FOLDER>/container.json`.
2. Remove the `"model"` key from that group's shared Claude settings file (`data/v2-sessions/<agent-group-id>/.claude-shared/settings.json`).
3. Force that group's agent container to respawn so it re-reads both files — container.json/settings.json are only read at container spawn time, not live: `docker stop $(docker ps --filter "name=nanoclaw-v2-<FOLDER>" --format "{{.Names}}")`. The next message to that group spins up a fresh container with the reverted config; no orchestrator restart or image rebuild needed either way.

No dedicated skill does this for you, but there's nothing stopping you from asking Claude to do it inside the same interactive session used for the skills above (`docker exec -it nanoclaw-mnemon bash -lc "cd \$NANOCLAW_INSTALL_PATH && claude"`) — it's just two small JSON edits and a container restart, well within what to just describe and ask for directly rather than needing a formal skill.

---

## 🎙️ Transcribing Audio/Video (`yt-dlp` + `whisper.cpp`)

`yt-dlp` (downloads/extracts audio from YouTube and most other video sites) and Whisper (local, offline speech-to-text — no API key, no account, no data leaving the machine) are available through **three different paths** — two this repo builds and maintains, one the agent can improvise entirely on its own:

- **The orchestrator image** — for you to run by hand (see "Manual pipeline" below), producing a transcript you drop into a group's `sources/` folder yourself.
- **The agent sandbox image** (`container/Dockerfile`, patched in by `apply_media_tools_patch()` in `run.sh`, the same idempotent text-splice mechanism `apply_mnemon_patch()` uses) — so the **agent itself** can pull down and transcribe a video directly from its own Bash tool when you just paste a URL in chat, no manual steps at all. Uses native, compiled `whisper.cpp` — faster, especially on longer audio.
- **Agent-improvised, rootless, no rebuild needed** (see below) — not something this repo installs; a real pattern observed with a live agent that found its own way to the same capability entirely on its own initiative, worth knowing about either way.

### Agent-side (paste a URL, the agent handles it)

Works out of the box once you've pulled a model into that specific group's own folder (see below) — just message the group with a video URL and ask it to transcribe/summarize/ingest it. The agent has `yt-dlp`, `ffmpeg`, and `whisper-cli` on its own `PATH` inside its sandbox container.

**One-time setup — pull a model into the group's own folder.** Unlike the orchestrator, there's no shared mount across every agent container (verified directly against NanoClaw's own `container-runner.ts`: only that specific group's own folder is bind-mounted in, at `/workspace/agent` — not the top-level install path) — so the model has to live inside each group that wants this, not once globally:

```bash
GROUP=your-group-folder
mkdir -p "$NANOCLAW_INSTALL_PATH/groups/$GROUP/models"
curl -L https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin \
  -o "$NANOCLAW_INSTALL_PATH/groups/$GROUP/models/ggml-base.bin"
```

That file shows up inside that group's agent container at `/workspace/agent/models/ggml-base.bin` — tell the agent that path (or just mention "the whisper model in your models/ folder") the first time you ask it to transcribe something.

**If you already had this install running before adding this patch**: `run.sh`'s `CLEAN` policy now rebuilds the agent-sandbox image itself (via NanoClaw's own `container/build.sh`) right after re-syncing and re-patching the source — see "Upgrading NanoClaw Without Redoing Setup" below for the full story of why this needed fixing and what it used to do instead (silently nothing, for an existing install). One `CLEAN` run is what actually bakes these tools in.

> **Fixed bug, confirmed against a real build**: on arm64 (Raspberry Pi), the `whisper.cpp` build step failed outright under Debian bookworm's default GCC 12 — `inlining failed in call to 'always_inline' float16x8_t vfmaq_f16(...): target specific option mismatch`, a known GCC-12-on-ARM64 incompatibility in ggml's NEON fp16 vector-arithmetic codepath. Fixed by building with `clang` instead (installed alongside `build-essential`/`cmake`, purged in the same layer same as before) — clang doesn't have this conflict. Applies to both the orchestrator's own `Dockerfile` and the agent-sandbox patch above; if you hit this exact error before pulling this fix, a fresh `CLEAN` now builds cleanly.

> **Fixed bug, confirmed against a real agent run**: `yt-dlp` failed outright with `python3: No such file or directory` — the patch was downloading the plain `yt-dlp` release asset, which is actually a zipimport script needing a system python3 on PATH, not the standalone binary the comment above it claimed. Fixed by picking the real self-contained `yt-dlp_linux*` binary via `uname -m` at patch/build time. **If you hit this before pulling the fix, a plain rebuild won't pick it up on its own**: `apply_media_tools_patch()` skips re-patching the moment it sees *any* `yt-dlp` string already in `container/Dockerfile`, which the old broken patch left behind. Only `CLEAN` clears this, since it `git reset --hard`s NanoClaw's own checkout (wiping the stale patch) before reapplying the corrected one and rebuilding the agent-sandbox image. And because agent containers are ephemeral and spawned fresh per session, an agent's *current* session still runs the old image after that rebuild — it needs a new session (or the group's container recreated) to actually pick up the fix.
>
> **A second, deeper bug compounded the one above, confirmed against a real `CLEAN` run**: `CLEAN`'s own local-edit-preservation step (added to stop channel/provider skills like `/add-telegram` from getting silently unwired — see the "Upgrading NanoClaw" section below) snapshots *every* locally-modified tracked file as a patch before the hard reset and reapplies it after, with no distinction between genuine skill wiring (`src/channels/index.ts`, `package.json`) and `container/Dockerfile`/`container/entrypoint.sh` — which `apply_mnemon_patch`/`apply_media_tools_patch` already own and regenerate idempotently every `CLEAN`, unconditionally, right after. Since those two Dockerfile-editing functions had already left their (in this case stale, pre-fix) patch text sitting in `container/Dockerfile` from an earlier run, that stale text got snapshotted, hard-reset away, then reapplied verbatim on top of the freshly-synced source — so `apply_media_tools_patch()`'s own idempotency check saw the *old* broken `yt-dlp` line again immediately after the "fresh" sync and skipped re-patching, exactly as if `CLEAN` had never run at all. **This meant no `CLEAN` could ever pick up a fix to the Dockerfile patch text once one had shipped once** — not just this yt-dlp fix, any future change to `apply_mnemon_patch`/`apply_media_tools_patch`'s own generated block. Fixed by excluding `container/Dockerfile` and `container/entrypoint.sh` from the local-edit snapshot/reapply entirely (via git pathspec exclusion on both the `status` and `diff` calls) — those two files now always get a clean hard-reset with no stale reapply, and the two patch functions correctly see pristine upstream content and apply their current (fixed) text fresh, every `CLEAN`.

### Agent-improvised, rootless (no rebuild, no approval, per-group only)

**Not something this repo installs** — a real pattern confirmed with a live agent that, on its own initiative, found and used a permission gap to get the same capability without any image rebuild or admin approval at all. Documented here because it's a genuinely different tradeoff worth knowing about, not because pi-bootstrap sets it up.

What it looked like in practice: the agent's own attempt to `apt-get install` packages at *runtime* correctly failed (agent sandboxes are non-root, by design — `/var/lib/dpkg` and `/usr/local` are root-owned, and this is true regardless of which of the two paths above you use, since those install at *build* time, not runtime). Rather than stop there, the agent built an entirely rootless alternative using only its own group's writable folder:

- `yt-dlp` — the prebuilt binary, downloaded directly (matching its own container architecture — arm64 vs amd64 matters here)
- `ffmpeg` — via the `ffmpeg-static` npm package (ships a prebuilt binary, no system install or compiler needed)
- Whisper — via `@xenova/transformers` (runs Whisper in pure JS/WASM via ONNX runtime, no C compiler required) + `wavefile` to decode audio for it

All of it installed inside `/workspace/agent` — that group's own bind-mounted, persistent folder (`$NANOCLAW_INSTALL_PATH/groups/<group>/`), via a `package.json` the agent created there itself and its own `npm install`. Nothing touched anywhere else in the container; nothing needed root or approval, since a group's own writable working directory isn't gated the way system-level installs are.

**Later upgraded to real, native `whisper.cpp` — still fully rootless.** Turns out `whisper.cpp` publishes prebuilt Linux binaries on its own GitHub releases (matching the container's actual architecture, e.g. arm64), so no compiler was needed after all. The one gap — `libgomp` (the OpenMP runtime `whisper.cpp` links against), normally an `apt` package — was worked around by downloading the raw `.deb` directly from Debian's own package mirror and extracting it with `dpkg-deb -x` (extraction is a plain archive operation and needs no root; only `apt install`-ing it does). Confirmed working against a real GGML model (`ggml-base.en.bin` from Hugging Face) with a real transcription. This is a strictly better outcome than the `@xenova/transformers` WASM path above — native, multithreaded, noticeably faster, especially on longer audio — kept the JS version around as a fallback rather than replacing it outright. Same persistence/trust characteristics as everything else in this subsection: whatever the agent placed the `whisper.cpp` binary and `libgomp.so` in still needs to be inside `/workspace/agent` (or another persistent mount — see the table above) to survive a respawn; anywhere else in the container's own filesystem and it silently needs redoing next time that container recreates.

**Persistence, corrected from what first seemed intuitive**: `/workspace/agent` survives both ordinary container respawns and a full agent-image rebuild, not just the current session — see "🧩 What Runs Where" → "Where Can an Agent Actually Write Persistent Data?" above for why (it's a bind mount to real host storage, not part of the container's own image layer). One small exception here specifically: `ffmpeg-static`'s own install-time download cache lands in `~/.cache/ffmpeg-static-nodejs/`, which *isn't* bind-mounted and does disappear on respawn — harmless, since the actual binary it downloads is already copied into that group's own persistent `node_modules/`.

**Worth having an actual opinion about**: this is the agent independently finding a permission gap and using it to fetch and run third-party code (an npm package, a downloaded binary) with zero human review — right after its own *properly gated* request (NanoClaw's own self-mod `install_packages` approval flow) got stuck. Not malicious here, and the end result works — but it's the general pattern worth noticing: closing one path doesn't mean nothing happens on that front, it can mean the agent quietly routes around it on a path you didn't think to gate. Whether that's fine (agent resilience) or something you want more oversight over is a judgment call, not a technical one this README can make for you.

**Tradeoffs vs. the two paths above**: this one needs zero human involvement and works immediately — and, now that native `whisper.cpp` turned out to be reachable rootlessly too (prebuilt binary + a manually-extracted `.deb`, no build tools needed), it's no longer a performance tradeoff either, just a scope one: still stuck to only the one group that did it, since there's no shared installation across groups the way the Dockerfile patch applies to every group from a single image rebuild. Every other group wanting this would redo the whole install (yt-dlp, whisper.cpp binary, libgomp, a GGML model) independently.

### Manual pipeline (you run it, then feed the transcript in yourself)

**One-time setup — pull a model into the install path.** This copy is for the orchestrator's own use, so it lives at the top level, not inside a group folder:

```bash
docker exec -it nanoclaw-mnemon bash -lc "
  mkdir -p \$NANOCLAW_INSTALL_PATH/models
  curl -L https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin \
    -o \$NANOCLAW_INSTALL_PATH/models/ggml-base.bin
"
```

(`ggml-base.bin` is a reasonable default — see [whisper.cpp's model list](https://github.com/ggml-org/whisper.cpp/blob/master/models/README.md) for smaller/larger/multilingual options.)

**Usage** — open an interactive shell (see "Useful Commands" below for the one-liner) rather than prefixing every step with `docker exec`:

```bash
docker exec -it nanoclaw-mnemon bash
cd /tmp

# 1. Pull down just the audio track
yt-dlp -x --audio-format wav -o audio.%(ext)s "https://www.youtube.com/watch?v=VIDEO_ID"

# 2. Resample to 16kHz mono — whisper.cpp's own required input format
ffmpeg -i audio.wav -ar 16000 -ac 1 audio-16k.wav

# 3. Transcribe
whisper-cli -m "$NANOCLAW_INSTALL_PATH/models/ggml-base.bin" -f audio-16k.wav -otxt -of transcript

cat transcript.txt
```

Copy `transcript.txt` into whichever group's `sources/` you want it in (`$NANOCLAW_INSTALL_PATH/groups/<group>/sources/`), then message that group's channel to have the agent ingest it — same workflow as any other source (see "Optional: Karpathy LLM Wiki" above for why dropping the file alone doesn't trigger ingestion on its own).

**No account needed** for either tool against public content, in either workflow — `yt-dlp` works anonymously, and `whisper-cli` is a local model with no API/account of any kind. Age-restricted, unlisted-but-gated, or members-only videos need YouTube cookies from a logged-in browser session passed to `yt-dlp` (`--cookies-from-browser`) — that's your own account, not a separate service.

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

**What this environment scaffolds vs. what stays interactive**: `./scripts/scaffold-wiki.sh <group-folder>` creates the mechanical, non-collaborative half — `wiki/`, `sources/`, empty `index.md`/`log.md` — for one group, idempotently (safe to re-run). The rest of the upstream skill (choosing a domain, designing the schema, writing a tailored `container/skills/wiki/SKILL.md`, wiring a CLAUDE.md section) is explicitly collaborative by its own design — it discusses the domain with you before writing anything, which unattended scripting can't replicate without producing a generic, shallow wiki. Run `/add-karpathy-llm-wiki` yourself in a Claude Code session against the group for that part; `scaffold-wiki.sh`'s own output prints the exact command.

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

## 📡 Adding Channels

**Channels are no longer standalone `setup/add-*.sh` scripts** — a recent upstream NanoClaw change moved every channel (Telegram, WhatsApp, Discord, Slack, Signal, Teams, iMessage) out of trunk entirely ("NanoClaw doesn't ship channels in trunk", per the skills' own docs) and into Claude Code skills that pull the adapter code in on demand. If you've seen older instructions (or an older version of this README) telling you to `bash setup/add-telegram.sh`, that script genuinely no longer exists — this isn't a bug in your install.

**Current procedure** — same interactive session as above:

```bash
docker exec -it nanoclaw-mnemon bash -lc "cd \$NANOCLAW_INSTALL_PATH && claude"
```

Then, inside that session, run the skill for whichever channel you want: `/add-telegram`, `/add-whatsapp`, `/add-discord`, `/add-slack`, `/add-signal`, `/add-teams`. (iMessage isn't offered in container mode regardless — see "Deployment Modes" above.) Each one walks you through it interactively:

1. Copies in that channel's adapter code and installs its pinned dependency.
2. Asks for whatever credential that channel needs (e.g. Telegram: create a bot via **@BotFather**, paste the token it gives you).
3. Restarts the service automatically so the new adapter loads.
4. Runs a pairing/linking handshake so the service knows which chat to treat as yours (Telegram/Discord: a one-time code you send back to the bot; WhatsApp: a QR code or pairing code, same as linking a new device).

Once pairing completes, that channel is live. See each skill's own troubleshooting section (visible in the session's own output while it runs) if a step fails.

---

## 💬 Talking to NanoClaw via Terminal (No Channel Needed)

NanoClaw ships a genuine, always-on **CLI channel** — zero credentials, no Telegram/WhatsApp/Discord pairing needed at all, found directly in its own source (`src/channels/cli.ts`):

```bash
docker exec -it nanoclaw-mnemon bash -lc "cd \$NANOCLAW_INSTALL_PATH && pnpm run chat"
```

Opens a live, interactive terminal chat session against a local Unix socket (`data/cli.sock`) the daemon always listens on — routes through the exact same message pipeline as any other channel (mnemon, hooks, everything works identically).

A few things worth knowing:

- **Single-client**: only one terminal can be connected at a time — opening a second `pnpm run chat` session kicks the first one off with a "superseded" notice.
- **Which group it talks to**: by default, whichever agent group the CLI channel is currently wired to — not automatically the same group your Telegram (or other channel) conversation uses. If nothing's wired yet, `/new-setup`'s `cli-agent` step creates a dedicated scratch group for it (folder `cli-with-<your-name>`); otherwise wire it to an existing group via `/manage-channels`, same as any other channel.
- **Trusted by design**: the socket is `chmod 0600` (owner-only), so "connected to the socket" is treated as operator-level trust — this is the same socket the `ncl` CLI itself uses (see "Adding Channels" above and the roles/approvals discussion earlier in this README).

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
| `$NANOCLAW_INSTALL_PATH/models/` | Whisper model file(s), if you've set up transcription (see "Transcribing Audio/Video" above) — untracked by git same as everything else here, so it survives `CLEAN` too; safe to skip backing up since it's just a re-downloadable model file |

> **Fixed bug, worth knowing about if you deployed before this fix**: `CLEAN` used to `rm -rf` the entire install path and re-clone from scratch, destroying `groups/`, `data/`, `store/`, and `.env` right along with it — including any scaffolded wiki. That's since been fixed (`run.sh` now hard-resets NanoClaw's git-tracked source with `git reset --hard` instead of deleting the directory, which by construction never touches the paths above — they're all in NanoClaw's own `.gitignore`, so `.env`/`groups/`/`data/`/`store/`/`dist/` are simply invisible to git operations). If you hit the old behavior and lost data, there's no recovery path here — this note is so it doesn't happen again, not a way to undo it.

The install directory's own NanoClaw source is safe to treat as disposable (`CLEAN` keeps it in sync with upstream); the directories above are the actual state worth backing up separately regardless, since a fixed `CLEAN` is not a substitute for real backups.

---

## 🎛️ Deployment Policies

| Policy | Action |
|--------|--------|
| `FAST` | Start the orchestrator container if stopped; skip if already active. Clones NanoClaw and applies the mnemon patch on first deploy only |
| `STOP` | Stop the orchestrator container (agent containers keep running) |
| `TEARDOWN` | Stop the orchestrator + remove this install's agent containers (scoped by mount path — see "Coexistence" above); data and install path untouched |
| `CLEAN` | Rebuild the orchestrator image, remove this install's agent containers, hard-sync the install path's NanoClaw source to latest upstream (git-tracked files only — `.env`/`groups/`/`data/`/`store/`/`dist/` untouched, see "Data Directories" above), reapply the mnemon patch, rebuild and restart if this was an existing install (skips the wizard entirely — it only ever runs when `dist/index.js` doesn't exist yet) |
| `INFO` | List data directories with sizes and useful commands (scrollable via `less` in an interactive terminal) |
| `WIPE` | Delete `groups/` and `data/` only (install dir preserved) |

---

## ⬆️ Upgrading NanoClaw Without Redoing Setup

Two different things can look like "upgrading" — worth being precise about which is which, though as of the `CLEAN` fix above, neither one forces you to redo setup on an existing install anymore:

- **`CLEAN` hard-syncs NanoClaw's source to latest upstream** (`git fetch` + `git reset --hard @{u}`, replacing an earlier version that `rm -rf`'d and re-cloned the whole install path — see the fixed-bug callout under "Data Directories" above), then reapplies pi-bootstrap's own patches (mnemon, media-tools, the OrbStack gateway fix, the nohup-autostart fix) to that tree, and rebuilds/restarts if this was an existing install. It's still the mechanism for pi-bootstrap's own patch maintenance (a `MNEMON_VERSION` bump, a fix to `run.sh` itself), but you can now also reach for it as a general "get me on latest" button — it no longer discards your groups, data, credentials, or wiki, and no longer forces the wizard to run again on an existing install. What it does *not* do: preserve any manual edits you made directly inside the NanoClaw checkout yourself — `reset --hard` discards those, since it forces the tree to exactly match upstream's latest commit.
- **NanoClaw's own `/update-nanoclaw` skill is the more careful upgrade path**, for when you specifically want that carefulness: run it from an interactive Claude Code session against the orchestrator (see "Launching Claude CLI Directly" above). It fetches upstream changes, creates a backup branch + tag first, shows a diff preview before touching anything, then merges/cherry-picks/rebases them into your *existing* checkout and validates the result (`pnpm run build`/`pnpm test`) — which matters if you've made local changes inside the checkout you want kept, or just want to review what's changing before it lands.

**In short**: both are now safe to run without losing your setup. `CLEAN` is the "just get me on latest, I don't need to review it" button (and remains the one to reach for after a `MNEMON_VERSION` bump or a `run.sh` change); `/update-nanoclaw` is the "show me a diff first, and don't discard any local edits" button. Pick based on how much you want to review, not out of fear of losing anything — that fear was legitimate before the fix above, it no longer is.

> **Confirmed end-to-end**: a real `CLEAN` run against an existing install with real data — data survived, and the wizard was correctly skipped in favor of an in-place rebuild+restart.

> **Fixed bug, worth knowing about if you deployed before this fix**: "rebuilds ... if this was an existing install" above used to only mean NanoClaw's own orchestrator (`pnpm run build` — a plain `tsc` compile of the host-side TS). It never rebuilt the **agent-sandbox Docker image** (`nanoclaw-agent-v2-<slug>:latest`, built from `container/Dockerfile`) — a completely separate artifact that's what every group's agent containers actually run from. That meant `apply_mnemon_patch`/`apply_media_tools_patch`'s own edits to `container/Dockerfile` sat there unused on any install that already existed before those patches were added — a fresh install's wizard bakes them in during its one-time first build, but `CLEAN` on an existing install never re-triggered that build at all. Caught this via a live report: an agent had no `yt-dlp`/`ffmpeg`/`whisper-cli` available months after the media-tools patch shipped, and had to improvise a workaround that (per "Where Can an Agent Actually Write Persistent Data?" above) couldn't survive a respawn either, since none of the locations it used were one of the three persistent mounts. `run.sh`'s `CLEAN` path now also calls NanoClaw's own `container/build.sh` (the same entry point `setup/auto.ts` itself uses when it needs to rebuild post-container-step) right after the orchestrator rebuild, so the patched Dockerfile actually gets built — the next agent container any group spawns just picks up whatever that image tag now resolves to, no further restart needed since agent containers are already ephemeral, spawned fresh per session. **If you deployed before this fix, one `CLEAN` run now is what actually bakes in `yt-dlp`/`ffmpeg`/`whisper-cli` for the first time** — everything up to now was running on the plain upstream image regardless of what the Dockerfile patch said.

> **Fixed bug, was a known gotcha — `CLEAN` used to silently strip any channel/provider skill's wiring.** NanoClaw's Claude Code skills (`/add-telegram`, `/add-whatsapp`, `/add-discord`, `/add-ollama-provider`, etc.) install themselves by copying in new **untracked** source files (e.g. `src/channels/telegram.ts`) *and* editing existing **tracked** trunk files — a self-registration import appended to `src/channels/index.ts`, a new dependency line in `package.json` (and `pnpm-lock.yaml`, if the skill's own installer ran `pnpm install` afterward). `git reset --hard @{u}` (what `CLEAN` runs above) only discards uncommitted changes to tracked files — it can't touch the untracked new files at all, so they were left behind looking completely intact, while the import/dependency edits that actually wired them in got silently reverted. The result: the channel looked fully installed on disk, but never loaded — no error, no warning, nothing in the logs, `registerChannelAdapter(...)` for that channel simply never ran again. Confirmed against a real deploy: Telegram went completely silent after a `CLEAN`, root-caused by exactly this (`src/channels/index.ts`'s own `import './telegram.js'` line, and `@chat-adapter/telegram` in `package.json`, both reverted; every `telegram*.ts` file still present).
>
> **Now auto-preserved**: `run.sh` snapshots any locally-modified tracked files (`git status --porcelain` filtered to non-untracked entries) as a patch right before the reset, then tries to reapply that patch afterward. In the common case — nothing upstream touched the same lines — this restores the channel/provider wiring automatically, no manual step needed. Verified directly (a throwaway repo simulating this exact scenario) that the reapply is clean when upstream changes an unrelated file, and cleanly falls back rather than corrupting anything when upstream genuinely touches the same lines: if the patch doesn't apply, `run.sh` says so, tells you which files, and leaves the saved patch on disk at a printed path — re-run the relevant channel/provider skill (e.g. `/add-telegram` again) in that case to restore the wiring by hand. If you have more than one channel/provider installed, the warning lists every affected file, not just one.

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
docker exec -it nanoclaw-mnemon bash -lc "cd \$NANOCLAW_INSTALL_PATH && claude"
# then, inside that session: /add-whatsapp, /add-telegram, /add-discord, etc.
# (channels aren't shipped as setup/add-*.sh scripts anymore — see "Adding Channels" below)
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

# Open an interactive shell instead of prefixing every command with docker exec
docker exec -it nanoclaw-mnemon bash

# Chat with NanoClaw directly from a terminal, no channel needed (see
# "Talking to NanoClaw via Terminal" above)
docker exec -it nanoclaw-mnemon bash -lc "cd \$NANOCLAW_INSTALL_PATH && pnpm run chat"

# Transcribe a video (see "Transcribing Audio/Video" above) — run these inside
# the interactive shell above, or prefix each with docker exec -it ... bash -lc
yt-dlp -x --audio-format wav -o audio.%(ext)s "<video-url>"
ffmpeg -i audio.wav -ar 16000 -ac 1 audio-16k.wav
whisper-cli -m "$NANOCLAW_INSTALL_PATH/models/ggml-base.bin" -f audio-16k.wav -otxt -of transcript

# Scaffold a Karpathy LLM Wiki for one group (see "Optional: Karpathy LLM Wiki" above)
./scripts/scaffold-wiki.sh <group-folder>

# Re-run mnemon setup for one group immediately, no chat message needed
# (see "Mnemon Integration" above) — finds/prompts for the group for you
./scripts/reload-mnemon.sh

# Launch an interactive Claude Code session against the orchestrator's own
# checkout — run skills (/add-karpathy-llm-wiki, /add-mnemon), or just ask
# Claude something directly (see "Launching Claude CLI Directly" above)
docker exec -it nanoclaw-mnemon bash -lc "cd \$NANOCLAW_INSTALL_PATH && claude"

# List every skill NanoClaw ships (or type `/` inside an interactive claude
# session for the same list with descriptions and autocomplete)
docker exec nanoclaw-mnemon ls "$NANOCLAW_INSTALL_PATH/.claude/skills/"
```

NanoClaw itself still has no web UI of its own (see the plain `nanoclaw` environment's README) — there's no `http://<host-ip>:3081` to visit unless you've separately added its optional `/add-dashboard` skill. Want a browser chat UI for Ollama? See the standalone `chat-frontends` environment instead — this one doesn't bundle one.

---

## What's Verified vs What Isn't

Verified directly against a real deploy, not assumed:
- The mnemon patch's exact text output, byte-for-byte, against the *actual current* `container/Dockerfile` and `container/entrypoint.sh` fetched live from `nanocoai/nanoclaw` — both insertions land exactly where and as the upstream skill file specifies.
- Idempotency — reapplying the patch against already-patched files correctly detects and skips both steps, no duplication.
- The full `FAST`/`CLEAN` control flow end-to-end, including a real `git clone`, real patch application, real `docker build`/`run`/mount/port sequence, the interactive `nanoclaw.sh` wizard running to completion inside a real container (Anthropic OAuth sign-in, root warning, Telegram channel pairing), and a real chat message getting a real model response.
- The cross-environment agent-container sweep filtering, against synthetic mount data covering exactly the "both environments deployed at once" collision case.
- Mnemon's own `mnemon embed --status` step, working correctly inside this containerized agent sandbox — including the Ollama install prompt and reachability checks. `ollama_available: true` specifically (i.e. mnemon's embed pipeline actually succeeding end-to-end) was not directly confirmed in this environment's own build/test process — `mnemon embed --status` is exactly how to check it yourself after pulling the embedding model.
- **Two wrong turns before the real fix, all found only by testing against a real live deploy, not by reading docs**: (1) `mnemon setup --target claude-code --yes --global` (this environment's original patched invocation) ran without erroring on every container start, but a real group's own `~/.claude/settings.json` showed only NanoClaw's own memory hooks after real use — no mnemon ones. (2) The first fix for that, bare `mnemon setup --yes` (reasoned from mnemon's own README, which shows no `--target`/`--global` for its Claude Code section specifically, unlike every other integration it documents), turned out to be wrong too — confirmed by running `mnemon setup` interactively inside a real agent-sandbox container: it auto-detects Claude Code correctly and *does* write hooks, but to a project-local `.claude/settings.json` relative to entrypoint.sh's own working directory (`/workspace/group`), not the global `~/.claude/settings.json` NanoClaw actually bind-mounts and Claude Code actually reads. (3) `mnemon setup --yes --global` (no `--target claude-code`) is the actual fix — confirmed twice over on a real Mac deploy: first live inside the agent-sandbox container by hand, then end-to-end after a fresh `CLEAN` redeploy, where a real group's `~/.claude/settings.json` came back with mnemon's hooks present alongside NanoClaw's own. `./scripts/reload-mnemon.sh`'s no-argument group auto-discovery (queries `data/v2.db`'s `agent_groups` table, auto-picks or prompts) was also confirmed working against that same real install. This environment's own docs are not a substitute for testing the actual live behavior of a third-party tool, even when those docs seem authoritative.
- Several genuine, non-obvious bugs found and fixed only by testing against a real OrbStack/macOS deploy rather than synthetic stubs — see the git history for `run.sh`, `patch-host-gateway.cjs`, and `patch-nohup-autostart.cjs` if you want the full diagnostic trail for any of them: NanoClaw's own nohup-fallback service-start step (writes but never runs its own wrapper), `systemctl`-based channel-installer restarts silently no-op'ing (no real systemd in this container), OrbStack's `host.docker.internal`/`host-gateway` resolving to a different address than the one its own port-publishing actually uses, and `/tmp` not being shared between this container and the host (breaking OneCLI's own certificate hand-off to spawned agent containers).
- `CLEAN` no longer wiping `.env`/`groups/`/`data/`/`store/` — confirmed against a real existing install with real data (including a scaffolded wiki): running `CLEAN` no longer destroys any of it, and the setup wizard is correctly skipped in favor of an in-place rebuild+restart.
- Container timezone following the host — confirmed directly against a running container's own `date` output after a fresh container creation.
- Recovery from an install path with no `.git` directory — confirmed against a real one, not a synthetic case: a Time Machine restore had skipped invisible files/directories entirely, leaving all of NanoClaw's own visible source back but no `.git`, which made both `pull` and `reset --hard` fail with `fatal: not a git repository`. The fresh-clone-with-data-preserved fallback correctly recovered it, and the subsequent `CLEAN` left `.env`/`groups/`/`data/`/`store/` untouched.
- `jq` being required by channel skills (`/add-telegram` and presumably every other channel skill that validates a credential via `curl | jq`) — confirmed directly: a real `/add-telegram` run failed at exactly that step with the missing binary, adding it to the Dockerfile and rebuilding let the same skill run past credential validation.
- `CLEAN` never rebuilding the agent-sandbox image for an existing install — confirmed via a live report of an agent with none of the media-tools patch's binaries available months after it shipped. Root-caused to `CLEAN`'s existing-install path only ever rebuilding the orchestrator (`pnpm run build`), never NanoClaw's own separate agent-sandbox Docker image; fixed by also calling `container/build.sh` there.
- The `whisper.cpp` build itself failing outright on arm64 — confirmed against a real build log: Debian bookworm's default GCC 12 hits a known incompatibility in ggml's ARM NEON fp16 codepath (`inlining failed in call to 'always_inline' ... target specific option mismatch`). Fixed by building with `clang` instead, in both the orchestrator's own Dockerfile and the agent-sandbox patch.
- The bundled `yt-dlp` failing outright with `python3: No such file or directory` — confirmed against a real run. The Dockerfile was downloading the plain `yt-dlp` release asset, which despite the "standalone, dependency-free" comment above it is actually a zipimport script (shebang `#!/usr/bin/env python3`) that still needs a system python3 on PATH — this image doesn't have one, by design. Fixed by picking the real self-contained `yt-dlp_linux*` binary via `uname -m` at build time instead — this orchestrator image is built on whatever host runs it (arm64 on a Raspberry Pi or Apple Silicon Mac, amd64 on an Intel Mac via OrbStack/Docker Desktop), so a single hardcoded asset would only have been correct for one of them.
- `CLEAN`'s local-edit-preservation step (the one that protects `/add-telegram`-style channel skill wiring from being wiped) silently swallowing fixes to the Dockerfile patches themselves — confirmed against a real `CLEAN` run whose own output showed it happening: the step snapshotted the (stale, pre-fix) `container/Dockerfile`, hard-reset the checkout, then reapplied that stale snapshot verbatim, so `apply_media_tools_patch()`'s idempotency check saw the old broken `yt-dlp` line again immediately and skipped re-patching — meaning the `yt-dlp`/python3 fix above could never actually land via `CLEAN`, and neither could any future fix to either Dockerfile-patching function. Fixed by excluding `container/Dockerfile`/`container/entrypoint.sh` from that snapshot/reapply mechanism, since both are already owned and unconditionally regenerated by `apply_mnemon_patch`/`apply_media_tools_patch` right after the reset.
- The post-deploy summary (`lib/info-lib.sh`, invoked via `lib/run-info.sh`) garbling its own emoji into raw hex-byte escapes (`<F0><9F><93><81>` etc.) when this environment's `run.sh` is invoked directly rather than through `deploy.sh`'s menu — confirmed against a real run's captured output. Root cause: `lib/locale-lib.sh` (which forces a UTF-8 locale specifically to prevent this) is sourced by `deploy.sh` and the other top-level entry scripts, but no per-environment `run.sh` — including this one — ever sourced it, so a shell with no UTF-8 locale already active hits exactly the failure mode `locale-lib.sh`'s own header comment describes. Fixed by sourcing it early in this environment's `run.sh`. The same gap exists in every other environment's `run.sh` in this repo (none of them source it either) — not fixed here since it wasn't reproduced against those, but the same one-line fix applies if it comes up.

**Not independently re-verified**: the identical `rm -rf`-based CLEAN data-loss bug and the missing-`.git` recovery fallback were also fixed in the plain `nanoclaw` environment's `run.sh` (both `container` and `host` mode branches), reasoned through against the same upstream `.gitignore` and mirroring the pattern already confirmed above — but not independently tested against a real plain-`nanoclaw` deploy in this session.

**Still not directly confirmed**: that `whisper-cli`/`yt-dlp` actually run correctly end-to-end once the build succeeds (the build itself was the part that failed and got fixed — a successful compile doesn't by itself prove the binary transcribes correctly), and that the agent can genuinely reach a model file placed under a group's own `models/` folder. Worth confirming on your own first successful `CLEAN` after this fix.

**Confirmed working, live, end-to-end**: the agent-improvised rootless path, in both its forms — first `yt-dlp` binary + `ffmpeg-static` + `@xenova/transformers` (WASM) + `wavefile`, then upgraded to a real, native `whisper.cpp` binary (prebuilt release + a manually-extracted `libgomp` `.deb`) — all inside `/workspace/agent`. A real agent downloaded a real GGML model and produced a real transcription with genuine `whisper.cpp`, independent of anything this repo builds. The persistence claim (bind-mounted, survives respawns and agent-image rebuilds, lost only if the group's own folder is wiped) is verified directly against `container-runner.ts`'s own mount logic, not just taken on faith.

Same caveat as the plain `nanoclaw` environment: this covers what's been tested, not a guarantee against everything upstream might change — treat your own first deploy as the real test, and see `MANUAL-STEPS.md` if you ever want to understand or reproduce any of this by hand.

---

## 📚 Further Reading

- **NanoClaw** — [nanocoai/nanoclaw](https://github.com/nanocoai/nanoclaw): the orchestrator and per-group agent sandbox this environment wraps. Its own `.claude/skills/` directory documents every skill referenced above (`/add-mnemon`, `/add-karpathy-llm-wiki`, `/add-telegram`, `/add-ollama-tool`, `/add-ollama-provider`, `/add-dashboard`, and more).
- **Claude Code** — [code.claude.com/docs](https://code.claude.com/docs): the CLI/SDK NanoClaw's agent containers run on — slash commands, skills, hooks, MCP servers, and the OAuth/subscription sign-in flow covered above.
- **Mnemon** — [mnemon-dev/mnemon](https://github.com/mnemon-dev/mnemon): the persistent-memory tool patched into the agent sandbox here. Its own `docs/USAGE.md` has the full CLI reference (`remember`, `recall`, `link`, `forget`, `gc`, `embed --status`, `embed --all`) and `docs/design/` covers the four-graph model.
- **Ollama** — [ollama.com](https://ollama.com): the optional local inference server mnemon's hybrid recall uses purely for embeddings, never for chat (see "Verifying Ollama & Mnemon" above). [ollama.com/download](https://ollama.com/download) for manual installs; [ollama.com/library](https://ollama.com/library) for browsing models beyond the default `nomic-embed-text`.
- **Karpathy's LLM Wiki pattern** — [the original gist](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f): the source pattern `/add-karpathy-llm-wiki` implements. `GIST-PARITY.md` in this directory compares this environment's implementation against it and five other independent implementations of the same pattern.
- **The gist this environment follows** — [VivianBalakrishnan's gist](https://gist.github.com/VivianBalakrishnan/a7d4eec3833baee4971a0ee54b08f322): NanoClaw + mnemon + local embeddings + wiki + Obsidian sync as a "second brain," with the credibility caveat discussed at the top of this README.
