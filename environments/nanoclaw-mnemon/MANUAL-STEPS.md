# Manual deployment and profile selection

`run.sh` is the supported deployment path. This document records the equivalent
profile decisions for operators who need to inspect or reproduce them manually.
This is the repository's only NanoClaw environment; the former
`environments/nanoclaw` environment has been retired.

## 1. Select the profile

Set one of these in this environment's `.env`:

```bash
# Default when omitted
NANOCLAW_SETUP=mnemon

# Plain NanoClaw agent image
# NANOCLAW_SETUP=plain
```

`mnemon` adds the Mnemon agent-image patch, optional Ollama embeddings, wiki
scaffolding, and agent media tools. `plain` leaves the upstream NanoClaw agent
image unmodified by those features. Both profiles remain container-only and
receive the shared group cost-and-fidelity policy.

## 2. Deploy or change profile

For a first deployment, run this environment's `run.sh` with your selected
value in `.env`. To change an existing deployment between `plain` and
`mnemon`, run a `CLEAN` deployment:

```bash
cd environments/nanoclaw-mnemon
REBUILD_POLICY=CLEAN ./run.sh
```

`CLEAN` resets the NanoClaw source checkout to upstream before applying the
selected profile and rebuilding the agent image. It preserves `.env`, `groups/`,
`data/`, `store/`, and `dist/`, but discards manual edits made directly in the
NanoClaw checkout.

## 3. Mnemon profile patch details

Only when `NANOCLAW_SETUP=mnemon`, `run.sh` applies NanoClaw's documented
Mnemon integration to the upstream agent image:

- downloads the pinned `MNEMON_VERSION` binary into `container/Dockerfile`;
- runs `mnemon setup --yes --global` in the agent entrypoint, so its Claude
  Code hooks use each group's persistent `.claude-shared` state;
- optionally configures `MNEMON_EMBED_ENDPOINT` and `MNEMON_EMBED_MODEL`;
- adds the supported media-tool patch.

The script applies these changes before NanoClaw's first agent-image build and
does so idempotently. For the exact policy installed into group instructions,
see [GROUP-POLICY.md](./GROUP-POLICY.md) and
[MNEMON-RECALL-POLICY.md](./MNEMON-RECALL-POLICY.md).

## 4. Important data boundary

Profile selection changes the agent image; it does not merge data from an old,
separate NanoClaw installation. Back up the old installation's `groups/`,
`data/`, and `.env` before retiring it. Review paths and credentials before
copying anything into this installation.
