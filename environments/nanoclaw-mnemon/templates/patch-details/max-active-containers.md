**What it changes.** `src/container-runner.ts` has no limit on how many agent
containers run at once. `wakeContainer()` gets one early return, after the
"already running" and "wake already in flight" short-circuits and before
`spawnContainer()`: if the number of distinct sessions that are running or
mid-spawn is at `NANOCLAW_MAX_ACTIVE_CONTAINERS`, it logs
`Deferring container spawn — active-container cap reached` and returns `false`.
The caller ignores that value, so the due message is untouched (no `tries`
penalty, no backoff) and the next sweep tick (up to 60s) retries it. Running
containers are never killed. The value is read from the process environment,
then NanoClaw's `.env` (service working directory); integer 1-64, anything else
warns and disables the cap. Unset means unbounded (upstream behavior). The
helpers live in a version-marked block (`pi-bootstrap:max-active-containers`)
at the end of the file.

**Why `NANOCLAW_RECONCILE_CONCURRENCY` is not enough.** That bounds the sweep's
own parallel `reconcileSession()` calls, but each returns as soon as a spawn is
requested, so a backlog drains in seconds while the spawned containers run for
minutes. Only this cap bounds live containers. The two settings are independent;
`2` for both held an 8-core host steady.

**When to set it.** Load far above core count, OneCLI `/v1/agents` timing out,
and sessions killed with `reason="gateway-unavailable"` in a loop after several
tasks share a cron slot. Note that `ncl tasks pause` stops future recurrences
but does not pull an already-overdue message out of the sweep. After
deploying, confirm a `Deferring container spawn` line appears under real load.

**Anchors.** `  const promise = spawnContainer(session)` exactly once. A missing
anchor skips the patch and says so; nothing is spliced blind. A fresh apply
rebuilds and restarts NanoClaw.

**What a correct fix has to look like.** Touch only `src/container-runner.ts`
and do not depend on `src/config.ts`; both are excluded from CLEAN's local-edit
snapshot, so hand edits there (or an import of a hand-added export) are lost
or break `tsc`. Bump `VERSION` in `scripts/patch-max-active-containers.cjs` on
any change. Upstreaming this as a default-off env override would remove the
need for the patch.

**Verified.** Against a fresh clone of upstream `main`: applies, idempotent
rerun, `tsc --noEmit` clean. The deferral path was not exercised under load, and
this has not run on a real install.

**Verifying the cap was followed (operator, from the host).** The patch logs
at INFO: `Deferring container spawn — active-container cap reached` with
`sessionId`, `cap` and `active`. Spawns log `Spawning container
containerName=...`; finishes log `Container exited` (sometimes missing, so do
not rely on it alone). After an incident:

```bash
docker logs nanoclaw-mnemon --since 30m 2>&1 | grep -E "Spawning container|Deferring container spawn|Container exited|gateway-unavailable"
```

A pass looks like: `active` never exceeds `cap` in any `Deferring` line;
spawn lines are never more than `cap` ahead of exits; at least one
`Deferring` line while a backlog drained; no `reason="gateway-unavailable"`
kills. For ground truth that does not depend on NanoClaw's own bookkeeping,
count the live containers while it happens (names are `nanoclaw-v2-*`):

```bash
watch -n2 'docker ps --filter name=nanoclaw-v2- --format "{{.Names}}" | wc -l'
```

**Verifying it from inside this container (admin `claude` session).** You
cannot run `docker` here, but NanoClaw's own log is on disk in the install
directory. Do these in order and report each result:

1. Confirm the patch is live: the status line for this section above must say
   `applied` or `already applied`, not `SKIPPED`. Then
   `grep -c "pi-bootstrap:max-active-containers" src/container-runner.ts`
   (expect 3: two markers and the call-site marker) and
   `grep NANOCLAW_MAX_ACTIVE_CONTAINERS .env` (expect a value; empty or absent
   means the cap is off).
2. Find the log (the expected path is `logs/nanoclaw.log`; if it is missing run
   `ls logs/`) and extract the window of interest:
   `grep -E "Spawning container|Deferring container spawn|Container exited|gateway-unavailable" logs/nanoclaw.log | tail -200`
3. Check the cap held: for every `Deferring` line, `active` must be `>= cap`
   (that is why it deferred); no point in the window may show more spawns than
   `cap` between exits. Count spawns per minute, and note any
   `gateway-unavailable` kill.
4. If there were due tasks but no `Deferring` line at all, say so plainly. It
   means either the load never reached the cap or the cap is not enforced.
   Do not report success on the absence of errors alone.

**Reporting.** Append a dated entry to `pi-bootstrap-patch-fixes.md` with:
the configured `cap`, the window checked, spawn/defer/exit counts, the peak
`active` seen, and any anomaly. Include verbatim log lines, not a summary. A
report that the cap was exceeded, or never fired under load, is what tells a
human to revisit the patch.

**Limits of this check.** After a NanoClaw restart, containers it adopts are
not killed and count toward `active`, so the live count can briefly exceed
the cap. Only `wakeContainer()` is gated; the `docker ps` count is the real
test of whether any other path spawns containers.
