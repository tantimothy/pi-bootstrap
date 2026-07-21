# NanoClaw-Mnemon Environment — Debugging & Setup Lessons Learned

This file holds every real debugging session specific to this environment,
each as its own dated section below — not just one story. Add a new `## `
section here the next time a real issue in this environment gets root-caused
and fixed, rather than starting a separate file.

## Mnemon Hook Registration

**Status:** retrospective. The fix below is merged (PRs
[#130](https://github.com/tantimothy/pi-bootstrap/pull/130),
[#131](https://github.com/tantimothy/pi-bootstrap/pull/131),
[#132](https://github.com/tantimothy/pi-bootstrap/pull/132),
[#133](https://github.com/tantimothy/pi-bootstrap/pull/133)) and confirmed
working against a real, live deploy — this document is the record of what
was tried, what was wrong about each attempt, and why.

### Summary

`run.sh`'s `apply_mnemon_patch()` patches a `mnemon setup` invocation into
NanoClaw's own agent-sandbox `container/entrypoint.sh`, run on every agent
container start, so mnemon's Claude Code hooks register automatically —
no manual `/add-mnemon` skill run needed. The patched command went through
two wrong versions, both reasoned from mnemon's own README, before a
third — verified against real, live container behavior instead — actually
worked.

### Issue Found & Fixed

#### Mnemon's Claude Code hooks never actually registered in a real group

**Symptom:** The patch applied cleanly on every `CLEAN` deploy, and the
agent container started without error. But a real conversation group's
own `~/.claude/settings.json`, checked after real use, only ever showed
NanoClaw's own two built-in hooks (`PreCompact`, `SessionStart`) — never
any of mnemon's. Confirmed directly via `docker ps -a --filter
"name=nanoclaw-agent"` that agent containers are ephemeral (spawned fresh
per message, `--rm` on exit) — so there was no live container to `docker
exec` into and inspect after the fact; the only way to see what actually
happened was to reproduce the exact command manually inside a fresh
container.

**Attempt 1 — wrong:** `mnemon setup --target claude-code --yes --global`
(this environment's original patched invocation, matching mnemon's own
documented flags for explicitly targeting Claude Code). Ran without
erroring on every container start, but produced the symptom above.

**Attempt 2 — also wrong:** Bare `mnemon setup --yes`, with `--target`/
`--global` removed entirely. Reasoned from mnemon's own README, which
shows no `--target`/`--global` flags for its Claude Code integration
section specifically — unlike every other integration target it
documents (Codex, Cursor, TRAE, Nanobot, etc.), which all explicitly show
`--target <name>`. Looked like the more-correct reading of the docs.

Confirmed wrong the same way attempt 1 was confirmed wrong — but this
time by actually running `mnemon setup --yes` **interactively inside a
real agent-sandbox container** (`docker run --rm -it --entrypoint bash
...`) rather than just reasoning from the README a second time. It
printed `Settings .claude/settings.json updated` and exited successfully
— genuinely did *something* — but `cat ~/.claude/settings.json`
immediately after came back `No such file or directory`. The command had
auto-detected Claude Code correctly and written hooks to a
**project-local** `.claude/settings.json`, relative to `entrypoint.sh`'s
own working directory (`/workspace/group` in this image) — not the
**global** `~/.claude/settings.json` (`/home/node/.claude/settings.json`)
that NanoClaw actually bind-mounts per group from
`data/v2-sessions/<id>/.claude-shared`, and that Claude Code actually
reads at runtime.

**Attempt 3 — the actual fix:** `mnemon setup --yes --global` (auto-detect
kept, `--target claude-code` still omitted, `--global` added back).
Confirmed the same way, live inside the same container: `~/.claude/settings.json`
correctly received mnemon's hooks this time. Confirmed a second time,
independently, after a full `CLEAN` redeploy against a real Mac install —
a real group's `~/.claude/settings.json` came back with mnemon's hooks
present alongside NanoClaw's own two.

### General Lessons

- **A documented example that "looks like" your use case can still be
  wrong for your specific working directory.** mnemon's own docs never
  claim `mnemon setup --yes` writes to a *global* path — that assumption
  came from pattern-matching "no flags shown" to "no flags needed," not
  from anything the docs actually stated. The real, decisive fact (which
  working directory a relative-path side effect resolves against) isn't
  something a flag-reference table can show at all; it's a property of
  the specific container the command runs inside.
- **When a patched command "succeeds" (no error, expected log output),
  that doesn't mean it did what you think.** Both wrong attempts exited
  cleanly and mnemon even printed a plausible-looking success message on
  attempt 2 — the failure was entirely in *where* the side effect landed,
  invisible to exit codes or stdout alone. Only checking the actual
  resulting file, inside the actual container, caught it.
- **Verify against the real, running container — not the flag list in a
  README — before shipping a fix, and say so explicitly once you have.**
  See `environments/nanoclaw-mnemon/README.md`'s "Verified directly
  against a real deploy" section for the pattern this repo uses to record
  that distinction (tested-and-confirmed vs. reasoned-from-docs) for every
  claim, not just this one.
- Once the root cause was fixed for *new* container spawns, groups whose
  `.claude-shared` directory had already been written by a broken version
  needed separate remediation — a rebuilt image alone doesn't retroactively
  fix already-existing host-side data. `scripts/reload-mnemon.sh` re-runs
  the corrected command directly against a specific group's real,
  persistent directory, with no chat round-trip (and therefore no need to
  wait for that group's next real message to spawn a fresh container)
  needed. Its own group-selection UX went through one more round of
  feedback-driven refinement after initially requiring the group's raw
  `ag-<timestamp>-<hash>` session ID by hand — it now auto-discovers real
  group names from NanoClaw's own `data/v2.db`, auto-picking if there's
  only one or prompting with a numbered list otherwise.

### Related PRs

- [#130](https://github.com/tantimothy/pi-bootstrap/pull/130) — attempt 2
  (bare `mnemon setup --yes`) — merged, later found to be a regression
- [#131](https://github.com/tantimothy/pi-bootstrap/pull/131) — attempt 3,
  the actual fix (`mnemon setup --yes --global`), plus the honest
  "two corrections" writeup in the README
- [#132](https://github.com/tantimothy/pi-bootstrap/pull/132) —
  `scripts/reload-mnemon.sh`, remediation for groups already affected by
  the earlier broken versions
- [#133](https://github.com/tantimothy/pi-bootstrap/pull/133) —
  `reload-mnemon.sh`'s group auto-discovery, replacing the manual-ID-required
  UX

---

## Approval-Card Silent Delivery Failure

**Status:** fix implemented (`environments/nanoclaw-mnemon/scripts/patch-approval-delivery.cjs`,
wired into `run.sh` alongside the existing `patch-host-gateway.cjs` call) —
not yet merged.

### Summary

An agent's `install_packages` self-mod approval request sat in
`pending_approvals` with `status='pending'` for over a week, re-requested 3
separate times, and the approval card **never once appeared** in the
owner's Telegram DM — with nothing in the logs indicating any failure at
all. Investigation (full writeup: a NanoClaw-repo incident report supplied
by the operator, not reproduced here) traced this to NanoClaw's own
`src/modules/approvals/primitive.ts`, and the fix is patched in at deploy
time the same way `patch-host-gateway.cjs` already patches
`src/container-runtime.ts` — this environment doesn't vendor NanoClaw's
source, so an upstream bug fix has to be applied as an idempotent text
splice against the freshly cloned tree, not a direct edit.

### Issue Found & Fixed

#### `requestApproval()` silently no-ops when no delivery adapter is set

**Symptom:** Three `pending_approvals` rows stuck since Jul 14/17/21, all
for the same action, with no delivery-failure log line
(`Failed to deliver approval card`) and no "no adapter"/"no owner
configured" fallback message ever appearing either — the code has both of
those failure paths, and neither fired.

**Root cause:** `requestApproval()`'s delivery call was shaped
`if (adapter) { try { await adapter.deliver(...) } catch { ...handle... } }`
with no `else` branch. When `getDeliveryAdapter()` returns falsy, the
entire block is skipped — no error, no cleanup, no notification — and
execution falls straight through to the function's own closing
`log.info('Approval requested', ...)`, logging apparent success despite
never attempting delivery. The delivery mechanism itself was proven sound
by two live tests directly against `chat-sdk-bridge.ts`'s `deliver()` (no
mocking) — the bug is entirely in this silent-no-op shape upstream of it.
Root cause for *why* the adapter was null at those specific moments inside
the long-running host process was not conclusively pinned down (leading,
unconfirmed hypothesis: `getDeliveryAdapter()` racing container/service
startup) — the fix addresses the silent-failure symptom regardless of
which specific cause triggers it.

**Fix:** `if (!adapter) { ...same log-error/delete-row/notify-agent
handling as the existing catch block... return; }` before the `try`, so a
missing adapter fails exactly as loudly as a `deliver()` throw already
did. Also fixed `createPendingApproval()`'s call at this same site to
persist `agent_group_id`/`channel_type`/`platform_id` (previously always
`NULL` here, unlike the sibling OneCLI credential-approval flow in
`onecli-approvals.ts` which already sets them) — not the delivery bug
itself (the click-resolution path looks the row up by `approval_id` alone
and never reads those columns), but worth fixing for consistency while
touching this call.

### General Lessons

- **`if (thing) { try {...important work...} catch {...} }` with no
  `else` is a silent-no-op trap**, not just an incomplete error path — a
  falsy `thing` skips the whole block and, unless the surrounding function
  has nothing left to fall through to, can end up logging a *success*
  message for work that never happened. Worth grepping for this exact
  shape anywhere delivery/notification is conditional on a possibly-null
  singleton.
- **"No error in the logs" is not evidence nothing went wrong** — it's
  only evidence none of the code's own explicit failure branches fired.
  The stuck-approval symptom here produced zero log signal for a week
  specifically because the one code path that *could* have logged
  something was the one being skipped entirely.
- **Live-testing the delivery mechanism in isolation, separately from the
  code path that's supposed to invoke it, is what actually located the
  bug.** Both layers looked plausible individually (adapter code: proven
  fine; call site: no visible error) — the gap only became visible by
  testing each independently against the real chat rather than trusting
  either one's absence of errors.
- **An upstream bug fix in a cloned (not vendored) dependency needs the
  same idempotent patch-at-deploy-time treatment as any other patch this
  environment applies** — a local, uncommitted edit to the source tree
  used for the original investigation doesn't reach a fresh install or an
  existing one's next `CLEAN` re-sync on its own.

**Ported to the plain `nanoclaw` environment**, which clones the same
upstream source: see `docs/lessons-learned/nanoclaw.md` for the porting
details, including why host mode needed different wiring than container
mode.

### Related PRs

- [#149](https://github.com/tantimothy/pi-bootstrap/pull/149) — this fix,
  plus the port to the plain `nanoclaw` environment (both deploy modes)

## yt-dlp / python3 Dependency Chain

**Status:** retrospective. Every fix below is merged (PRs
[#124](https://github.com/tantimothy/pi-bootstrap/pull/124),
[#126](https://github.com/tantimothy/pi-bootstrap/pull/126),
[#127](https://github.com/tantimothy/pi-bootstrap/pull/127)) and confirmed
against a real, live agent successfully transcribing a video end-to-end —
this document is the record of how a one-line diagnosis ("python3 is
missing, please install it") turned out to be masking three independent,
compounding bugs, each only found by tracing the actual failure instead of
accepting the stated symptom.

### Summary

A live agent ("Clawdia") hit `yt-dlp: python3: No such file or directory`
and filed a proper `install_packages` approval request: install `python3`
via `apt`. The request's own reasoning ("yt-dlp shells out to a python3
interpreter") sounded plausible and matched the literal error — but this
environment's own Dockerfile comment already claimed `yt-dlp` was installed
specifically as "the standalone, dependency-free binary release" to avoid
needing Python at all. That contradiction was the first sign the stated
diagnosis was wrong, and approving the literal ask (installing `python3`)
would have reintroduced a dependency this environment had deliberately
designed around, rather than fixing the actual bug. Four rounds of
"should be fixed now" followed before the real, full fix actually landed —
each round exposed one more layer.

### Issues Found & Fixed

#### 1. Wrong yt-dlp release asset — needs python3 despite the "standalone" comment

**Symptom:** `yt-dlp: python3: No such file or directory`, inside an image
that has no `python3` installed by design.

**Root cause:** `yt-dlp`'s GitHub releases publish several assets under
similar names. The plain `yt-dlp` asset — what both the orchestrator's
`Dockerfile` and the agent-sandbox patch (`apply_media_tools_patch()` in
`run.sh`) were downloading — is a zipimport script (shebang
`#!/usr/bin/env python3`) that still needs a system Python on `PATH` to
run at all. The actual standalone, dependency-free binary is a
differently-named asset (`yt-dlp_linux`, `yt-dlp_linux_aarch64`,
`yt-dlp_linux_armv7l`, depending on architecture) — the Dockerfile
comment's claim was aspirational, not verified against what URL it
actually pointed at.

**Fix:** Detect the build host's architecture via `uname -m` and download
the correct arch-matched standalone asset instead. Needed in both places
this environment builds a `yt-dlp`-bearing image: the orchestrator's own
`Dockerfile`, and the agent-sandbox patch text `run.sh` splices into
NanoClaw's own `container/Dockerfile`. `MANUAL-STEPS.md`'s hand-written
mirror of that same patch text still had the old broken line even after
both automated copies were fixed — found only by grepping the whole repo
for the literal download URL, not by assuming "fixed in the automated
path" meant "fixed everywhere the same snippet was copied."

#### 2. Fixing the orchestrator's Dockerfile didn't fix the agent's own container

**Symptom:** After the fix in #1 landed (merged, on `master`), the same
agent hit the identical error again.

**Root cause:** The orchestrator's own `Dockerfile` and the agent-sandbox
image are two entirely separate build artifacts. An agent like Clawdia
runs inside NanoClaw's own per-conversation-group agent-sandbox container
(built from `container/Dockerfile` *inside the NanoClaw checkout*, patched
at deploy time by `apply_media_tools_patch()` in this environment's
`run.sh`) — not inside the orchestrator container at all. The first fix
only touched the orchestrator's own copy of the same broken download line;
the agent-sandbox patch text in `run.sh` had an independent copy of the
identical bug, untouched.

**Fix:** Apply the identical `uname -m`-based fix to the heredoc block
`apply_media_tools_patch()` writes into `container/Dockerfile`.

**Lesson:** the same broken snippet existed in two independent places
because it had been copy-pasted between them rather than shared — fixing
one is not evidence the other is fixed too. Before declaring a bug fixed,
grep the whole repo for the same literal pattern, not just the one file
that was actually touched.

#### 3. `CLEAN`'s own local-edit-preservation step silently revived the stale patch

**Symptom:** After the fix in #2 was merged and a real `CLEAN` redeploy
run, the deploy log showed `✅ yt-dlp/ffmpeg/whisper.cpp already patched
into container/Dockerfile` — not the expected `🎙️ Patching
yt-dlp/ffmpeg/whisper.cpp...` — and the rebuilt agent-sandbox image still
had the old broken binary. Confirmed directly by grepping the actual
`container/Dockerfile` on the deploy host: it still had the pre-fix
one-liner, and `docker images`' timestamp for the agent-sandbox image
predated the whole incident.

**Root cause:** `CLEAN` has a separate mechanism (added to stop
channel/provider skills like `/add-telegram` from getting silently
unwired by the hard reset) that snapshots *every* locally-modified tracked
file as a patch before `git reset --hard`, then reapplies that patch
afterward — with no distinction between genuine skill wiring
(`src/channels/index.ts`, `package.json`) and `container/Dockerfile`/
`container/entrypoint.sh`, which `apply_mnemon_patch`/
`apply_media_tools_patch` already own and regenerate idempotently,
unconditionally, right after the reset. The (stale, pre-fix)
`container/Dockerfile` text got snapshotted, hard-reset away, then
reapplied verbatim on top of the freshly-synced source — so
`apply_media_tools_patch()`'s own idempotency check (`grep -q 'yt-dlp'`)
saw the *old* broken line again immediately and skipped re-patching,
exactly as if `CLEAN` had never run.

**Fix:** Exclude `container/Dockerfile`/`container/entrypoint.sh` from
that snapshot/reapply mechanism via git pathspec exclusion on both the
`status` and `diff` calls — those two files now always get a clean
hard-reset, and the patch functions see pristine upstream content to
patch fresh, every `CLEAN`.

**Lesson:** this meant no `CLEAN` could *ever* have picked up a fix to
either Dockerfile-patching function's generated text, not just this one —
a mechanism added to protect one category of local edit (user-installed
skill wiring) silently defeated a different category (this repo's own
idempotent codegen) that happened to look identical to git. When two
independent things both show up as "local modifications to a tracked
file," don't assume a blanket preserve-and-reapply mechanism is safe for
both just because it's safe for one.

#### 4. Post-deploy summary garbling into raw hex-byte escapes

**Symptom:** Surfaced in the same `CLEAN` run's captured log — the
post-deploy summary (`lib/info-lib.sh`, via `lib/run-info.sh`) printed
`<F0><9F><93><81>` etc. instead of emoji.

**Root cause:** `lib/locale-lib.sh` exists specifically to force a UTF-8
locale and prevent exactly this failure mode (its own header comment
documents this exact byte-escape example) — but it's sourced by
`deploy.sh` and the other top-level entry scripts only, never by any
per-environment `run.sh`, including this one. Invoking `run.sh` directly
(bypassing `deploy.sh`'s menu, as this deploy did) skipped that guard
entirely.

**Fix:** Source `lib/locale-lib.sh` early in this environment's `run.sh`,
matching `deploy.sh`'s own pattern. The same gap exists in every other
environment's `run.sh` in this repo (confirmed by checking, not fixed
here — see `docs/future-enhancements/nanoclaw-mnemon.md`).

#### 5. (Not a bug) whisper.cpp libs/model wiped from an agent's home directory

**Symptom:** After the real fix above finally landed and the agent
respawned onto the rebuilt image, the agent reported its previously
self-installed whisper.cpp libs/model were gone, and had to reinstall
them before transcription could proceed.

**This was expected behavior, not a new bug:** `/workspace/agent` is the
only path inside an agent's container that's bind-mounted to real host
storage (`$NANOCLAW_INSTALL_PATH/groups/<group>/`) and therefore survives
a respawn or image rebuild. Everything else, including the container's
own home directory, lives in the container's ephemeral layer and is
wiped on *any* respawn — not just a deliberate one; idle agent containers
get torn down and recreated routinely on their own regardless. The agent
had installed whisper.cpp's libs/model outside `/workspace/agent`, so
they were always going to disappear sooner or later — this rebuild just
happened to be the trigger this time. A prior agent (see
`environments/nanoclaw-mnemon/GIST-PARITY.md` and the README's
"Agent-improvised, rootless" section) already learned this same lesson
the hard way and moved everything into `/workspace/agent` specifically
because of it — worth surfacing that precedent proactively rather than
letting each agent rediscover it independently.

### General Lessons

- **An `install_packages` approval request's own stated diagnosis can be
  wrong, even when it matches the literal error message.** "python3 is
  missing" was true and would have made the immediate error go away, but
  the actual fix was "download the right binary," not "add the missing
  dependency" — approving the literal ask would have quietly reintroduced
  a dependency this environment was deliberately built to avoid. Trace the
  root cause before implementing (or approving) the stated fix, especially
  when the request's own reasoning conflicts with something already
  documented in the codebase (here, the Dockerfile's own "no Python
  needed" comment).
- **A fix applied to one file is not evidence it's fixed everywhere the
  same snippet exists.** The broken download line existed independently
  in three places (orchestrator `Dockerfile`, the agent-sandbox patch text
  in `run.sh`, and `MANUAL-STEPS.md`'s hand-written mirror of it) — each
  found only by grepping the whole repo for the literal pattern, not by
  assuming the one file already touched was the only copy.
- **Verify a fix actually took effect against real deploy output — build
  timestamps, log messages, the actual patched file's contents — before
  telling anyone to re-test.** Multiple "should be fixed now" messages in
  this saga were wrong: first because `CLEAN` had never actually been run
  yet, then because `CLEAN` ran but silently no-op'd due to issue #3 above.
  Both were only caught by asking for concrete evidence (`git log`,
  `grep`'d file contents, `docker images` timestamps) rather than trusting
  restated confidence.
- **A mechanism that protects one category of local file edit isn't
  automatically safe for a different category that looks identical to
  git.** `CLEAN`'s local-edit-preservation step didn't distinguish
  "user-installed channel-skill wiring" from "this repo's own idempotent
  Dockerfile codegen" — both are just "modified tracked files" from git's
  point of view, but only one of them should ever be snapshotted and
  reapplied blindly.
- **Container ephemeral storage claims another victim, exactly as
  documented.** An agent installing tools outside `/workspace/agent` will
  lose them on the next respawn regardless of what triggers that respawn
  — this had already been learned once (see the "Agent-improvised,
  rootless" README section) and happened again independently in this
  saga, suggesting the lesson needs to reach agents more proactively than
  a README section they may never read.

### Related PRs

- [#124](https://github.com/tantimothy/pi-bootstrap/pull/124) — issue #1's
  fix in the orchestrator's own `Dockerfile` only; confirmed later to be
  incomplete (issue #2)
- [#126](https://github.com/tantimothy/pi-bootstrap/pull/126) — issue #1's
  fix repeated in the agent-sandbox patch text (`apply_media_tools_patch()`
  in `run.sh`), the copy that actually reaches an agent's own container
- [#127](https://github.com/tantimothy/pi-bootstrap/pull/127) — issue #3
  (`CLEAN`'s local-edit-preservation step reviving the stale patch) and
  issue #4 (`lib/locale-lib.sh` not sourced by this environment's `run.sh`),
  both found only by tracing a real `CLEAN` run's own captured output
