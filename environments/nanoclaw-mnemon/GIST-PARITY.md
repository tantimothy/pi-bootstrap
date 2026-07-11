# Gist Parity: What's Here, What's Missing, How to Get It

The [VivianBalakrishnan gist](https://gist.github.com/VivianBalakrishnan/a7d4eec3833baee4971a0ee54b08f322) this environment follows combines five pieces. Here's the status of each, verified against the actual upstream source (not assumed), and exactly what's needed to close each gap.

| Component | Status | Automated in this environment? |
|---|---|---|
| Core NanoClaw (channels, per-group agent containers) | ✅ Have | Yes — `run.sh` clones and runs it |
| Persistent graph memory (mnemon) | ✅ Have | Yes — `apply_mnemon_patch()` in `run.sh`, byte-verified |
| Wiki knowledge base (Karpathy LLM Wiki pattern) | 🟡 Partial | Mechanical half only (`scaffold-wiki.sh`); domain design is interactive by upstream design |
| Voice transcription — OpenAI Whisper API | ❌ Not built | No |
| Voice transcription — local whisper.cpp | ❌ Not built | No |
| Local vector embeddings (Ollama + `nomic-embed-text`) | ❌ Not built — model + connectivity pinned down; two design paths below (gist-accurate, needs mnemon schema investigation, vs. wiki-scoped, lower risk) | No |
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

**Corrected below against the gist's actual text.** An earlier version of this section proposed scoping embeddings to the wiki corpus, treating them as complementary to (separate from) mnemon. Having re-fetched the gist directly rather than working from a paraphrase, that's backwards — here's what it actually describes, quoted:

- Three layers, in order: **raw sources → mnemon → wiki**.
- Mnemon is described as a "custom CLI knowledge graph tool (SQLite + graph traversal)" that extracts and stores "discrete facts, insights, and style preferences" from raw sources.
- **Embeddings live inside mnemon's own retrieval step, not at the wiki layer.** Quoted: the system "uses local vector embeddings (Ollama + nomic-embed-text) for semantic retrieval" to "run a semantic query against the graph using the user's message as input," and "relevant entries are injected as context before the agent responds." Concretely: `nomic-embed-text` embeds the live user message; that vector is compared against embedded mnemon facts; matches get pulled into context.
- The wiki is pure synthesis **downstream of mnemon's facts**, with no embeddings involved at that layer at all: "synthesized markdown narratives compiled from mnemon facts." Karpathy's pattern is credited specifically as inspiration for this synthesis step, not the retrieval step: "the wiki pattern is inspired by [Karpathy's LLM Wiki] concept — extracting structured knowledge from raw sources rather than indexing them whole" — contrasted directly with plain RAG: "RAG retrieves text chunks; mnemon stores synthesised facts as discrete nodes."

**A consequence worth being explicit about**: the gist's "mnemon" is not simply the stock `mnemon-dev/mnemon` binary this environment installs via `/add-mnemon`. The real project's own docs, verified earlier in this work, never mention embeddings — `mnemon-dev/mnemon` is graph-based, not vector-based, full stop. So the gist author appears to have built their own Ollama-based semantic-query layer around mnemon's SQLite storage themselves — genuinely custom work beyond what `/add-mnemon` installs, not a documented mnemon feature. **This environment's own mnemon integration is the stock binary, with no embeddings layer** — matching the gist's actual architecture, not just "some embeddings somewhere," means building that custom layer, and it depends on mnemon's real storage schema, which hasn't been inspected yet (unlike wiki markdown files, which this repo fully controls and has already read).

**Pinned down** (unaffected by the correction above):
- **Model**: [`nomic-ai/nomic-embed-text-v1.5`](https://huggingface.co/nomic-ai/nomic-embed-text-v1.5), pulled via `ollama pull nomic-embed-text` — first-class entry in Ollama's own model library, no manual GGUF conversion needed. 137M params, 8192-token context, Matryoshka-truncatable 768→64 dimensions, Apache 2.0. Requires task-prefixed input (`search_query: `/`search_document: `) — matters directly for whatever ingestion/query code gets written, since a prefix mismatch degrades retrieval silently rather than erroring.
- **Connectivity**: `/add-ollama-tool`'s own `SKILL.md` (fetched and read in full) establishes the pattern to reuse rather than reinvent — `OLLAMA_HOST` env var, default `http://host.docker.internal:11434` with a `localhost` fallback, forwarded into agent containers via `ollamaEnvArgs()` in `container-runner.ts`. Ollama itself runs as a host-level (or otherwise externally reachable) daemon, never inside a per-message agent container — embeddings should follow the exact same reachability assumption, not invent a second one.

**Two design paths, honestly different in difficulty:**

**A. Match the gist's real flow — embeddings query mnemon's facts.**
1. Prerequisite work not yet done: inspect `mnemon-dev/mnemon`'s actual on-disk format (it's SQLite per the gist's description, but the schema — table names, what constitutes a "fact" row, IDs stable enough to key an external index against) hasn't been read. This is a real unknown, not a detail.
2. Two embedding calls, matching the gist's own two phases: **ingestion** — after mnemon writes a new fact (via its `remember`/`link` hooks), embed that fact's text and store the vector keyed to mnemon's own fact ID; **retrieval** — embed the live user message before the agent responds, compare against stored fact vectors, inject top matches as context (mirroring mnemon's own `UserPromptSubmit` hook timing).
3. New MCP tools mirroring `/add-ollama-tool`'s registration pattern, but scoped to mnemon facts rather than wiki pages — e.g. `index_mnemon_fact` / `semantic_recall`.
4. Storage: a side-table or a separate per-group SQLite file keyed by mnemon's fact IDs — depends entirely on what step 1 finds. Could plausibly live alongside mnemon's own data under `/home/node/.claude/mnemon/` inside the agent container (same host bind mount mnemon already uses).
5. **Not a drop-in** — this only works cleanly if this environment's stock `mnemon-dev/mnemon` actually exposes (or can be safely read around) a stable fact ID and stable fact text, which is unverified.

**B. The simpler, previously-proposed alternative — embeddings index the wiki instead.**
Scope embeddings to `wiki/*.md` pages (not mnemon's graph): trigger via the wiki skill's own ingest step, two MCP tools (`index_wiki_page`/`search_wiki`), per-group SQLite (`groups/<group>/wiki/.embeddings.db`, `sqlite-vec` or a pure-JS brute-force fallback). Doesn't match the gist's actual architecture, but doesn't require reverse-engineering mnemon's internals either — plain markdown files this repo already reads and writes. Karpathy's own pattern doc explicitly says a plain `index.md` "works surprisingly well at moderate scale... avoiding embedding-based RAG infrastructure needs" until a wiki outgrows that, so this path has independent justification even setting the gist aside.

If you want this built: path A for gist parity (needs mnemon schema investigation first), path B for a lower-risk build that still delivers local semantic search, just over a different corpus.

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

Two of five pieces are fully automated and verified (core NanoClaw, mnemon — though note mnemon here is the stock binary, without the gist's own embeddings-augmented retrieval layer). One is half-automated with the interactive part staying manual by upstream design (wiki), with `nvk/llm-wiki` documented above as a more complete alternative if you want to look beyond NanoClaw's own skill. Two require real new work: voice transcription is a well-specified but nontrivial build (known upstream skills, cross-distro translation needed); embeddings had no spec at all — model and connectivity are pinned down, and two design paths are proposed above, one matching the gist exactly (harder — needs mnemon's storage schema investigated first) and one lower-risk (wiki-scoped, doesn't need mnemon internals). Sync is intentionally left as "point your own tool at an existing folder."

Let me know what to build next — voice transcription (start with the git-merge feasibility check against current `main`), embeddings path A (start by inspecting mnemon's actual SQLite schema inside a running agent container), or embeddings path B (implement the wiki-scoped MCP tools directly, no schema investigation needed).
