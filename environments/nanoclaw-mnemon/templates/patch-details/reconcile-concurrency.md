**What it changes.** `src/host-sweep.ts` hardcodes
`export const RECONCILE_CONCURRENCY = 8;`, the number of sessions the host
sweep wakes/spawns in parallel each tick. This patch replaces that literal with
a version-marked block (`pi-bootstrap:reconcile-concurrency`) that reads
`NANOCLAW_RECONCILE_CONCURRENCY` from the process environment, then from
NanoClaw's own `.env` (read from the service's working directory), then falls
back to `8`. Accepts an integer 1-64; anything else warns and uses `8`. With
nothing set, behavior is unchanged.

**When to set it.** When many scheduled tasks share one cron slot and each
reconcile is a full agent container doing real work. Symptoms seen: host load
far above core count, `onecli-postgres-1` pinned near 100% CPU, OneCLI
`/v1/agents` returning 408, NanoClaw killing sessions with
`reason="gateway-unavailable"` in a loop that a restart does not clear (the
due-task backlog lives in `data/v2.db`). `2` was enough on an 8-core host. Put
`NANOCLAW_RECONCILE_CONCURRENCY=2` in NanoClaw's `.env` (the install
directory's, not this environment's) and redeploy or restart.

**Anchors.** `export const RECONCILE_CONCURRENCY = 8;` exactly once. If the
file was hand-edited or upstream changed the line, the patch is skipped and
says so; nothing is spliced blind. It rebuilds and restarts NanoClaw when it
freshly applies or upgrades its block.

**What a correct fix has to look like.** Touch only `src/host-sweep.ts`.
`src/config.ts` is owned by the Ollama patch and excluded from CLEAN's
local-edit snapshot, so any new export added there is lost while a reapplied
host-sweep edit would still import it and fail `tsc`. `src/host-sweep.ts` is
excluded from that snapshot too, so this patch is its only owner. Bump
`VERSION` in `scripts/patch-reconcile-concurrency.cjs` on any change to the
block. Upstreaming an env override would make this patch unnecessary.

**Verified.** Against a fresh clone of upstream `main`: applies, idempotent
rerun, `tsc --noEmit` clean. Not yet verified on a real install.
