# Gist Parity: What's Here, What's Missing, How to Get It

The [VivianBalakrishnan gist](https://gist.github.com/VivianBalakrishnan/a7d4eec3833baee4971a0ee54b08f322) this environment follows combines five pieces. Here's the status of each, verified against the actual upstream source (not assumed), and exactly what's needed to close each gap.

| Component | Status | Automated in this environment? |
|---|---|---|
| Core NanoClaw (channels, per-group agent containers) | ✅ Have | Yes — `run.sh` clones and runs it |
| Persistent graph memory (mnemon) | ✅ Have | Yes — `apply_mnemon_patch()` in `run.sh`, byte-verified |
| Wiki knowledge base (Karpathy LLM Wiki pattern) | 🟡 Partial | Mechanical half only (`scaffold-wiki.sh`); domain design is interactive by upstream design; **disconnected from mnemon — see "Gap: Wiki ≠ Downstream of Mnemon" below** |
| Voice transcription — OpenAI Whisper API | ❌ Not built | No |
| Voice transcription — local whisper.cpp | ❌ Not built | No |
| Local vector embeddings (Ollama + `nomic-embed-text`) | ✅ Have — opt-in | Yes — `apply_mnemon_patch()` bakes `MNEMON_EMBED_ENDPOINT`/`MNEMON_EMBED_MODEL` into the Dockerfile when set in `.env` (unset by default; requires a reachable Ollama daemon and `CLEAN` to activate) |
| Obsidian/iCloud/rsync personal sync | ❌ Out of scope by design | Inherently personal, not automatable |

---

## 🎙️ Voice Transcription (OpenAI Whisper → local whisper.cpp)

Two chained official skills: `/add-voice-transcription` (OpenAI API, prerequisite) then `/use-local-whisper` (swaps to on-device). I fetched both `SKILL.md` files and the actual code each one merges in, to see exactly what's needed rather than guess.

**What's needed:**

1. **WhatsApp channel already added.** Both skills only support WhatsApp (`isVoiceMessage` checks Baileys' `ptt` flag, WhatsApp-specific). Get this via `docker exec -it nanoclaw-mnemon bash -lc "cd $NANOCLAW_INSTALL_PATH && bash setup/add-whatsapp.sh"` (interactive — QR/pairing code scan).
2. **A temporary, funded OpenAI API key.** `/add-voice-transcription`'s own Phase 4 verify step tests a real voice note transcribing through OpenAI's Whisper API before you're meant to move on — so you need a working key at least long enough to pass that gate, even though the code it installs gets fully replaced by the next skill. Cost is trivial (~$0.006/min of audio, one test note).
3. **Two chained git-merges from a separate, old-org fork**: both skills pull from `https://github.com/qwibitai/nanoclaw-whatsapp.git` (note: `qwibitai`, not `nanocoai` — this WhatsApp-channel fork apparently never moved when the main repo transferred owners) — `git fetch whatsapp skill/voice-transcription && git merge ...`, then later `git fetch whatsapp skill/local-whisper && git merge ...`. I pulled the actual `src/transcription.ts` off the `skill/local-whisper` branch directly: it fully replaces the OpenAI call — `execFile('whisper-cli', ['-m', WHISPER_MODEL, '-f', tmpWav, ...])` after an `ffmpeg` resample to 16kHz mono WAV, no OpenAI reference left at all. This is a real git merge of a moving branch, not a fixed text insertion at a known anchor — meaningfully less deterministic to automate/verify than mnemon's patch was, and worth re-diffing against upstream before trusting blindly if those branches change.
4. **`whisper-cpp` (the `whisper-cli` binary) and `ffmpeg` installed where the code actually runs.** This is the key architectural mismatch: `transcription.ts` executes inside the **orchestrator** process (it's WhatsApp-channel code, not agent-sandbox code) — and our orchestrator itself runs inside a container (`environments/nanoclaw-mnemon/Dockerfile`), unlike mnemon which patches the *agent* sandbox's own `container/Dockerfile`. So these binaries would need to go into **our own orchestrator Dockerfile**, not NanoClaw's. The upstream skill assumes `brew install whisper-cpp ffmpeg` on host macOS — Debian-slim (our orchestrator's base image) needs a different install path: `apt-get install -y ffmpeg` works directly; `whisper-cli` has no Debian package, so it'd need building from the [whisper.cpp source](https://github.com/ggml-org/whisper.cpp) or downloading a prebuilt Linux binary from its releases, if one exists for the target arch.
5. **A GGML model file** (`data/models/ggml-base.bin`, ~148MB) downloaded into the install path — straightforward, one `curl` from Hugging Face.
6. **No launchd translation needed** — the upstream skill's Phase 3 is all about macOS launchd PATH/`launchctl kickstart`, irrelevant here since we install the binaries at image-build time (already on `PATH` inside the container) and restart via `docker restart nanoclaw-mnemon`, not launchd.

**Net assessment**: buildable, but step 3's git-merge-from-a-moving-fork and step 4's cross-distro binary translation make this a real engineering task, not a drop-in patch — closer to a half-day of careful work (fetch current branch state, verify the merge applies cleanly against current `nanocoai/nanoclaw` main, find/build a Linux `whisper-cli`, wire a new `apply_voice_transcription_patch()` into `run.sh` alongside the mnemon one) than the few hours mnemon took.

---

## 🧠 Local Vector Embeddings (Ollama + `nomic-embed-text`)

**Corrected twice now — this second correction reverses most of the first.** Two passes on this section, both worth showing rather than silently overwriting:

**Pass 1** (re-fetched the gist directly): found the real flow is raw sources → mnemon → wiki, with embeddings inside mnemon's own retrieval, not scoped to the wiki as originally proposed. Still accurate.

**Pass 2** (read further into `mnemon-dev/mnemon`'s own README than before): Pass 1 also concluded the gist's "mnemon" must be a custom fork or wrapper, since "mnemon's own docs never mention embeddings." **That conclusion was wrong** — it was based on an incomplete read of the same README. The actual text, further down than previously checked:

> **Intent-aware recall** — graph traversal + optional vector search (RRF fusion), enabled by default for all queries
> **Optional embeddings** — works fully without Ollama; add local Ollama for enhanced vector+keyword hybrid search

And from the configuration table:

| Environment Variable | Default | Description |
|---|---|---|
| `MNEMON_EMBED_ENDPOINT` | `http://localhost:11434` | Ollama API endpoint |
| `MNEMON_EMBED_MODEL` | `nomic-embed-text` | Embedding model name |

**Stock `mnemon-dev/mnemon` has Ollama + `nomic-embed-text` embeddings built in, as an optional flag, with `nomic-embed-text` as the literal default model name.** The gist's author didn't build a custom semantic layer — they just pointed stock mnemon (installed exactly as `/add-mnemon` installs it, which is exactly what this environment's `apply_mnemon_patch()` does) at a reachable Ollama daemon. `docs/DEPLOYMENT.md` confirms the container-networking side too: `MNEMON_EMBED_ENDPOINT=http://host.docker.internal:11434` for Docker Desktop — the identical `host.docker.internal` pattern already used for `/add-ollama-tool`'s `OLLAMA_HOST`.

**Built — this is no longer a proposal.** `apply_mnemon_patch()` now bakes `MNEMON_EMBED_ENDPOINT`/`MNEMON_EMBED_MODEL` (both opt-in, unset by default) into `container/Dockerfile` as plain `ENV` lines, right alongside the existing `MNEMON_DATA_DIR` line — the same idempotency check (`grep -q 'MNEMON_VERSION'`) covers all three, so nothing new to verify separately there. Confirmed with a stub Dockerfile against the real anchor text: unset produces the same output as before (a harmless blank line, no embed vars), set produces both `ENV` lines correctly, and re-running with the same `.env` doesn't duplicate either.

**Why this is baked into the image rather than forwarded per-spawn** like `/add-ollama-tool`'s `OLLAMA_HOST`: that mechanism lives in `container-runner.ts` (`ollamaEnvArgs()`), which this environment doesn't patch — mnemon runs inside NanoClaw's own per-group containers, spawned by NanoClaw's own orchestrator code, so an image-level `ENV` is the only hook available without touching NanoClaw's TypeScript source. Functionally equivalent for a single-daemon setup; the tradeoff is it can't vary per-group the way `container.json`-based config could, which wasn't a requirement here.

**To actually use it**: set `MNEMON_EMBED_ENDPOINT` in `.env` (see `.env.example`'s own commented-out stub), then `CLEAN` redeploy — same activation path as bumping `MNEMON_VERSION`. As of this update, getting Ollama itself ready is *also* automated: `run.sh`'s new `ensure_ollama_ready()` checks whether the configured endpoint is reachable, and — only for a local address (`host.docker.internal`/`localhost`/`127.0.0.1`; a remote endpoint is left entirely alone) — offers to install Ollama (Homebrew on macOS, the official installer on Linux, gated behind an explicit y/N confirmation prompt), starts it if installed but not running, and pulls the configured model if it's missing. Verified against stub `curl`/`brew`/`ollama`/`uname` binaries covering: opt-out (silent no-op), already-reachable-with-model-present, local-and-unreachable-with-decline, remote-and-unreachable, confirmed-install, and already-installed-but-stopped — every failure path warns and lets the rest of the deploy continue rather than aborting, since mnemon's own fallback (graph-only recall) is a legitimate, documented behavior, not an error state.

**Model alternatives to the default**, from Ollama's actual embedding-model listing (pasted directly by the user, not fetched — `ollama.com` is blocked at this session's network-policy level, same as `huggingface.co`; treat the download-count figures below as a snapshot, not something re-verified here):

| Model | Sizes | Downloads | Why you'd pick it over the default |
|---|---|---|---|
| `nomic-embed-text` | 137M | 78M | The default — mnemon's own, English-only, zero config needed |
| `nomic-embed-text-v2-moe` | — | 478.6K | Multilingual upgrade *within the default's own family* (MoE architecture) |
| `bge-m3` | 567M | 5.1M | Multilingual + hybrid dense/sparse/multi-vector retrieval in one model — most capable option here, not just multilingual |
| `snowflake-arctic-embed2` | 568M | 422.5K | Multilingual added over v1 "without sacrificing English performance" — v1 itself (22m/33m/110m/137m/335m tags, 3.1M downloads) stays English-only |
| `mxbai-embed-large` | 335M | 12.4M | Best general-purpose English quality-for-size; highest adoption after the default itself |
| `all-minilm` | 22m/33m | 3.2M | Smallest/fastest by a wide margin — the pick if a Pi can't spare resources for anything bigger, at a real quality cost |
| `qwen3-embedding` | 0.6b/4b/8b | 2.4M | LLM-scale embedding models (Alibaba's Qwen3) — a different tier entirely; the 8B variant isn't realistic on a Pi |
| `embeddinggemma` | 300M | 1.4M | Google's entry in the same general-purpose tier as `mxbai-embed-large`/`bge-large` |
| `granite-embedding` | 30m (English) / 278m (multilingual) | 337.7K | IBM's family — cleanly splits English-only-small vs. multilingual-larger |

Net guidance, given all of the above: the only two reasons to override `MNEMON_EMBED_MODEL` from its default are multilingual support (`bge-m3`, `nomic-embed-text-v2-moe`, or `snowflake-arctic-embed2` — genuinely comparable options, not one obviously best) or hardware constraints (`all-minilm`, or Snowflake's own small tags). Everything else in the table is a lateral move in the same general-purpose English tier the default already occupies.

---

## 🔗 Gap: The Wiki Isn't Downstream of Mnemon (Unlike the Gist)

Surfaced answering a direct question, worth tracking explicitly rather than leaving implicit in the two sections above.

**What the gist actually does** (quoted already in the embeddings section above): raw sources → **mnemon** (extracts discrete facts) → **wiki** (synthesizes those facts into markdown pages). The wiki never reads raw sources directly — it's a compiled view of what mnemon already extracted.

**What this environment actually does**: two independent features that don't talk to each other.

- `apply_mnemon_patch()` + `ensure_ollama_ready()` — mnemon's own graph memory (plus optional embeddings), operating on whatever the agent decides to `remember`/`link` during conversation. Fully automated, covered above.
- `scaffold-wiki.sh` + NanoClaw's own `/add-karpathy-llm-wiki` skill — compiles wiki pages **straight from whatever you drop in a group's `sources/` folder**, with no mnemon involvement at all. This is a faithful implementation of NanoClaw's own skill (verified against its actual `SKILL.md` — see the README's "Optional: Karpathy LLM Wiki" section), just not a faithful implementation of *the gist's* wiki, which is fed by mnemon's facts rather than raw sources.

Two consequences worth being explicit about:
1. **Naming mismatch on top of the architectural one**: this environment's scaffold uses `sources/` (NanoClaw's skill's own term); the gist and Karpathy's original idea file both say `raw/`. Same concept, different name — not itself a functional gap, but worth knowing if you're comparing directory listings against the gist's own description.
2. **If you run both features on the same install**, you get mnemon's memory and a wiki that happens to exist in the same `groups/<group>/` tree, not a pipeline — nothing writes mnemon's facts into `sources/`, and nothing feeds the wiki compiler from `recall` output. Building the actual gist-accurate connection would mean either (a) having the wiki-compiling skill call `mnemon recall` as a source instead of (or alongside) `sources/` files, or (b) writing mnemon's `remember`/`link` output back out to `sources/` as it happens, so the existing wiki skill picks it up unmodified. Neither is built; this is a real, unstarted gap, not a config flag like the embeddings one turned out to be.

**Not currently planned to be closed** — flagging status quo, not committing to build it. Revisit if it becomes a priority.

---

## 📚 The Karpathy-Pattern Ecosystem (it's not one project)

Surfaced while fact-checking an unrelated question, then widened deliberately — "llm-wiki" turns out to be a pattern name at least half a dozen people have implemented independently, all crediting the same [Karpathy gist](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f), none built on each other. `/add-karpathy-llm-wiki` (the NanoClaw skill this environment scaffolds against) is one more entry in that same list, not a variant of any of these — it's the only one that lives inside `nanocoai/nanoclaw` itself and produces a NanoClaw-specific structure per conversation *group*.

Five external implementations checked directly (READMEs fetched and read in full, not summarized secondhand):

| Project | Distribution | Primary input | Search mechanism | Notable extras |
|---|---|---|---|---|
| [`nvk/llm-wiki`](https://github.com/nvk/llm-wiki) | Claude Code / Codex / OpenCode plugin, portable `AGENTS.md` | Curated sources (URLs, files, text) | Index-first navigation; optional `qmd` (BM25+vector) past ~100 articles | Parallel research agents (5/8/10), thesis-driven investigation, archiving, session capture, feedback curation |
| [`praneybehl/llm-wiki-plugin`](https://github.com/praneybehl/llm-wiki-plugin) | Claude Code plugin, or any [agentskills.io](https://agentskills.io)-compatible runtime (Codex, Cursor, Gemini CLI, OpenCode, **OpenClaw**, Pi Agent) | Curated sources | BM25 (`wiki_search.py`, stdlib-only) as fallback past index-summary matching | Widest agent-runtime compatibility table of any of these; explicit degraded-mode notes per runtime |
| [`ussumant/llm-wiki-compiler`](https://github.com/ussumant/llm-wiki-compiler) | Claude Code / Codex plugin | Markdown files **or entire codebases** | None built in; optionally recommends `qmd` (attributed to `jina-ai` here, vs. `tobi` in `nvk`'s README — same tool, inconsistent credit across these projects) past 100+ topics | Codebase mode (architecture/API/decision-record synthesis from source code, not just docs), interactive knowledge-graph visualization |
| [`lucasastorian/llmwiki`](https://github.com/lucasastorian/llmwiki) (Apache 2.0) | **MCP server**, not a slash-command plugin — connects Claude Desktop/Code/Cowork, Codex, or any MCP client | Uploads (PDF/Office/Markdown) + a Chrome extension for web clipping | Local SQLite full-text index, or Postgres+S3 in hosted mode | Full Next.js web app, nightly Claude Routine for autonomous maintenance, local-or-hosted deployment |
| [`Pratiyush/llm-wiki`](https://github.com/Pratiyush/llm-wiki) (MIT) | Standalone CLI + static-site generator | **Your own AI session transcripts** (Claude Code/Codex/Copilot/Cursor/Gemini CLI `.jsonl` logs) — a different data source entirely, not curated documents | None core; optional Ollama backend, but for **LLM-generated summary text**, not embeddings-based retrieval | `llms.txt`-spec AI-consumable exports, confidence scoring, 5-state page lifecycle, 16 lint rules, CI-tested (2651 passing) |

**Cross-cutting finding, independently consistent across all five**: none use vector embeddings as their core retrieval mechanism. Full-text/BM25 search is the standard fallback at scale, with hybrid BM25+vector search (`qmd`) as an *optional* bolt-on two of them recommend, never built in. Five separately-authored projects converging on the same "compiled wiki over embeddings" choice is a stronger signal than any one of their docs saying so alone — this looks like a deliberate, load-bearing design choice in this whole space, not an oversight any of them happened to share.

**The actionable finding for NanoClaw specifically**: `lucasastorian/llmwiki`'s MCP-server model is meaningfully lower-risk to integrate than the four plugin-based options. The other four all depend on Claude Code's plugin-install mechanism working inside NanoClaw's Bun-based agent-runner container — unverified, an open question flagged since the first pass on this. An MCP server sidesteps that entirely: NanoClaw's own `container-runner.ts`/`index.ts` already has a proven MCP-server-registration pattern (verified directly — it's exactly what `/add-ollama-tool` uses). Wiring in an MCP-based wiki tool is the same *kind* of change this codebase already makes, not a new integration surface to validate first.

**Not yet checked**: `nashsu/llm_wiki` (a cross-platform desktop app, per its GitHub description — different distribution model from all of the above) and `doum1004/llmwiki-cli` also turned up in search and haven't been read in depth. Listed for completeness, not evaluated.

**On the Substack article's plugin specifically** (`/llm-wiki:init`/`/llm-wiki:ingest`/`/llm-wiki:export`): checked against all five of the above plus a direct repo-name guess (`doneyli/llm-wiki`, 404) — no match on command naming or a public repo. Most likely the author's own separate, paid-subscriber-only implementation, not publicly verifiable. Its described mechanics ("It is not a vector store") are consistent with the cross-cutting finding above regardless.

---

## 🔀 Related but Different: Routing the Agent's Chat Model to Ollama

Not part of the gist, and **not embeddings** — but came up while researching the embeddings gap above, and worth documenting since it's easy to conflate ("Ollama integration" gets used loosely to mean several unrelated things). These two swap which model *answers the conversation*; neither touches retrieval or memory.

- **[`/add-ollama-provider`](https://github.com/nanocoai/nanoclaw/blob/main/.claude/skills/add-ollama-provider/SKILL.md)** — a real, official skill in the main repo (fetched and read in full). Routes one agent group to a local Ollama model instead of the Anthropic API, by exploiting the fact that Ollama natively speaks the Anthropic `/v1/messages` wire format: it sets `ANTHROPIC_BASE_URL=http://host.docker.internal:11434` and a dummy `ANTHROPIC_API_KEY=ollama` in that group's `container.json`, plus a `model` override in its Claude Code `settings.json`, and optionally blocks `api.anthropic.com` at the container's `/etc/hosts` level so a config drift can't accidentally spend real API credits. No code patch needed on a current install — it only requires two small (idempotency-checked) additions to `ContainerConfig`/`container-runner.ts` if a given install predates those fields.
- **[`dipockdas/nanoclaw-ollama-cloud`](https://github.com/dipockdas/nanoclaw-ollama-cloud)** — real, but third-party (not `nanocoai`-official, found via search under an unrelated owner). Solves a narrower problem: the Claude Agent SDK validates model names/API keys strictly, which breaks if you want *Ollama Cloud* (hosted, not local) models specifically. It runs a local LiteLLM proxy that aliases Ollama Cloud models as Claude models to satisfy that validation, and ships a reference patch to `container-runner.ts` for the Docker networking side. Different mechanism from `/add-ollama-provider` (proxy-based aliasing vs. direct `ANTHROPIC_BASE_URL` redirection) because it's solving for cloud-hosted Ollama, not a local daemon.

Both are genuinely useful if the goal is cutting Anthropic API costs or running fully offline — but they answer "which model talks to the user," not "how does the agent remember/retrieve things," so neither substitutes for the embeddings work above.

---

## 📖 Obsidian / iCloud / rsync Sync

Already covered in the README's "Optional: Karpathy LLM Wiki" section — recapping the concrete options here since they follow directly from what's already scaffolded:

- **Content generation**: `./scaffold-wiki.sh <group-folder>` + a manual `/add-karpathy-llm-wiki` session gets you the actual markdown wiki (`$NANOCLAW_INSTALL_PATH/groups/<group>/wiki/`) — this part is done, see the README.
- **Getting it into Obsidian**: since that directory is already a plain host bind mount (nothing container-internal about it), the simplest path is just opening `$NANOCLAW_INSTALL_PATH/groups/<group>/wiki/` directly as an Obsidian vault on whatever machine runs the orchestrator — zero sync needed if Obsidian runs on the same host.
- **If you want it on another device** (the gist's actual setup — a Mac Mini syncing to the author's own Mac/iPhone): point any generic sync tool at that same host directory — iCloud Drive (symlink the folder into your iCloud Drive location), Syncthing, or a cron'd `rsync`. This is genuinely just "sync a folder," no NanoClaw-specific logic involved — the gist author's version isn't more automatable than any other folder-sync setup, which is why it stays out of scope for pi-bootstrap to script generically.

---

## Summary

Three of five pieces are fully automated and verified now (core NanoClaw, mnemon, and mnemon's optional embeddings — the last of which looked like the hardest gap through two prior passes on this document and turned out to be a built-in config flag). One is half-automated with the interactive part staying manual by upstream design (wiki) — and, tracked separately above, architecturally disconnected from mnemon in a way the gist itself isn't, since NanoClaw's own wiki skill compiles from raw sources rather than from mnemon's facts. A whole ecosystem of external wiki alternatives is documented above too, if you want to look beyond NanoClaw's own skill. Voice transcription is the one piece that's still a genuine, unstarted build (known upstream skills, cross-distro translation needed). Sync is intentionally left as "point your own tool at an existing folder."

Let me know if you want voice transcription started next — begin with the git-merge feasibility check against current `main`.
