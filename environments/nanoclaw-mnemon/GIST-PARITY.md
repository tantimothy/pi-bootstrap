# Gist Parity: What's Here, What's Missing, How to Get It

The [VivianBalakrishnan gist](https://gist.github.com/VivianBalakrishnan/a7d4eec3833baee4971a0ee54b08f322) this environment follows combines five pieces. Here's the status of each, verified against the actual upstream source (not assumed), and exactly what's needed to close each gap.

| Component | Status | Automated in this environment? |
|---|---|---|
| Core NanoClaw (channels, per-group agent containers) | ✅ Have | Yes — `run.sh` clones and runs it |
| Persistent graph memory (mnemon) | ✅ Have | Yes — `apply_mnemon_patch()` in `run.sh`, byte-verified |
| Wiki knowledge base (Karpathy LLM Wiki pattern) | 🟡 Partial | Mechanical half only (`scaffold-wiki.sh`); domain design is interactive by upstream design |
| Voice transcription — OpenAI Whisper API | ❌ Not built | No |
| Voice transcription — local whisper.cpp | ❌ Not built | No |
| Local vector embeddings (Ollama + `nomic-embed-text`) | ❌ Not built — **no spec exists anywhere** | No |
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

**There is nothing to fetch here.** I checked every skill location that exists: the main `nanocoai/nanoclaw` repo's 48+ bundled skills, the official marketplace (`nanocoai/nanoclaw-skills`, full 24-skill catalog enumerated), and the community-skills repo turned up in search results — no embeddings, vector-memory, or semantic-search skill exists anywhere in NanoClaw's ecosystem. `/add-ollama-tool` is unrelated — it wires an Ollama-backed *tool* into the agent's MCP config for the agent to call local models, not an embeddings/retrieval pipeline.

This piece of the gist is the one place where "how to get it" has no upstream answer — it's original, unpublished work by the gist's author. Building it means designing it from scratch, which means answering questions the gist doesn't specify:
- **Ingestion trigger**: embed on every message? Only wiki pages? Only mnemon entries?
- **Storage**: what vector store — SQLite with `sqlite-vec`, Chroma, a flat file? Nothing in NanoClaw's stack currently includes one.
- **Query path**: a new MCP tool the agent calls (mirroring `/add-ollama-tool`'s registration pattern in `container-runner.ts`/`index.ts`), or something that runs automatically like mnemon's hooks?
- **Relationship to mnemon**: mnemon is graph-based (temporal/entity/causal/semantic edges), not vector-based — would embeddings be a second, parallel memory system, or feed into mnemon somehow? Mnemon's own docs don't mention embeddings at all.

If you want this, it's a genuine design-and-build task, not a patch to apply — happy to draft a concrete proposal if you want to go there, but I'd be inventing the architecture, not implementing a spec.

---

## 📖 Obsidian / iCloud / rsync Sync

Already covered in the README's "Optional: Karpathy LLM Wiki" section — recapping the concrete options here since they follow directly from what's already scaffolded:

- **Content generation**: `./scaffold-wiki.sh <group-folder>` + a manual `/add-karpathy-llm-wiki` session gets you the actual markdown wiki (`$NANOCLAW_INSTALL_PATH/groups/<group>/wiki/`) — this part is done, see the README.
- **Getting it into Obsidian**: since that directory is already a plain host bind mount (nothing container-internal about it), the simplest path is just opening `$NANOCLAW_INSTALL_PATH/groups/<group>/wiki/` directly as an Obsidian vault on whatever machine runs the orchestrator — zero sync needed if Obsidian runs on the same host.
- **If you want it on another device** (the gist's actual setup — a Mac Mini syncing to the author's own Mac/iPhone): point any generic sync tool at that same host directory — iCloud Drive (symlink the folder into your iCloud Drive location), Syncthing, or a cron'd `rsync`. This is genuinely just "sync a folder," no NanoClaw-specific logic involved — the gist author's version isn't more automatable than any other folder-sync setup, which is why it stays out of scope for pi-bootstrap to script generically.

---

## Summary

Two of five pieces are fully automated and verified (core NanoClaw, mnemon). One is half-automated with the interactive part staying manual by upstream design (wiki). Two require real new work: voice transcription is a well-specified but nontrivial build (known upstream skills, cross-distro translation needed); embeddings has no spec at all and would be original design. Sync is intentionally left as "point your own tool at an existing folder."

Let me know which of the remaining pieces you want built — voice transcription (I can start with the git-merge feasibility check against current `main`) or embeddings (I can draft an architecture proposal first, since there's no spec to follow).
