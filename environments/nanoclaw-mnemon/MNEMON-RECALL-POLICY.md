# Mnemon Recall Policy

This document applies only to the `nanoclaw-mnemon` environment, where Mnemon
is installed in each group agent container. It extends the shared NanoClaw
cost-and-fidelity policy with targeted cross-session recall rules.

## Lifecycle

`run.sh` installs this extension on every `FAST` or `CLEAN` deployment, and
`scripts/scaffold-wiki.sh <group>` installs it when a wiki is scaffolded. It
updates only the text between
`PI_BOOTSTRAP_MNEMON_RECALL_POLICY_START` and
`PI_BOOTSTRAP_MNEMON_RECALL_POLICY_END` in a group's `CLAUDE.local.md`.
Other group instructions remain untouched.

## Managed instructions

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

This avoids an unreliable instruction to guess whether Mnemon might help. The
agent has clear triggers for one narrow recall while keeping source archives,
manifests, and the wiki authoritative for raw source material.

## Customization

Do not edit the marker-delimited block directly; deployment replaces it.
Add group-specific Mnemon instructions elsewhere in the group's
`CLAUDE.local.md`. To update the shared Mnemon behavior, edit
[`scripts/apply-mnemon-recall-policy.sh`](./scripts/apply-mnemon-recall-policy.sh)
and redeploy.
