# OKF Graph Wiki — a second gist by the same author, and what it would mean here

**Status: evaluated; nothing built in pi-bootstrap itself, and nothing planned here.** This
document exists because the gist it analyses explicitly evaluates and rejects mnemon — the
component `environments/nanoclaw-mnemon/` is named for — and its stated reasons check out
against mnemon's real schema. That's worth having on record whether or not anything gets
built.

A partial build has since been proposed from the other direction — by an agent running
*inside* a deployed group, for that group's own wiki, rather than as a change to this
repo. Which level should own that work, ordering guidance, and three corrections are in
"[Implementation ordering, if a group agent builds part of this](#implementation-ordering-if-a-group-agent-builds-part-of-this)"
below. **Read the Ollama correction before starting anything**: the most likely wasted
effort is re-solving a problem `run.sh` already solves.

## What this is about

`environments/nanoclaw-mnemon/GIST-PARITY.md` tracks
[gist `a7d4eec3…`](https://gist.github.com/VivianBalakrishnan/a7d4eec3833baee4971a0ee54b08f322)
("NanoClaw + mnemon + local embeddings + wiki + Obsidian sync as a second brain").

This document is about a **different gist by the same author**:
[`83d1ea5f…`](https://gist.github.com/VivianBalakrishnan/83d1ea5f929d0ae51bca7fe25129b0d7),
`okf-graph-wiki.md` — "OKF Graph Wiki: Agent-Maintained Knowledge Graph for Context
Retrieval." It is not a companion piece to the first one. It is a self-contained
engineering spec for the retrieval half of a Karpathy-pattern wiki, and its architecture
contradicts the first gist's on the one point `GIST-PARITY.md` already flagged as
uncorroborated.

**How this was read, stated once up front**: `gist.githubusercontent.com` is blocked by
this session's network egress proxy, so the raw file could not be fetched. Everything
below comes from the rendered gist page read through the fetch tool. Direct quotes are
reproduced as that tool returned them. This is weaker sourcing than `GIST-PARITY.md`'s
own standard (it quotes upstream files fetched directly), and given that document's
history of corrections from exactly this kind of gap, **re-read the gist directly before
acting on any of it**. The one claim below that does *not* depend on that sourcing is the
mnemon-schema corroboration, which is checked against code in this repo.

## OKF is a real external spec, not the author's coinage

Worth establishing first, because it changes how much of this is one person's design.
**Open Knowledge Format is an open specification (v0.1) published by Google Cloud on
12 June 2026** — a vendor-neutral markdown + YAML-frontmatter format for giving AI agents
curated context, explicitly formalising the LLM-wiki pattern into something portable.
OKF core requires exactly one field on every concept: `type`. Concepts link to each other
with ordinary markdown links, and the directory becomes a traversable graph.

So the gist's foundation is a published standard with a named author organisation behind
it — a materially different situation from the first gist, whose central claim
`GIST-PARITY.md` could not corroborate anywhere. The gist's **typed-triple `relations`
array is the author's own extension on top of OKF**, not part of the base spec.

That the gist necessarily postdates 12 June 2026 also makes it, most likely, the author's
later position on this problem — not a parallel description of the same system.

## What the spec describes

- **Source of truth stays markdown.** One concept file per entity under `entities/` (and
  `computations/` for attested metrics), `references/` for mirrored external material.
  Frontmatter carries `type`, `title`, `description`, `tags`, `sources`, `generated`,
  `verified`, `status`, `stale_after`, `superseded_by`, `supersedes`, and `relations`.
- **`relations` is an array of typed triples.** Subject is implicit (the file's own path);
  each entry has `predicate` (free text, open vocabulary), `object` (a bundle-relative
  path starting `/`, or a literal), and optional `date` and `source` (joining to
  `sources[].id`). Edges are asserted bidirectionally in the same ingest step — the spec's
  own example: when a person's file gets `secretary_of → /entities/us-department-of-state.md`,
  the department's file gets the matching `secretary →` triple.
- **`wiki.db` is a build artifact**, regenerated unconditionally on every ingest, never
  hand-edited: a `concepts` table (frontmatter fields as columns, JSON for the array-valued
  ones, plus `body`), an FTS5 mirror over `title`/`description`/`tags`/`body`, and
  `embeddings(path, vector)` with the vector as a JSON float array.
- **`context_for(question)`** — the retrieval pipeline:
  1. **Seed matching** via Reciprocal Rank Fusion (k ≈ 60) over three signals: exact
     whole-word title match (fused twice, i.e. weighted 2×), FTS5/BM25, and vector cosine.
  2. **Intent detection** — `WHY | WHEN | ENTITY | GENERAL`, driving predicate weights.
  3. **Bounded graph expansion** — BFS, 2 hops default, scored
     `predicate_weight(intent, predicate) × hop_decay^hop × trust_multiplier(tier)`.
  4. **Trust and budget filtering** — drop facts where `today >= stale_after`, exclude
     `status: superseded` from seeding and resolve supersession chains at query time
     (bounded walk), then take the top N within the context budget.
  5. **Serialisation** — compact fact lines with trust tier and source inline, plus seed
     concept prose.
- **Operations**: ingest, query, lint (orphans, broken link targets, contradictions,
  asymmetric relations, predicate drift), reindex, evaluate (regression cases, run as a
  hard gate on every ingest), and rebuild-from-references.
- **Runtime**: TypeScript on **Bun** (`bun:sqlite`), the `yaml` package pinned to YAML 1.2
  core schema, and **Ollama + `nomic-embed-text`** at `localhost:11434` with
  `search_document:`/`search_query:` prefixing. The spec is explicit that there is no
  TF-IDF fallback in the production path.
- **Optional harness hook** (§12): `wiki-trigger.sh` registered as a `UserPromptSubmit`
  hook in Claude Code's `settings.json`, grepping the incoming prompt against a regenerated
  `wiki-trigger-keywords.txt` (concept titles + tags) so the expensive pipeline stays off
  the hot path for off-topic turns.

Tuning constants are given as starting points, not requirements — `hop_decay` "constant
< 1 (e.g. 0.6)", `SUPERSEDED_MULTIPLIER` "(e.g. 0.15)", and the 0.65 vector threshold as a
value reached during prototyping and expected to be retuned per bundle via `evaluate`.

## Does it describe anything new?

Mostly no, and the parts that are new are small and practical rather than architectural.

**Not new** — OKF itself (Google Cloud, June 2026); the Karpathy wiki pattern it opens by
crediting; RRF with k ≈ 60 (the standard constant from the original rank-fusion
literature); SQLite FTS5/BM25; cosine similarity over `nomic-embed-text`; hybrid
keyword+vector retrieval fused by RRF (mnemon's own README advertises exactly this, and
`nomic-embed-text` is literally mnemon's default `MNEMON_EMBED_MODEL`); bounded multi-hop
graph expansion with distance decay, which is the standard graph-RAG shape.

**Distinctive, and worth stealing regardless of whether the whole thing gets built:**

| Idea | Why it's interesting |
|---|---|
| **BM25 gated on word *coverage*, not score** — "the fraction of the question's content words that actually appear in [the top match]", `>0.5` | BM25 scores aren't comparable across queries, so a fixed score threshold is unreliable by construction. Coverage is query-normalised. This is a genuinely better answer to a real problem. |
| **Exact title match as a first-class fused signal, weighted 2×, at whole-word boundaries** | With the stated failure it prevents: "A concept titled 'AI' must not seed on the word 'explain', nor 'Go' on 'ago'." Cheap, deterministic, and it fixes the case embeddings are worst at. |
| **Trust tier as a retrieval multiplier derived from `verified` frontmatter** | `{human-reviewed: 1.0, machine-confirmed: 0.8, unverified: 0.6}` — makes provenance affect ranking rather than just being displayed. |
| **Supersession and staleness resolved at query time** | `superseded_by`/`supersedes` chains walked (bounded) during retrieval, plus `stale_after` expiry — an explicit answer to "the KB says two contradictory things and both are technically in there." |
| **`evaluate` as a hard gate on every ingest** | Treating a knowledge base like code with a regression suite. None of the six wiki implementations surveyed in `GIST-PARITY.md` does this. |
| **Regenerated trigger-keywords + `UserPromptSubmit` hook as a pre-filter** | Directly comparable to this environment's own `apply-mnemon-recall-policy.sh` — see below. |

The typed-triple `relations` extension is the one architectural addition, and it's an
extension to OKF rather than a new idea in itself — subject-predicate-object with temporal
and source qualification is RDF's model, restated in YAML.

## The part that matters here: it evaluates mnemon and rejects it

§5.1, titled "Why not `mnemon-dev/mnemon`", gives four reasons:

> Its SQLite DB **is** the source of truth — no per-node markdown files exist to keep
> git-diffable, which inverts this spec's core principle (§1, §3).
>
> Its `insights` schema is a flat memory-snippet model with no room for OKF's
> `type`/`sources`/`verified`/`status`/`stale_after` fields.
>
> Its edges are inferred heuristically (embedding similarity thresholds, keyword regex,
> temporal proximity) from a fixed four-type enum, not deliberately asserted, sourced,
> open-vocabulary predicates.
>
> It has importance-decay and auto-pruning by design, which works against the "nothing
> gets silently dropped" compounding-wiki goal.

**All four check out against mnemon's real schema, as already recorded in this repo** —
this is the one claim here that doesn't depend on the gist being trustworthy.
`environments/nanoclaw-mnemon/scripts/export-mnemon-pages.py`'s header documents the
schema confirmed against mnemon's own upstream `internal/store/db.go`:

```
insights(id, content, category, importance, tags, entities, source,
         access_count, created_at, updated_at, deleted_at,
         last_accessed_at, embedding, effective_importance)
edges(source_id, target_id, edge_type, weight, metadata, created_at)
```

- Flat snippet model with no provenance/verification/expiry fields — confirmed.
- Fixed four-type edge enum — confirmed; that same script's `EDGE_TYPE_ORDER` is exactly
  `causal, temporal, entity, semantic`.
- Importance decay and pruning — `importance`, `effective_importance`, `access_count`,
  `deleted_at` are precisely that machinery.
- DB as source of truth — confirmed by every one of this repo's mnemon scripts having to
  snapshot a live WAL-mode SQLite file to read anything out of it.

This is an accurate critique, not a dismissal. Whether it's the *right tradeoff* is a
separate question: mnemon's decay-and-prune is a feature for conversational memory, where
unbounded accumulation of chat trivia is the actual failure mode, and a liability for a
compounding reference wiki. The two systems are optimised for different jobs. The gist's
mistake, if any, is treating that as a defect rather than a scope difference.

## What it does to `GIST-PARITY.md`'s conclusions

**It corroborates the credibility caveat, and resolves one loose end.** That document
doubted the first gist's claim of a wiki synthesised *from* mnemon's extracted facts,
noting no implementation of that pattern exists anywhere, including in the author's public
work. This gist confirms it from the author's own side: ingest reads **raw sources**
("Agent reads a new source, extracts facts, discusses with the user…"), and mnemon isn't
upstream of the wiki at all — it's a rejected alternative. It also explains the odd
evidence `GIST-PARITY.md` turned up: a public fork of `mnemon-dev/mnemon` with zero commits
ahead of upstream is exactly what "evaluated and rejected" leaves behind.

**It is a sixth data point that partly breaks one cross-cutting finding.** The
Karpathy-ecosystem section concludes that none of the five surveyed implementations use
vector embeddings as their core retrieval mechanism, and calls that convergence a
load-bearing design signal. This spec *does* — as one of three RRF-fused signals, with no
TF-IDF fallback in the production path. It doesn't overturn the finding (five independent
implementations still converged the other way, and this one is a spec rather than a
surveyed shipping project), but it's no longer unanimous, and the qualification belongs
next to the claim.

## What building it here would actually involve

Not recommended as-is — this is scoping, not a plan.

| Piece | Fit against this environment |
|---|---|
| **Bun + six TS scripts** | Must run where the *agent* runs, i.e. NanoClaw's per-group sandbox — a new `apply_okf_wiki_patch()` on `container/Dockerfile`, subject to every rule in the root `CLAUDE.md`: version-marked block, version bumped on any text edit, anchors checked before use, `\|\| true` at the call site, base image rebuilt **and** derived `nanoclaw-agent-v2-<slug>:<group-id>` images swept afterwards. |
| **Ollama + `nomic-embed-text`** | Already solved. `ensure_ollama_ready()` installs the daemon and pulls the model; `MNEMON_EMBED_ENDPOINT` establishes the `host.docker.internal` pattern. The spec's `localhost:11434` needs that same translation. |
| **Bundle layout** | Maps onto what `scaffold-wiki.sh` already creates: bundle root → `groups/<g>/wiki/`, `references/` → the existing `sources/`. `log.md` exists in both, with different conventions — the scaffold's is `## [YYYY-MM-DD] ingest\|query\|lint \| <title>`, the spec's is OKF-native edit history. Note `GIST-PARITY.md` already records a `sources/` vs `raw/` naming mismatch against the first gist; this would be a third name for the same directory. |
| **Schema docs in `CLAUDE.md`/`AGENTS.md`** | Walks straight into the known trap: `claude-md-compose.ts` regenerates `CLAUDE.md` fresh on every container spawn ("Composed at spawn — do not edit"). Must be `CLAUDE.local.md`, same as `scaffold-wiki.sh` already warns about for the upstream skill. |
| **`UserPromptSubmit` trigger hook** | Overlaps with `apply-mnemon-recall-policy.sh`, which solves the same "when should the agent go look something up?" problem with marker-delimited prose in `CLAUDE.local.md` instead of a keyword grep. The hook is deterministic and cheaper per turn; the prose policy needs no harness support and no regenerated keyword file. Not obviously better either way — but they would both be firing, on every prompt, in the same session. |
| **Scale** | Non-issue. The spec targets hundreds to low thousands of concepts and says a linear vector scan is fine there. A real store in this environment sits at 353 insights / 4262 edges. |

**The honest summary**: this is a well-argued spec that would sit *beside* mnemon in the
same container, duplicating a good deal of its retrieval design over a different and more
inspectable source of truth, with two hooks competing to nudge the same agent. Building it
would be a real project, and the case for it is "markdown you can review in git beats an
opaque insight DB", not "mnemon is broken". If any of it gets picked up, the BM25
coverage gate and the exact-title seeding rule are the cheap, standalone wins.

## Implementation ordering, if a group agent builds part of this

**Whose build this is.** The proposal this section responds to came from an agent running
inside a deployed group, scoped to that group's own `wiki/` — not a change to this repo.
That distinction sets the rules below: group-local files persist across deploys, anything
inside the NanoClaw checkout does not, and nothing here goes through `run.sh`'s patch
machinery unless it graduates into a `apply_*_patch()`. The proposal came in three tiers
(conventions / scripts / embeddings). The tiering is sound; the contents need three fixes.

### Which level owns it: build at group level, keep at pi-bootstrap level

**"pi-bootstrap level" does not have to mean the patch machinery.** A version-marked
`apply_*_patch()` on `container/Dockerfile`, with the base rebuild and derived-image sweep
it drags along, is one tier — not the only one. `scripts/scaffold-wiki.sh` is the proof:
a pi-bootstrap-owned script, invoked manually against one group, writing plain files into
that group's folder. No version marker, no image rebuild, no sweep. That's the tier these
scripts fit, and noticing it removes most of the usual cost argument for keeping generic
tooling out of the repo.

So the question isn't "repo or agent", it's which parts and when.

| Piece | Belongs to | Why |
|---|---|---|
| `lint.ts`, `timeline.ts`, `build-index.ts`, `keywords.ts` | **pi-bootstrap, eventually** | Zero group-specific content; byte-identical for every group. Generic mechanism distributed to many groups is what this repo is for. |
| The schema — which `type`s exist, which predicates are legitimate, what earns a page | **The group, permanently** | Domain-specific by definition. Same boundary `scaffold-wiki.sh` already documents: mechanical half scripted, schema half stays collaborative, because unattended schema design produces a generic, shallow wiki. |
| Hook registration, if it happens | **pi-bootstrap** | Same shape as `scripts/apply-mnemon-recall-policy.sh` — marker-delimited, owned by the repo, rewritten every deploy. Agent-authored hook config that a later deploy overwrites is a bad time. |

**Build it at group level first**, for three reasons in descending weight:

1. **Iteration cost.** In the group folder, editing `lint.ts` is instant. Under pi-bootstrap
   it's edit → deploy → verify every time, and as a Dockerfile patch it inherits this repo's
   own documented trap: forget the version bump and the change is invisible to every existing
   install while every deploy reports success. That's the wrong loop for code that will change
   twenty times in its first week.
2. **A linter needs a corpus, and only the group has one.** This repo has no fixtures and no
   test framework — verification here is `bash -n` and a real deploy. Whether a check like
   "asymmetric relations" fires on real data can only be found out where real pages exist.
3. **Durability is not the tiebreaker it appears to be.** Group-folder scripts survive `CLEAN`
   (gitignored, so `git reset --hard` cannot see them) *and* `groups/` is declared in
   `info.yaml`'s `data_dirs`, so `backup.sh` archives them. Group-level work here is not
   fragile in the way "outside git" usually implies.

**What group level genuinely lacks**, and these are real: no review, no diff history, no PR
trail; no replication to a second group; not reproducible on a fresh Pi except via restore;
and no `docs/lessons-learned/` entry when it breaks. Acceptable for a prototype, not for
anything load-bearing.

**Graduation triggers — write them down now or the prototype simply stays one.** Move the
generic scripts into `environments/nanoclaw-mnemon/scripts/`, in the `scaffold-wiki.sh` mold,
when **any one** of these holds: they've stopped changing; a second group wants them or a
fresh Pi has to reproduce them; losing them would actually cost something.

**The override — checked on 2026-08-15, and it does not apply**: Bun ships in NanoClaw's own
base image (`bun 1.3.12`, `/usr/local/bin/bun`, all groups), so group-level is confirmed and
none of the image machinery is needed. The rule is kept because it still governs any *future*
tool this work turns out to need. If a runtime isn't on `PATH` in the agent sandbox, that work
is pi-bootstrap's from day one — it becomes a `container/Dockerfile` patch, and an agent structurally cannot durably
modify the image it runs in. That case has precedent worth heeding: `GIST-PARITY.md` records
an agent hitting exactly this wall for media tools, then installing `yt-dlp` and a rootless
`whisper.cpp` around it through a permission gap in its own writable folder — twice,
unprompted. It worked, and it was also per-group-only, unreplicable, and off-book, while the
underlying gap was a pi-bootstrap bug (`CLEAN` not rebuilding the sandbox image from the
patched Dockerfile) that could only be fixed at the right level. A rootless Bun in one group's
folder would be that story again.

### The Ollama tier is mostly already built, and installing it in-container is wrong

Treating embeddings as "one package install inside the sandbox, pending admin approval"
misreads how this environment is wired. **Ollama runs natively on the host**; containers
reach it at `host.docker.internal:11434`. `run.sh:2170`'s `ensure_ollama_ready()` — called
unconditionally at `run.sh:2493` on every deploy, `FAST` or `CLEAN` — already probes the
endpoint, offers a host install behind a y/N prompt (Homebrew on macOS, the official
installer on Linux), starts an installed-but-stopped daemon, and **pulls the configured
model if it's missing**. Installing a second daemon inside a per-group sandbox would mean a
duplicate model download per group on a Pi, for nothing.

The correct action is: set `MNEMON_EMBED_ENDPOINT` in `.env`, redeploy. No package request.

The hard part of this tier was never installation — it's **container→host reachability**,
already a real multi-day failure here (see the README's Ollama section): `host.docker.internal`
resolved inside the container to an address that refused connections while the host's own LAN
IP was reachable from that same container, and every host-side check passed the whole time.
That's why `ensure_ollama_ready()` also curls from inside a throwaway container with
`--noproxy '*'`. A second footgun sits next to it: baking `ENV NO_PROXY=host.docker.internal`
into the image *breaks* the routing this needs (`run.sh:1117-1132`). Any new embedding client
written inside the sandbox inherits both — reuse the existing endpoint configuration rather
than re-deriving it.

(On model size: 137M *parameters*, ~274MB *on disk* at F16. Both figures are correct; they're
different units, not a discrepancy.)

### Split the script tier — half of it has no reader

| Script | Ship when? | Why |
|---|---|---|
| `lint.ts` | **Now** | Output is consumed by a human directly. Needs no SQLite — it walks frontmatter and checks referential integrity — so it has no dependency on `build-index.ts` and ships completely standalone. Lowest coupling *and* highest immediate value. |
| `timeline.ts` | **Now** | Same: renders `timeline.md` for a human. Self-contained. |
| `build-index.ts` | **Wait** | Produces a `wiki.db` nothing queries until `context_for()` exists. An unread index goes stale. |
| `keywords.ts` | **Wait** | Produces a keyword file that is inert until a `UserPromptSubmit` hook is registered to read it. |

`context-for.ts` — the actual payoff, and the only consumer of the bottom two — is in none of
the proposed tiers. Build the index and the keyword file *with* their reader, as one piece of
work, or not yet.

> **Superseded in part.** The "wait" verdict on `build-index.ts` was reasoned from an assumed
> ~50-page corpus. The real figure is 632, and FTS5 needs no frontmatter — see
> "[Revised ordering](#revised-ordering)" below, which promotes it. The pairing rule stands:
> build it *with* `context-for.ts`, never alone.

The hook in particular is the highest-integration-risk item and shouldn't be waved through as
a footnote: it has to be registered in the agent's own settings inside the container, and it
would fire on every prompt alongside mnemon's own hooks **and** the marker-delimited recall
policy that `scripts/apply-mnemon-recall-policy.sh` rewrites into each group's
`CLAUDE.local.md` on every deploy. Three mechanisms nudging one agent on one turn.
`MNEMON-RECALL-POLICY.md` is the existing prose answer to the same question the hook answers
deterministically; decide which one owns the job before adding the second.

### Where the files live decides whether the work survives

Anything written inside the NanoClaw checkout is destroyed by the next `CLEAN` — that path is
`git reset --hard` to upstream, and the README states plainly that manual edits inside the
checkout are discarded. Scripts must live in the group's own folder
(`$NANOCLAW_INSTALL_PATH/groups/<group>/`), which is in NanoClaw's `.gitignore` and therefore
invisible to git operations — the same reason `groups/`, `data/`, and a scaffolded `wiki/`
already survive `CLEAN`. Anything that needs to survive an *image* rebuild as well eventually
has to graduate into a version-marked `apply_*_patch()` in `run.sh`, with the derived-image
sweep that implies (see the root `CLAUDE.md`). For scripts operating on group-local data,
group-local is correct and sufficient.

### Answered by the group agent, 2026-08-15 — and two of the answers change the plan

Both open questions above came back, along with the corpus shape. Recorded here because
the second answer reverses part of the ordering that preceded it.

**Bun: present, and it's free.** `bun 1.3.12` at `/usr/local/bin/bun`, a root-owned 100MB
native binary that ships in NanoClaw's own base image — the agent runner at `/app/` is
itself a Bun application (`bun.lock`, `"start": "bun src/index.ts"`). Not apt, not `npm -g`,
available to every group, no per-group install. `node v22.23.1` is there too. This is the
cleanest possible answer to the level question: **no Dockerfile patch, no image rebuild, no
derived sweep** — these are plain files in the group folder, and later graduation into
`environments/nanoclaw-mnemon/scripts/` is a file copy in the `scaffold-wiki.sh` mold.

**Scale: 632 pages, not the ~50 the caveat above assumed.** That inverts it. 632 is six
times past the ~100-article threshold at which every surveyed implementation says
index-first navigation stops working, and comfortably inside the OKF spec's own
hundreds-to-low-thousands target. Retrieval is warranted *now*; it is not premature.

**Frontmatter: 291 of 632 pages have any (46%).** `relations:` appears on exactly one page,
`nodes:` (an older format) on four. So the relation graph starts from zero.

The consequence for ordering, which contradicts the "wait" verdict in the table above:
**FTS5 indexes body text, so `build-index.ts` needs neither frontmatter nor the schema.**
It delivers keyword search across all 632 pages immediately; only graph expansion depends
on `relations`. The earlier table bundled `build-index.ts` with the schema-dependent work,
which was the right call for a ~50-page corpus and the wrong one for this.

`lint.ts` still goes first, but **its value is not where the proposal put it.** Relation
symmetry has one page to check. What has real signal today: 341 pages with no frontmatter
at all, missing `type`/`title` on the 291 that do, the 4 legacy `nodes:` pages, broken
internal links, orphans, and the `log.md`-versus-`log/` split.

### The type vocabulary already exists, and OKF's would break it

"No existing schema to conform to" isn't quite right. The corpus has an emergent one, in
use: `reference` ×68, `wiki-page` ×15, `personal-history` ×11, `archive` ×10, `explainer`
×9, `book` ×7, plus a tail.

Those don't compete with the spec's `Person`/`Organization`/`Product`/`Place`/`Country`/
`Entity`/`Concept` — they're a different axis. **The existing types describe what a
document *is*; OKF's describe what an entity *is*.** This corpus is a library; OKF models a
graph. Adopting the spec's list verbatim would mean reclassifying ~120 already-typed pages
into a taxonomy that doesn't describe them, with no correct answer for what `type: book`
becomes.

The likely right shape is both axes: keep document types for source-derived pages, and add
entity pages as a new layer that `relations` actually connects. That is a schema design
decision, and per `scaffold-wiki.sh`'s own reasoning it isn't one to make unattended.

One gap worth closing first: the listed types account for ~120 of the 291 frontmatter
pages. Whether the remaining ~170 are a long tail of one-off types or have no `type:` at
all changes whether the vocabulary needs consolidating before anything indexes it.

### The hook has a scope risk the sandbox can't see

`settings.json` lives at `/home/node/.claude/settings.json`, on a virtiofs mount from the
Mac host — so it survives container restarts, and its single current `UserPromptSubmit`
entry is mnemon's. Adding a second entry alongside it is mechanically straightforward.

**What isn't established is whether that mount is per-group or shared across every group.**
The mount table inside a container shows the target, not the source path. This repo's own
layout suggests per-group (`data/v2-sessions/<group-id>/.claude-shared/…`), but "mounted
from the Mac host" is compatible with either, and if it's shared then a wiki-trigger hook
registered there fires for *every* group — including ones with no wiki, where it errors on
every prompt. Settle it host-side (`docker inspect` the group's container, or look at what
`$NANOCLAW_INSTALL_PATH/data/v2-sessions/` actually contains).

Two things follow either way:

- **The hook must self-gate** — exit 0 immediately if `wiki-trigger-keywords.txt` is
  absent. Cheap insurance regardless of the answer.
- Putting the script in `/workspace/agent/hooks/` while registering it in a possibly-shared
  `settings.json` happens to work, because every group has its own `/workspace/agent` — but
  that's a coincidence rather than a design, and it is only safe with the gate.

### Revised ordering

| Step | Status |
|---|---|
| `lint.ts` — frontmatter coverage, legacy `nodes:`, broken links, orphans | **Start now.** Real findings on day one; needs no schema and no SQLite. |
| `build-index.ts` + `context-for.ts` as a pair, FTS5 over body only | **Promoted from "wait".** 632 pages needs search; body-text indexing needs no schema. |
| Schema decision — document types vs. a new entity layer | **Before any `relations` work.** Collaborative, not scripted. |
| `timeline.ts` | After relations exist. Nothing to render from one page. |
| `keywords.ts` + hook | Last, gated on the shared-vs-per-group answer, self-gating regardless. |
| Vector leg | Worth having at this corpus size; blocked while Ollama is down (see `docs/lessons-learned/general.md`, 2026-08-15). |

### The conventions tier is free, with one dependency worth naming

Typed `relations` blocks, quoted date literals, `generated:` provenance, and
`superseded_by:`/`supersedes:` on replacement all cost nothing and compound. But "assert both
directions of a relation on ingest," proposed as discipline rather than code, is exactly the
discipline that decays silently — which is why the spec makes asymmetric relations a **lint
check** instead of a rule. That item doesn't hold without `lint.ts`, which is an independent
argument for the same ordering: lint first.

## Related

- `environments/nanoclaw-mnemon/GIST-PARITY.md` — the first gist, the five surveyed wiki
  implementations, and the credibility caveat this document corroborates.
- `environments/nanoclaw-mnemon/MNEMON-RECALL-POLICY.md` — the prose-policy answer to the
  problem §12's hook solves.
- `environments/nanoclaw-mnemon/scripts/scaffold-wiki.sh` — what exists today.
