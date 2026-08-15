# OKF Graph Wiki — a second gist by the same author, and what it would mean here

**Status: evaluated, not built, not currently planned.** This document exists because
the gist it analyses explicitly evaluates and rejects mnemon — the component
`environments/nanoclaw-mnemon/` is named for — and its stated reasons check out against
mnemon's real schema. That's worth having on record whether or not anything gets built.

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

## Related

- `environments/nanoclaw-mnemon/GIST-PARITY.md` — the first gist, the five surveyed wiki
  implementations, and the credibility caveat this document corroborates.
- `environments/nanoclaw-mnemon/MNEMON-RECALL-POLICY.md` — the prose-policy answer to the
  problem §12's hook solves.
- `environments/nanoclaw-mnemon/scripts/scaffold-wiki.sh` — what exists today.
