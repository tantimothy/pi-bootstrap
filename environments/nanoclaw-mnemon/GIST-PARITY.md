# Gist Parity: What's Here, What's Missing, How to Get It

The [VivianBalakrishnan gist](https://gist.github.com/VivianBalakrishnan/a7d4eec3833baee4971a0ee54b08f322) this environment follows combines five pieces. Here's the status of each, verified against the actual upstream source (not assumed), and exactly what's needed to close each gap.

| Component | Status | Automated in this environment? |
|---|---|---|
| Core NanoClaw (channels, per-group agent containers) | ✅ Have | Yes — `run.sh` clones and runs it |
| Persistent graph memory (mnemon) | ✅ Have | Yes — `apply_mnemon_patch()` in `run.sh`, byte-verified |
| Wiki knowledge base (Karpathy LLM Wiki pattern) | 🟡 Partial | Mechanical half only (`scaffold-wiki.sh`); domain design is interactive by upstream design |
| Voice transcription — OpenAI Whisper API | ❌ Not built | No |
| Voice transcription — local whisper.cpp | ❌ Not built | No |
| Local vector embeddings (Ollama + `nomic-embed-text`) | ❌ Not built — model + connectivity pinned down, architecture proposed below, no code yet | No |
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

**There is nothing to fetch here.** I checked every skill location that exists: the main `nanocoai/nanoclaw` repo's 48+ bundled skills, the official marketplace (`nanocoai/nanoclaw-skills`, full 24-skill catalog enumerated), and the community-skills repo turned up in search results — no embeddings, vector-memory, or semantic-search skill exists anywhere in NanoClaw's ecosystem. `/add-ollama-tool` is related but not a substitute — it wires an Ollama-backed *chat/generate* tool into the agent's MCP config, with no embeddings-specific tool (only `ollama_list_models`, `ollama_generate`, and admin tools for pull/delete/show/list-running).

This piece of the gist is the one place where "how to get it" has no upstream answer — it's original, unpublished work by the gist's author. Two things are pinned down (model choice, connectivity pattern); the rest is a genuine design task.

**Pinned down:**
- **Model**: [`nomic-ai/nomic-embed-text-v1.5`](https://huggingface.co/nomic-ai/nomic-embed-text-v1.5), pulled via `ollama pull nomic-embed-text` — first-class entry in Ollama's own model library, no manual GGUF conversion needed. 137M params, 8192-token context, Matryoshka-truncatable 768→64 dimensions, Apache 2.0. Requires task-prefixed input (`search_query: `/`search_document: `) — matters directly for whatever ingestion/query code gets written, since a prefix mismatch degrades retrieval silently rather than erroring.
- **Connectivity**: `/add-ollama-tool`'s own `SKILL.md` (fetched and read in full) establishes the pattern to reuse rather than reinvent — `OLLAMA_HOST` env var, default `http://host.docker.internal:11434` with a `localhost` fallback, forwarded into agent containers via `ollamaEnvArgs()` in `container-runner.ts`. Ollama itself runs as a host-level (or otherwise externally reachable) daemon, never inside a per-message agent container — embeddings should follow the exact same reachability assumption, not invent a second one.

**Still open — a proposed design, not a spec:**

1. **Scope it to the wiki, not a general-purpose memory layer.** The gist's embeddings piece exists alongside the wiki, and Karpathy's own pattern doc is explicit that a plain `index.md` "works surprisingly well at moderate scale... avoiding embedding-based RAG infrastructure needs" until a wiki outgrows that. Recommendation: embeddings index the wiki's `wiki/*.md` pages specifically (not raw messages, not mnemon's graph) — gives embeddings a clear, bounded job (fuzzy semantic search over wiki content once `index.md` alone stops being enough) instead of becoming a second, competing memory system.
2. **Trigger**: wire it into the wiki's own ingest step rather than a blanket "embed everything" hook. Concretely, the tailored `container/skills/wiki/SKILL.md` that `/add-karpathy-llm-wiki` generates (Step 3b) is the natural place to add "after writing/updating a wiki page, call the indexing tool" as one more instruction — consistent with how that skill already tells the agent to update `index.md`/`log.md` on every ingest.
3. **New MCP tools, mirroring `/add-ollama-tool`'s own registration pattern** (`index.ts` for registration, `container-runner.ts` for env forwarding, same `OLLAMA_HOST`): expose two high-level verbs, not a raw embedding call — `index_wiki_page` (embed + upsert one page's chunks) and `search_wiki` (embed the query, return top-k matching chunks with page references). Raw embedding vectors are useless to an LLM directly; the tool surface should hide them entirely, the same way `ollama_generate` hides the raw completion API shape.
4. **Storage**: a per-group SQLite file (`groups/<group>/wiki/.embeddings.db`), matching the existing pattern of scoping wiki data to `groups/<group>/wiki/`. `sqlite-vec` (a SQLite extension for vector similarity search) is the natural choice — zero separate service to run, fits a single-file-per-group model the same way mnemon's own storage is scoped per group. A pure-JS brute-force cosine-similarity fallback (no native extension) is viable too at the corpus sizes a personal wiki actually reaches (hundreds to low thousands of chunks) — worth prototyping both before committing, since `sqlite-vec` adds a native dependency to the agent-runner's Bun build that the fallback avoids entirely.
5. **Relationship to mnemon**: complementary, not overlapping, and this is worth being explicit about since it's easy to conflate — mnemon stays the graph memory (temporal/entity/causal/semantic edges over the conversation itself); embeddings would only ever cover the separate wiki corpus. Mnemon's own docs don't mention embeddings, and nothing above touches mnemon's storage or hooks.

If you want this built, it's a genuine implementation task on top of this proposal, not a patch to apply.

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

Two of five pieces are fully automated and verified (core NanoClaw, mnemon). One is half-automated with the interactive part staying manual by upstream design (wiki). Two require real new work: voice transcription is a well-specified but nontrivial build (known upstream skills, cross-distro translation needed); embeddings had no spec at all — model choice and connectivity are now pinned down and a concrete architecture is proposed above, but none of it is implemented yet. Sync is intentionally left as "point your own tool at an existing folder."

Let me know which of the remaining pieces you want built — voice transcription (I can start with the git-merge feasibility check against current `main`) or embeddings (implement the proposal above: the two MCP tools, the per-group SQLite store, and the wiki-skill wiring).
