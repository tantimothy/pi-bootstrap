# Gist Parity: What's Here, What's Missing, How to Get It

This document compares this environment against **two gists by the same author**. They describe different systems and stand in very different relationships to what's built here — keeping that straight is the first thing to get right:

- **Gist 1 — [the "second brain" gist](https://gist.github.com/VivianBalakrishnan/a7d4eec3833baee4971a0ee54b08f322)** (`a7d4eec3…`). NanoClaw + mnemon + local embeddings + a wiki + Obsidian sync. **This is the one this environment follows**: its five pieces are build targets, and the first table below is the status of each, verified against actual upstream sources rather than assumed, with exactly what's needed to close each gap.
- **Gist 2 — ["OKF Graph Wiki"](https://gist.github.com/VivianBalakrishnan/83d1ea5f929d0ae51bca7fe25129b0d7)** (`83d1ea5f…`). A later, self-contained retrieval spec for a Karpathy-pattern wiki, built on Google Cloud's [Open Knowledge Format](https://cloud.google.com/blog/products/data-analytics/how-the-open-knowledge-format-can-improve-data-sharing) (v0.1, June 2026). **This environment does not implement it and has not committed to.** It's here as a comparison reference — a second, more rigorous design for the same slot — and because it evaluates and rejects mnemon, which is worth knowing about the component this environment is named for. Its table is further down under "The second gist."

A ❌ in the first table is a gap against something this environment set out to do. A ❌ in the second is simply a thing this environment doesn't do, and mostly never intended to.

**A credibility caveat, worth reading before the rest of this document**: this environment implements each individual piece the gist names against real, independently-verified upstream sources — NanoClaw's own `/add-mnemon` and `/add-karpathy-llm-wiki` skills, and mnemon's own genuinely-real optional embeddings feature. What's *not* independently corroborated is the gist's specific claim that these pieces form one connected pipeline (wiki pages synthesized *from* mnemon's extracted facts). Checked two ways: the gist author's only public GitHub repository is a fork of `mnemon-dev/mnemon` with **zero commits ahead of upstream** ("there isn't anything to compare," confirmed directly via GitHub's own compare view) — no trace of the described wiki-compilation code anywhere in their public work. And none of the five independently-built "Karpathy pattern" wiki implementations surveyed below use anything like a "separate memory tool extracts facts, wiki synthesizes from those facts" architecture — all five compile directly from raw sources, the simpler two-stage model this environment also uses. Given that, **this environment's actual architecture — mnemon and the wiki as independent systems, not a claimed pipeline — looks like the one supported by real-world precedent, not a shortfall relative to a proven design.** Treat "what the gist says" below as one person's unverified description, not an established spec to chase.

**Corroborated since, from the author's own side.** The same author has a second, later gist — [`83d1ea5f…`, "OKF Graph Wiki"](https://gist.github.com/VivianBalakrishnan/83d1ea5f929d0ae51bca7fe25129b0d7) — describing a wiki that ingests **raw sources**, with mnemon appearing only in a section headed "Why not `mnemon-dev/mnemon`" explaining why it was evaluated and rejected. That independently confirms the reading above (no mnemon→wiki pipeline) and explains the zero-commit fork: evaluating and rejecting a tool is exactly what leaves one behind. Full analysis, including whether that gist's critique of mnemon holds up against mnemon's real schema (it does): [`docs/future-enhancements/okf-graph-wiki.md`](../../docs/future-enhancements/okf-graph-wiki.md).

## Gist 1: the "second brain" gist — component status

| Component | Status | Automated in this environment? |
|---|---|---|
| Core NanoClaw (channels, per-group agent containers) | ✅ Have | Yes — `run.sh` clones and runs it |
| Persistent graph memory (mnemon) | ✅ Have | Yes — `apply_mnemon_patch()` in `run.sh`, byte-verified |
| Wiki knowledge base (Karpathy LLM Wiki pattern) | 🟡 Partial | Mechanical half only (`scaffold-wiki.sh`); domain design is interactive by upstream design; **runs independently of mnemon — matches every other real implementation surveyed, not a gap relative to the gist's unverified claim; see the section below** |
| Voice transcription — OpenAI Whisper API | ❌ Not built | No — not planned; see below for why |
| Voice transcription — local whisper.cpp | ✅ Have — via a different path than the gist's own | Yes — but **not** the gist's own WhatsApp-voice-note pipeline analyzed below. A separate, from-scratch `yt-dlp` + `whisper.cpp` build was added instead (`apply_media_tools_patch()` in `run.sh`, plus the orchestrator's own `Dockerfile`) — video-URL transcription for the wiki, not voice-note transcription for chat. See the README's "🎙️ Transcribing Audio/Video" section. Deliberately avoids everything in section 3 below (no `qwibitai` fork, no git-merge, no WhatsApp dependency) — `yt-dlp` and `whisper.cpp` are pulled directly from their own real upstream projects |
| Local vector embeddings (Ollama + `nomic-embed-text`) | ✅ Have — opt-in | Yes — `apply_mnemon_patch()` bakes `MNEMON_EMBED_ENDPOINT`/`MNEMON_EMBED_MODEL` into the Dockerfile when set in `.env` (unset by default; requires a reachable Ollama daemon and `CLEAN` to activate) |
| Obsidian/iCloud/rsync personal sync | ❌ Out of scope by design | Inherently personal, not automatable |

**Naming convention for the rest of this document**: everything from here down to "The second gist" concerns gist 1, and an unqualified "the gist" means gist 1 throughout — those sections were written before a second one existed. Gist 2 is always named explicitly.

---

## 🎙️ Voice Transcription (OpenAI Whisper → local whisper.cpp) — the gist's own approach, not what got built

**Everything below analyzes the upstream gist/skill's own specific pipeline** (WhatsApp voice notes → OpenAI Whisper API → swapped for local whisper.cpp via a git-merge from a third-party fork) — this was research into whether that path was worth taking, and it wasn't. **What actually got built is a separate, from-scratch implementation with none of this section's fragility**: `yt-dlp` (pulled directly from `yt-dlp/yt-dlp`'s own releases) + `whisper.cpp` (built directly from `ggml-org/whisper.cpp`, the real upstream project) patched into both the orchestrator's own `Dockerfile` and NanoClaw's own `container/Dockerfile` via `apply_media_tools_patch()` — no `qwibitai` fork, no git-merge of a moving branch, no WhatsApp dependency, and it transcribes video URLs for the wiki rather than WhatsApp voice notes for chat. See the README's "🎙️ Transcribing Audio/Video" section for what's actually running. The only thing this alternate implementation shares with the analysis below is the end goal (local whisper.cpp transcription) — the mechanism, trigger, and dependencies are all different.

**A third path exists too, and this repo didn't build it**: a live agent, blocked from installing packages at runtime (correctly — sandboxes are non-root by design), found and used a permission gap in its own group's writable folder to install a rootless alternative (`yt-dlp` binary + `ffmpeg-static` npm package + `@xenova/transformers` WASM Whisper + `wavefile`) with zero human approval, and confirmed it works end-to-end. It then went further and got real, native `whisper.cpp` running rootlessly too — `whisper.cpp` ships prebuilt Linux binaries on its own GitHub releases, and the one missing shared library (`libgomp`) was pulled as a raw `.deb` and extracted with `dpkg-deb -x` rather than installed via `apt` (extraction alone needs no root). No longer even a performance tradeoff against the Dockerfile-patch path, just a scope one (still per-group only, no shared install across groups). See the README's same section for the full comparison, including the trust/oversight consideration worth having an actual opinion about — an agent routing around a permission gate it hit, entirely on its own initiative, twice now.

**Why the agent had to resort to this at all, on an install that already had `apply_media_tools_patch()`**: the patch was landing in `container/Dockerfile`'s text correctly, but `run.sh`'s `CLEAN` path never actually rebuilt the agent-sandbox image from it on an existing install — only NanoClaw's own orchestrator got rebuilt. So the patched Dockerfile just sat unused, the agent's own sandbox genuinely had none of these tools, and its rootless workaround was a reasonable response to a real gap rather than an unnecessary one. Now fixed (`run.sh` also calls `container/build.sh` after the orchestrator rebuild) — see the README's "Upgrading NanoClaw Without Redoing Setup" section for the full writeup. One `CLEAN` run against an already-existing install is what actually bakes these tools in for the first time.

Two chained official skills: `/add-voice-transcription` (OpenAI API, prerequisite) then `/use-local-whisper` (swaps to on-device). I fetched both `SKILL.md` files and the actual code each one merges in, to see exactly what's needed rather than guess.

**What's needed:**

1. **WhatsApp channel already added.** Both skills only support WhatsApp (`isVoiceMessage` checks Baileys' `ptt` flag, WhatsApp-specific). Get this via `docker exec -it nanoclaw-mnemon bash -lc "cd $NANOCLAW_INSTALL_PATH && claude"` then `/add-whatsapp` inside that session (interactive — QR/pairing code scan; see the README's "Adding Channels" section — this is no longer a standalone script).
2. **A temporary, funded OpenAI API key.** `/add-voice-transcription`'s own Phase 4 verify step tests a real voice note transcribing through OpenAI's Whisper API before you're meant to move on — so you need a working key at least long enough to pass that gate, even though the code it installs gets fully replaced by the next skill. Cost is trivial (~$0.006/min of audio, one test note).
3. **Two chained git-merges from a separate, old-org fork**: both skills pull from `https://github.com/qwibitai/nanoclaw-whatsapp.git` (note: `qwibitai`, not `nanocoai` — this WhatsApp-channel fork apparently never moved when the main repo transferred owners) — `git fetch whatsapp skill/voice-transcription && git merge ...`, then later `git fetch whatsapp skill/local-whisper && git merge ...`. I pulled the actual `src/transcription.ts` off the `skill/local-whisper` branch directly: it fully replaces the OpenAI call — `execFile('whisper-cli', ['-m', WHISPER_MODEL, '-f', tmpWav, ...])` after an `ffmpeg` resample to 16kHz mono WAV, no OpenAI reference left at all. This is a real git merge of a moving branch, not a fixed text insertion at a known anchor — meaningfully less deterministic to automate/verify than mnemon's patch was, and worth re-diffing against upstream before trusting blindly if those branches change.
4. **`whisper-cpp` (the `whisper-cli` binary) and `ffmpeg` installed where the code actually runs.** This is the key architectural mismatch: `transcription.ts` executes inside the **orchestrator** process (it's WhatsApp-channel code, not agent-sandbox code) — and our orchestrator itself runs inside a container (`environments/nanoclaw-mnemon/Dockerfile`), unlike mnemon which patches the *agent* sandbox's own `container/Dockerfile`. So these binaries would need to go into **our own orchestrator Dockerfile**, not NanoClaw's. The upstream skill assumes `brew install whisper-cpp ffmpeg` on host macOS — Debian-slim (our orchestrator's base image) needs a different install path: `apt-get install -y ffmpeg` works directly; `whisper-cli` has no Debian package, so it'd need building from the [whisper.cpp source](https://github.com/ggml-org/whisper.cpp) or downloading a prebuilt Linux binary from its releases, if one exists for the target arch.
5. **A GGML model file** (`data/models/ggml-base.bin`, ~148MB) downloaded into the install path — straightforward, one `curl` from Hugging Face.
6. **No launchd translation needed** — the upstream skill's Phase 3 is all about macOS launchd PATH/`launchctl kickstart`, irrelevant here since we install the binaries at image-build time (already on `PATH` inside the container) and restart via `docker restart nanoclaw-mnemon`, not launchd.

**Net assessment**: buildable, but step 3's git-merge-from-a-moving-fork and step 4's cross-distro binary translation make this a real engineering task, not a drop-in patch — closer to a half-day of careful work (fetch current branch state, verify the merge applies cleanly against current `nanocoai/nanoclaw` main, find/build a Linux `whisper-cli`, wire a new `apply_voice_transcription_patch()` into `run.sh` alongside the mnemon one) than the few hours mnemon took.

---

## 🧠 Local Vector Embeddings (Ollama + `nomic-embed-text`)

**Corrected twice now, plus one scope note on top of both.** Three passes on this section, worth showing rather than silently overwriting:

**Pass 1** (re-fetched the gist directly): found the gist *claims* the flow is raw sources → mnemon → wiki, with embeddings inside mnemon's own retrieval, not scoped to the wiki as originally proposed. What's below is still an accurate quote of that claim — see the credibility caveat at the top of this document for why "the gist claims X" and "X is real" turned out to be worth separating. What matters for this section specifically is unaffected by that: the model and connectivity details below come from mnemon's own independently-verified docs, not from trusting the gist's narrative.

**Pass 2** (read further into `mnemon-dev/mnemon`'s own README than before): Pass 1 also concluded the gist's "mnemon" must be a custom fork or wrapper, since "mnemon's own docs never mention embeddings." **That conclusion was wrong** — it was based on an incomplete read of the same README. The actual text, further down than previously checked:

> **Intent-aware recall** — graph traversal + optional vector search (RRF fusion), enabled by default for all queries
> **Optional embeddings** — works fully without Ollama; add local Ollama for enhanced vector+keyword hybrid search

And from the configuration table:

| Environment Variable | Default | Description |
|---|---|---|
| `MNEMON_EMBED_ENDPOINT` | `http://localhost:11434` | Ollama API endpoint |
| `MNEMON_EMBED_MODEL` | `nomic-embed-text` | Embedding model name |

**Stock `mnemon-dev/mnemon` has Ollama + `nomic-embed-text` embeddings built in, as an optional flag, with `nomic-embed-text` as the literal default model name.** This part is solid regardless of the gist's own credibility — it's straight from mnemon's own docs, nothing to do with whether the gist's author actually built or ran anything. *If* the gist's description is real, no custom semantic layer would've been needed — stock mnemon (installed exactly as `/add-mnemon` installs it, which is exactly what this environment's `apply_mnemon_patch()` does), pointed at a reachable Ollama daemon, is sufficient on its own. `docs/DEPLOYMENT.md` confirms the container-networking side too: `MNEMON_EMBED_ENDPOINT=http://host.docker.internal:11434` for Docker Desktop — the identical `host.docker.internal` pattern already used for `/add-ollama-tool`'s `OLLAMA_HOST`.

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

**Fixed — this was a caveat, now it's handled.** NanoClaw's `container-runner.ts` unconditionally injects `HTTPS_PROXY` (verified directly, its own comment: "OneCLI gateway — injects HTTPS_PROXY + certs so container API calls are routed through the agent vault for credential injection") into *every* agent container, no exceptions — see the "OneCLI" section below. `apply_mnemon_patch()` now extracts the host from `MNEMON_EMBED_ENDPOINT` (via `sed`, stripping scheme and anything after the host) and bakes `ENV NO_PROXY=<host>`/`ENV no_proxy=<host>` alongside it, unconditionally — not just for `https://` endpoints, since it's a genuine no-op for plain HTTP and costs nothing to include either way. Same fix `/add-ollama-provider`'s own `SKILL.md` applies for its analogous case. Verified against a stub Dockerfile: correct host extraction across `http://host.docker.internal:11434`, an HTTPS remote endpoint with a path and port, `localhost`, and a bare IP; unset endpoint still produces zero extra lines; re-running with the same `.env` doesn't duplicate anything.

---

## 🔐 OneCLI

Not part of the gist, not something this environment adds — core NanoClaw infrastructure, present identically whether you deploy the plain `nanoclaw` environment or this one, since both clone the same upstream repo and run the same `nanoclaw.sh` wizard. Worth naming explicitly here since it came up investigating the caveat above, and because this environment's own README hadn't named it before (the plain `nanoclaw` environment's README already did).

**What it is, verified directly against source, not assumed**: `setup/register-claude-token.sh` hard-requires the `onecli` binary with no fallback path (`command -v onecli >/dev/null || exit 1`) — it's how the wizard registers your Anthropic token into a local vault rather than writing it to `.env` or handing it to a container directly. `container-runner.ts` calls `onecli.applyContainerConfig(...)` on every agent-container spawn, injecting `HTTPS_PROXY` plus certs so the container's own outbound API calls get routed through OneCLI for credential injection at request time — and treats a failed apply as fatal ("OneCLI gateway not applied — refusing to spawn container without credentials"), so this isn't an optional or best-effort mechanism.

This environment's `apply_mnemon_patch()`/`ensure_ollama_ready()` don't interact with OneCLI at all — mnemon is a separate Go binary making its own outbound requests, not going through Claude Code's own SDK/API-call path that OneCLI is built to intercept. The one place the two touch is OneCLI's unconditional `HTTPS_PROXY` injection potentially catching mnemon's own embeddings traffic — see the `NO_PROXY`/`no_proxy` fix in the "Model alternatives" subsection above, now handled.

---

## 🔗 Mnemon and the Wiki Run as Independent Systems — And That Now Looks Like the Right Call, Not a Shortfall

Went through two corrections already (first called the two features fully "disconnected," which overstated it; then treated the gist's claimed pipeline as the target this environment falls short of). A third pass, after checking the gist's actual credibility (see the caveat at the top of this document), changes the framing again: there's no strong reason left to treat the gist's specific pipeline claim as a real target at all.

**What the gist claims** (quoted already in the embeddings section above, and still an accurate quote of what it *says* — just not corroborated as something real): raw sources → **mnemon** (extracts discrete facts) → **wiki** (synthesizes those facts into markdown pages), a *structured, guaranteed* data path — every wiki page traces back to mnemon facts, every time, by design. No implementation of this specific pattern exists anywhere I've been able to find, including in the claimed author's own public work.

**What this environment actually has — independent systems, matching every other real implementation surveyed below, not a gap relative to this claim:**

- `apply_mnemon_patch()` installs mnemon's hooks (`mnemon setup --yes --global`) into `container/entrypoint.sh` — the **per-group agent container's** own entrypoint. That means mnemon's `SessionStart`/`UserPromptSubmit`/`Stop` hooks are active for *any* Claude Code session running in that specific group's container.
- `/add-karpathy-llm-wiki`'s ongoing maintenance (as opposed to its one-time schema setup) isn't a separate process either — the skill wires wiki-ingest/query/lint instructions directly into that *same group's* `CLAUDE.md`/`CLAUDE.local.md` (its Step 3c). So the identical agent, in the identical session, handles both the group's live conversation and its wiki maintenance when instructed to.

Since Claude Code's hooks are session-wide, not scoped to "which skill is active," there's no code-level wall keeping the two apart. Concretely: while an agent is mid-ingest on a wiki source, the **Remind** hook is still firing on every prompt, still nudging "would `recall` help here?" — and the agent's own judgment (per mnemon's `GUIDELINE.md`) could pull in relevant memory and let it shape a wiki page. Symmetrically, the **Nudge** hook after a wiki-maintenance exchange could prompt the agent to `remember` something from it — which cuts both ways: it might capture something genuinely useful, or it might pollute mnemon's memory with file-bookkeeping trivia, since `GUIDELINE.md` has no way to know "this session happened to be doing wiki maintenance" is different from an ordinary conversation.

**What this actually is**: not incidental leakage from a "real" pipeline this environment fails to fully implement — it's the same architecture every independently-built wiki tool surveyed below uses (wiki compiled from curated sources, no fact-extraction intermediary), plus mnemon running alongside it for unrelated conversational memory. The session-level hook overlap described above (mnemon's `Remind`/`Nudge` hooks firing regardless of what the agent is doing) is real and worth knowing about, but it's a side effect of both features sharing a session, not evidence of a missing connection — there's no strong reason to believe a tighter connection was ever a real, working thing to be missing in the first place.

**Naming mismatch worth knowing about regardless**: this environment's scaffold uses `sources/` (NanoClaw's skill's own term); the gist and Karpathy's original idea file both say `raw/`. Same concept, different name.

**If you want a deliberate mnemon-informed wiki anyway** — a legitimate thing to want on its own merits, gist-accuracy aside — that would mean the wiki skill explicitly calling `mnemon recall` as a documented ingest step, not hoping the agent's own judgment happens to do it. Not built; **not currently planned**, since it's not clear this needs to exist rather than optional per-user preference. See the manual-prompt alternative below if you want this behavior without writing code for it.

### Manual bridge: a prompt to combine them on demand

Whether or not the gist ever ran a real version of this, a deliberate, well-worded prompt can combine mnemon and the wiki on demand if you want that — the agent has both tool sets (`mnemon recall`, and, if scaffolded, wiki-writing) available; they're just not wired together automatically. Tested this reasoning against a concrete example:

> "Compile a fresh wiki into the /wiki directory. Query mnemon for our top 20 highest-importance entities and core concepts from the last month, synthesize them into comprehensive narrative pages, and cross-link them using Obsidian wiki-links."

**What actually happens when an agent tries this**, checked against `mnemon`'s real CLI reference (`docs/USAGE.md`, fetched directly), not assumed:

- Verified `recall` flags: `--limit`, `--intent` (`WHY`/`WHEN`/`ENTITY`/`GENERAL`), `--cat` (`preference`/`decision`/`fact`/`insight`/`context`/`general`), `--source`, `--basic`, `--verbose`. **No native importance-sort flag, no native date-range flag, and no native entity-vs-concept type filter** — `--cat`'s actual values don't distinguish "entity" from "concept" at all; entities are metadata attached to an insight via `remember --entities`, not a separately queryable type.
- So a prompt like this **can't** resolve into one precise, deterministic `recall` call. What actually happens: the agent calls `recall` with a broad topic query (or `--basic` for looser matching) and a generous `--limit`, gets back a batch of JSON that *does* include `importance` and, with `--verbose`, timestamps — then filters/sorts/classifies that batch itself, in its own reasoning, to approximate "top 20 by importance, last month, entities vs. concepts." Real data comes back; the filtering precision is the agent's own judgment call, not a guarantee, and results would vary run to run.
- Two prerequisites the prompt itself doesn't establish: the group's agent needs *both* mnemon and wiki tooling actually active (same opt-in-per-group caveat as everything else here — nothing automatic makes both present), and `/wiki` as an absolute path likely isn't right for this environment's layout (`groups/<group>/wiki/`, mounted at `/workspace/agent/wiki/` inside the container) — phrasing it relatively, or letting the agent resolve its own path from its own instructions, avoids that ambiguity.

**Net take**: real, usable, available today — a judgment call each time it's run rather than a guaranteed pipeline, and not chasing gist-parity so much as just a genuinely useful thing to be able to ask for. Good for an occasional "give me a state-of-the-memory wiki snapshot" ask; not a substitute for the deterministic ingest step described above if you specifically want that connection to hold up unattended.

### It has actually been done, once, in the opposite direction

Surfaced on 2026-08-15 from a group agent's own self-documentation, and worth recording because it qualifies the section heading above.

**"Independent systems" describes what this environment wires up — not necessarily what a given deployment ends up running.** Nothing in `run.sh` connects mnemon to the wiki, and that is still accurate. But on 2026-07-18 one real deployment bridged them by hand, and not in the direction the gist claims: the **wiki was bulk-imported into mnemon**, via `mnemon import` against schema-validated JSON drafts, using the 83 wiki pages that existed at the time (the raw `sources/` folder — 243 files, 54MB — was considered and rejected as too voluminous for atomic insight storage). Result: 321 insights, 0 errors, and 3,295 total edges from 140 explicitly declared ones, the rest auto-derived by mnemon's own import path.

So the manual bridge above isn't hypothetical, and the direction that actually got exercised is **wiki → mnemon**, the reverse of the gist's claimed mnemon → wiki pipeline. That is still not evidence for the gist's architecture — if anything it's the opposite, since it treats the wiki as the source and mnemon as the derived store.

**It also turned out to be the wrong direction to push knowledge**, for reasons that are mnemon's design rather than anyone's mistake — see `docs/lessons-learned/nanoclaw-mnemon.md`'s 2026-08-15 entry. Short version: mnemon decays and prunes by design, so reference material imported at default importance halves in effective value every 30 days, and a one-time snapshot goes stale from the next wiki edit onward (that corpus reached 632 pages within a month, leaving the import at ~13% coverage). The gist's own §5.1 reaches the same conclusion from the other side, listing importance-decay and auto-pruning as reasons mnemon can't be the wiki's substrate.

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

**No longer unanimous, though the finding stands.** A sixth entry — the same gist author's [OKF Graph Wiki spec](https://gist.github.com/VivianBalakrishnan/83d1ea5f929d0ae51bca7fe25129b0d7) — puts vector similarity in the core path, as one of three RRF-fused seed signals, and states outright that no TF-IDF fallback exists in its production path. It's a spec rather than a surveyed shipping project, so it doesn't outweigh five independent implementations converging the other way; it does mean "nobody in this space uses embeddings as core retrieval" is now too strong a statement. See [`docs/future-enhancements/okf-graph-wiki.md`](../../docs/future-enhancements/okf-graph-wiki.md).

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

- **Content generation**: `./scripts/scaffold-wiki.sh <group-folder>` + a manual `/add-karpathy-llm-wiki` session gets you the actual markdown wiki (`$NANOCLAW_INSTALL_PATH/groups/<group>/wiki/`) — this part is done, see the README.
- **Getting it into Obsidian**: since that directory is already a plain host bind mount (nothing container-internal about it), the simplest path is just opening `$NANOCLAW_INSTALL_PATH/groups/<group>/wiki/` directly as an Obsidian vault on whatever machine runs the orchestrator — zero sync needed if Obsidian runs on the same host.
- **If you want it on another device** (the gist's actual setup — a Mac Mini syncing to the author's own Mac/iPhone): point any generic sync tool at that same host directory — iCloud Drive (symlink the folder into your iCloud Drive location), Syncthing, or a cron'd `rsync`. This is genuinely just "sync a folder," no NanoClaw-specific logic involved — the gist author's version isn't more automatable than any other folder-sync setup, which is why it stays out of scope for pi-bootstrap to script generically.

---

## The second gist: OKF Graph Wiki — a reference point, not a roadmap

[`83d1ea5f…`](https://gist.github.com/VivianBalakrishnan/83d1ea5f929d0ae51bca7fe25129b0d7), by the same author and necessarily later (it builds on a spec published 12 June 2026). A full engineering design for the retrieval half of a Karpathy-pattern wiki: OKF-formatted concept files as the source of truth, a regenerable SQLite index (`concepts` + FTS5 + `embeddings`), and a `context_for(question)` pipeline — RRF fusion (k≈60) of exact-title / BM25 / vector cosine, intent detection, bounded 2-hop graph expansion with trust multipliers, supersession and staleness filtering. TypeScript on Bun, Ollama + `nomic-embed-text`.

**Read this table differently from the one at the top.** Nothing here was ever a build target. It exists so that a future reader comparing this environment against that gist can see immediately which parts happen to coincide, which don't, and which diverge deliberately.

| Component | Status here | Notes |
|---|---|---|
| Markdown concept files as source of truth | 🟡 Partial | The scaffolded wiki is markdown, but nothing produces OKF-conformant frontmatter. One deployment separately maintains a genuinely OKF v0.1-conformant bundle (4 files) alongside its wiki — built by hand, not by anything in `run.sh` |
| **Git-diffable** source of truth | ❌ | The spec's own first and strongest objection to mnemon is that a DB isn't git-diffable. Checked on a live install: the wiki isn't under version control either, so that advantage is currently theoretical. Highest-leverage gap of any row here |
| Typed `relations` triples | ❌ | The author's own extension, not OKF core (OKF requires only `type`). One page carries `relations:`; ~138 person-pages carry an ad-hoc `married:` scalar that is the same idea in weaker form — and doesn't currently parse |
| `wiki.db` — SQLite `concepts` + FTS5 + `embeddings` | ❌ Not built | — |
| `context_for()` retrieval pipeline | ❌ Not built | — |
| `lint` / `evaluate` / `timeline` / `keywords` | ❌ Not built | `evaluate` as a hard gate on every ingest is something none of the six wiki implementations surveyed above does |
| `UserPromptSubmit` trigger hook | ❌ Not built | The slot is occupied: mnemon's own hook is registered there, and `MNEMON-RECALL-POLICY.md` answers the same "when should the agent go look?" question in prose instead |
| Bun runtime | ✅ Present | Ships in NanoClaw's own base image (`/usr/local/bin/bun`, all groups) — nothing to install |
| Ollama + `nomic-embed-text` | ✅ Present | The same host daemon and model mnemon's optional embeddings already use |
| Supersession / staleness (`superseded_by`, `stale_after`) | ❌ | — |
| mnemon itself | ⚠️ Divergent, deliberately | **The spec evaluates mnemon and rejects it** (§5.1); this environment installs it by default. Not a gap — see below |

### The mnemon rejection, and why it isn't an argument to remove it

§5.1's four objections: the SQLite DB *is* the source of truth with no git-diffable per-node files; the `insights` schema is flat, with no room for `type`/`sources`/`verified`/`status`/`stale_after`; edges are inferred heuristically from a fixed four-type enum rather than deliberately asserted; and importance-decay plus auto-pruning work against a "nothing gets silently dropped" goal.

**All four check out** against mnemon's real schema — as documented independently in this repo, in `scripts/export-mnemon-pages.py`'s header (confirmed against mnemon's own `internal/store/db.go`), right down to the four-type enum being that script's own `EDGE_TYPE_ORDER`.

They are also all arguments about mnemon as a *wiki substrate*, not as conversational memory. Decay and pruning are a liability for a compounding reference corpus and a feature for cross-session chat memory, where unbounded accumulation is the actual failure mode. The two systems are optimised for different jobs, and this repo has since seen what happens when that boundary is crossed in practice — see `docs/lessons-learned/nanoclaw-mnemon.md`'s 2026-08-15 entry on a wiki bulk-imported into mnemon.

### What's worth taking from it regardless

Most of the spec is standard information retrieval — RRF at k≈60 is the constant from the original rank-fusion literature, and hybrid keyword+vector fusion is what mnemon's own README already advertises. Three ideas aren't, and are cheap enough to adopt without the rest:

- **BM25 gated on word *coverage*, not score** — the fraction of the question's content words present in the top match, `>0.5`. BM25 scores aren't comparable across queries, so a fixed score threshold is unreliable by construction; coverage is query-normalised.
- **Exact title match as a first-class fused signal, weighted 2×, at whole-word boundaries** — with the failure it prevents stated plainly: *"A concept titled 'AI' must not seed on the word 'explain', nor 'Go' on 'ago'."*
- **`evaluate` as a hard gate on every ingest** — regression-testing a knowledge base.

Full analysis, what would be involved in building any of it here, and an ordering if someone does: [`docs/future-enhancements/okf-graph-wiki.md`](../../docs/future-enhancements/okf-graph-wiki.md).

---

## Summary

Three of five pieces are fully automated and verified now (core NanoClaw, mnemon, and mnemon's optional embeddings — the last of which looked like the hardest gap through two prior passes on this document and turned out to be a built-in config flag). One is half-automated with the interactive part staying manual by upstream design (wiki) — and runs as an independent system from mnemon, which, after checking the gist's own credibility (see the caveat at the top of this document), now looks like the architecture matching real-world precedent rather than a shortfall against a proven design: none of the five independently-built wiki tools surveyed below connect a memory tool's extracted facts to wiki compilation either. A manual prompt can combine the two on demand if you want that behavior anyway, documented below. Voice transcription **via the gist's own specific pipeline** (WhatsApp voice notes, OpenAI Whisper, the `qwibitai` fork git-merge) remains an unstarted build, deliberately — but local whisper.cpp transcription itself is done, via a separate, from-scratch `yt-dlp`+`whisper.cpp` implementation with none of that pipeline's fragility (see the section above and the README's "🎙️ Transcribing Audio/Video"). Sync is intentionally left as "point your own tool at an existing folder."

**Against gist 2, the picture is different in kind, not degree.** Almost nothing of the OKF Graph Wiki spec is built, and almost none of it was ever meant to be — the two things that do line up (Bun, and Ollama with `nomic-embed-text`) are there for other reasons entirely. The rows worth a second look are the two that aren't simply "not built": the wiki isn't in git, which nullifies the spec's own strongest argument for markdown over a database and is cheap to fix; and mnemon is installed here despite the spec rejecting it, which is a deliberate divergence rather than an oversight, because the rejection is about mnemon as a *wiki substrate* and this environment uses it as *conversational memory*.

Both gists point at the same underlying boundary from opposite sides: curated reference material wants a durable, reviewable store, and conversational context wants one that forgets. Gist 1 blurred that line with a claimed pipeline this environment declined to build; gist 2 draws it explicitly and rejects mnemon on the strength of it. This environment has arrived at the same place by keeping the two systems separate.

Let me know if you want voice transcription started next — begin with the git-merge feasibility check against current `main`.
