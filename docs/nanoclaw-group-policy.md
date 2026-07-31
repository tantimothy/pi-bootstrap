# NanoClaw Group Cost and Knowledge-Fidelity Policy

Both `nanoclaw` and `nanoclaw-mnemon` install a managed policy in every
existing group's `CLAUDE.local.md`. It gives the agent a standing instruction
to conserve shared monthly LLM capacity without trading away source fidelity.

## Lifecycle

- `FAST` and `CLEAN` deployments update every existing immediate subdirectory
  of `$NANOCLAW_INSTALL_PATH/groups/`.
- `nanoclaw-mnemon`'s `scaffold-wiki.sh <group>` applies it immediately to a
  newly scaffolded group.
- The installer owns only the text between
  `PI_BOOTSTRAP_COST_AND_FIDELITY_POLICY_START` and
  `PI_BOOTSTRAP_COST_AND_FIDELITY_POLICY_END`. Group-specific instructions
  outside those markers are preserved.
- The durable target is `CLAUDE.local.md`, not `CLAUDE.md`: NanoClaw composes
  the latter afresh when it spawns an agent.

The policy is intentionally qualitative. It makes the agent optimize for a
constrained monthly resource without pretending it knows a hard budget. It
does not enforce spend limits; configure those separately at the model gateway
or API account if enforcement is required.

## Managed policy

### Cost discipline

- Treat LLM usage as a constrained shared monthly resource. Minimize token use
  whenever doing so does not reduce correctness, safety, or source fidelity.
- Prefer local, deterministic work first: file listing, hashing,
  deduplication, metadata inspection, text extraction, and link/asset
  validation.
- Work incrementally from the source manifest, index, and changed inputs. Do
  not re-read, re-summarize, or rewrite unchanged material.
- Read only the source sections needed for the task; batch related work; avoid
  speculative research and broad maintenance sweeps.
- Keep responses and logs concise. Do not narrate routine progress, repeat
  plans, or duplicate information.
- Before unusually large ingest, reprocessing, or maintenance work, state the
  expected scope and ask for approval.
- For work involving an existing topic, project, person, decision, preference,
  prior source, or cross-session question, run one focused mnemon recall first
  using the task's named entities and key terms.
- For a wholly new, self-contained source ingest, begin from the source
  manifest and wiki. Recall mnemon if the source refers to an existing
  entity/topic or the task requires reconciliation with prior knowledge.
- Reuse that recall for the current task; do not perform broad or repeated
  exploratory recalls unless the task scope materially changes.
- Store durable relationships, decisions, and preferences in mnemon. Do not
  store routine ingest bookkeeping or duplicate source text there.
- Never reduce source fidelity merely to save tokens: preserve originals,
  URLs, diagrams, provenance, and uncertainty.

### Source-of-truth and no-loss rule

- `sources/` is the immutable source archive. Never delete, overwrite,
  truncate, or replace original files.
- The wiki is derived knowledge, not a replacement for sources or mnemon.
- Every ingested source needs a stable source ID, original filename, SHA-256
  hash, source URL if applicable, retrieval date, and ingest status.
- Every factual wiki claim must cite its source ID and a precise locator:
  page, heading, timestamp, or quoted passage.
- Preserve URLs exactly. Keep the original URL and any local/archive copy path;
  never replace a URL with a summary.
- Preserve diagrams and media: retain the original file, URL, embed, or source
  code; retain extracted image assets; add textual descriptions only as
  supplementary accessibility metadata.
- Preserve Mermaid and other diagram source verbatim when available.

### Safe incremental ingest and maintenance

1. Register or verify the source in the manifest; hash it and skip identical
   already-ingested content.
2. Preserve the raw original before extracting or summarizing.
3. Extract locally where possible; send only relevant chunks to the model.
4. Update or add wiki pages with provenance and cross-links.
5. Update `index.md` and append an ingest record to `log.md`.
6. Verify every cited local asset and link exists. Record extraction limitations
   rather than silently omitting content.

Maintenance is incremental only: changed sources, broken links, stale pages,
or explicitly requested scope. Never silently remove information; mark it as
superseded or deprecated and link to its replacement. Do not perform broad
rewrites, consolidation, or deletion without explicit approval. When sources
conflict, preserve both claims with provenance and describe the conflict.

## Operator customization

Add group-specific rules outside the managed markers in that group's
`CLAUDE.local.md`. Do not edit inside the markers: the next deployment replaces
that block deliberately so all groups receive future policy improvements.

To change the baseline for all groups, update
[`lib/apply-nanoclaw-group-policy.sh`](../lib/apply-nanoclaw-group-policy.sh)
and redeploy. A direct manual invocation is also available:

```bash
bash lib/apply-nanoclaw-group-policy.sh "$NANOCLAW_INSTALL_PATH"
bash lib/apply-nanoclaw-group-policy.sh "$NANOCLAW_INSTALL_PATH" <group-folder>
```
