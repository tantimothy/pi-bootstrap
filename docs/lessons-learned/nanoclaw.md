# NanoClaw Environment — Debugging & Setup Lessons Learned

This file holds every real debugging session specific to this environment,
each as its own dated section below — not just one story. Add a new `## `
section here the next time a real issue in this environment gets root-caused
and fixed, rather than starting a separate file.

## Porting the Approval-Card Silent Delivery Fix from `nanoclaw-mnemon`

**Status:** fix implemented — not yet merged.

### Summary

`nanoclaw-mnemon`'s own investigation (see
`docs/lessons-learned/nanoclaw-mnemon.md`'s "Approval-Card Silent Delivery
Failure" section for the full root-causing) found and fixed a real upstream
NanoClaw bug: `requestApproval()` (`src/modules/approvals/primitive.ts`)
silently drops an approval card — logging apparent success — whenever
`getDeliveryAdapter()` returns falsy, instead of failing loudly. This
environment clones the exact same `nanocoai/nanoclaw` source, so the same
bug applies here — but porting the fix wasn't a pure copy-paste: this
environment supports **two** deploy modes (`NANOCLAW_DEPLOY_MODE=container`
or `host`), each with its own patch-application mechanics, and the bug
itself needed to be checked against each mode's actual architecture rather
than assumed identical.

### Issue Found & Fixed

#### Working out which of the three existing source patches actually generalize to host mode

**Context:** this environment already carries two idempotent text-splice
patches against the cloned NanoClaw source —
`scripts/patch-host-gateway.cjs` (OrbStack's broken `host-gateway`
resolution) and `scripts/patch-nohup-autostart.cjs` (NanoClaw's setup
wizard never running the nohup fallback it writes) — both wired into
**container mode only**. Before assuming the same was an oversight that
also needed fixing for the new approval-delivery patch, each one was
checked against what it actually fixes:

- **`patch-nohup-autostart.cjs` is correctly host-mode-exempt, not a gap.**
  It exists because `setupNohupFallback()` only runs when NanoClaw's setup
  wizard detects no systemd/launchd. Host mode is *defined* as running
  under real systemd/launchd — the wizard registers a proper service unit
  there and this fallback code path never executes at all. Applying this
  patch in host mode would be a correct no-op, and wiring it in either way
  changes nothing.
- **`patch-host-gateway.cjs` is only relevant in an unusual combination.**
  It fixes OrbStack's Docker Desktop resolution — but host mode is Linux's
  *default* (macOS defaults to container mode), and on real bare-metal
  Docker the patch is a deliberate no-op by its own design (the token and
  the computed gateway already resolve to the same address there — see the
  patch script's own header). It would only matter for someone explicitly
  overriding `NANOCLAW_DEPLOY_MODE=host` on a Mac running OrbStack.
- **`patch-approval-delivery.cjs` needed porting unconditionally.** The bug
  is plain application logic in the approval-request/delivery code path —
  nothing about being a bare host process vs. a containerized one changes
  whether a falsy delivery adapter silently drops the card. A host-mode
  Telegram approval is exposed to the exact same failure.

**Fix — container mode:** copied `scripts/patch-approval-delivery.cjs`
in unchanged (it's install-path-generic) and wired it into both existing
`patch-host-gateway.cjs` call sites: the pre-sync check against an
already-built existing install (`run.sh`, combining both patches' exit
codes into one rebuild-if-either-fired-exit-2 decision), and the
post-clone/CLEAN-sync call (covered by that branch's own unconditional
"rebuild if source was synced" logic further down, so no separate
rebuild dance needed there).

**Fix — host mode:** a direct `node "$SCRIPT_DIR/scripts/patch-approval-delivery.cjs"
"$INSTALL_PATH"` call (no `docker exec` wrapper — NanoClaw's own
orchestrator process isn't containerized in host mode, so there's no
container to exec into), placed after the clone/CLEAN-sync block and
before the unconditional `bash nanoclaw.sh` wizard hand-off. That wizard
call always rebuilds from whatever's on disk, for both a fresh install and
a `CLEAN` resync, so no separate exit-code-driven rebuild/restart logic was
needed here either — unlike container mode, which live-patches an
already-running container and has to decide whether a rebuild+restart is
actually warranted.

**Known, deliberate non-fix:** host mode's `FAST` policy against an
already-running (or registered-but-stopped) service returns early without
touching `$INSTALL_PATH`'s source at all — not just skipping this patch,
but skipping literally everything else that touches source too, including
a plain `git pull`. This was true before this fix and stays true after
it: `FAST` in host mode means "make sure the service is running," full
stop. Only `CLEAN` or a genuinely fresh install reaches any of the three
patches. Extending `FAST` to detect-and-rebuild an existing host-mode
install is a separate, larger design change, deliberately left alone here.

### General Lessons

- **A shared upstream dependency cloned into two different environments
  needs its fixes ported deliberately — nothing shares code between
  `environments/*/` folders.** `nanoclaw` and `nanoclaw-mnemon` both clone
  `nanocoai/nanoclaw` independently; a patch script added to one doesn't
  reach the other without an explicit copy + rewiring pass.
- **"This environment has two deploy modes" means checking a ported fix
  against both, not just wiring it in wherever the last similar patch
  happened to live.** Two of the three existing patches here are
  container-mode-only for real architectural reasons (no-systemd
  detection, OrbStack-specific), not because host mode was overlooked —
  assuming the third patch needed identical treatment without checking
  would have either silently no-op'd it (fine) or missed that it actually
  needed a different mechanism (`docker exec` piping doesn't apply when
  there's no container at all).
- **Whether a bug is "topology-specific" or "plain application logic" is
  worth answering explicitly before assuming a companion patch does or
  doesn't generalize.** The two existing patches happen to be topology
  bugs (no-init-system, OrbStack-networking); this one isn't — the
  distinction changes which deploy modes actually need the fix, not just
  how the fix gets mechanically applied.

### Related PRs

- (this fix — PR link filled in once opened)
