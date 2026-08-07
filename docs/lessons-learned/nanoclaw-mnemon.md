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

## Live, Uncommitted NanoClaw Checkout Changes — Ollama + Telegram (2026-07-25)

**Status:** informational snapshot, not a bug report. This documents a
real user's in-progress, **uncommitted** local modifications to their own
`$NANOCLAW_INSTALL_PATH` checkout (the actual upstream NanoClaw repo,
patched into this environment at deploy time — not `pi-bootstrap` itself)
as of the date above, plus the `CLEAN`-safety implications of leaving them
uncommitted, per issue #3 above. No pi-bootstrap code changed as part of
this entry.

### Summary

`git status` inside the running container's install path showed two
distinct feature areas in progress, per the user's own categorization,
plus a few files whose attribution isn't fully certain and three files
that are normal generated runtime state rather than feature code at all.

**Ollama integration** (modified: `src/container-runtime.ts`; new:
`container/agent-runner/src/ollama-mcp-stdio.ts`,
`container/agent-runner/src/ollama-registration.test.ts`,
`src/ollama-env.ts`, `src/ollama-wiring.test.ts`) — wires the host's
native Ollama daemon into the agent-sandbox container as an MCP stdio
server, via the orchestrator's own container-launch code
(`container-runtime.ts`).

**Correction, confirmed against a real diff of this checkout's
`container/Dockerfile`/`container/entrypoint.sh`:** these two files'
"modified" status is **not** part of this feature — it's `run.sh`'s own
`apply_mnemon_patch()`/`apply_media_tools_patch()` output (mnemon binary
install + `MNEMON_EMBED_ENDPOINT` pointed at `host.docker.internal:11434`/
`nomic-embed-text`, ffmpeg/whisper-cli/yt-dlp), regenerated identically on
every deploy including `CLEAN` — see the "CLEAN-safety risk analysis"
section below, corrected accordingly.

**Telegram channel** (modified: `src/channels/index.ts`; new:
`src/channels/telegram.ts`, `src/channels/telegram-pairing.ts` +
`.test.ts`, `src/channels/telegram-markdown-sanitize.ts` + `.test.ts`,
`src/channels/telegram-registration.test.ts`) — a new chat-platform
channel following the same shape as NanoClaw's other `/add-<channel>`
skills: a barrel-import registration in `channels/index.ts` plus the
channel's own implementation files.

**Ambiguous — plausibly Telegram-related but not confirmed:**
`package.json`, `pnpm-lock.yaml`, `setup/service.ts`,
`src/modules/approvals/primitive.ts`. The first two match the shape
`run.sh`'s own comments describe for channel-skill wiring (new
dependency + lockfile churn alongside `channels/index.ts`); `service.ts`
and `approvals/primitive.ts` could belong to either feature area (or be
incidental) — not asserted here without reading their actual diffs.

**Not feature code — normal generated/runtime state, despite showing as
"Untracked (new)":**
- `start-nanoclaw.sh` — written automatically by `setup/service.ts`'s own
  "nohup fallback" path when no systemd/launchd unit is available; not
  hand-authored.
- `nanoclaw.pid` — the PID file that same nohup-fallback background
  process writes while running.
- `.claude/settings.local.json` — Claude Code's own standard
  project-local settings file, unrelated to either feature.

### CLEAN-safety risk analysis

This environment's `CLEAN` policy runs `git -C "$INSTALL_PATH" fetch
origin` then `git -C "$INSTALL_PATH" reset --hard '@{u}'`
(`run.sh`, ~line 604). A snapshot-and-reapply mechanism added for issue #3
above (~lines 555-613) protects most locally-modified **tracked** files
from that hard reset automatically — `git status --porcelain -- . ':!container/Dockerfile' ':!container/entrypoint.sh'`
saves a `git diff HEAD` patch before the reset and tries to `git apply` it
back after, succeeding silently in the common case or leaving a warning +
saved patch path on conflict.

That mechanism explicitly **excludes** `container/Dockerfile` and
`container/entrypoint.sh` by pathspec — and, confirmed directly against
this checkout's actual diff content (see the correction above), that
exclusion is correct and not a risk here: everything currently different
in those two files is exactly what `apply_mnemon_patch()`/
`apply_media_tools_patch()` (called unconditionally right after the reset,
`run.sh` ~lines 630-631) already regenerate from scratch on every deploy.
Nothing user-authored lives in either file for this checkout — `CLEAN`
reproduces them identically. The other 6 modified tracked files
(`package.json`, `pnpm-lock.yaml`, `setup/service.ts`,
`src/channels/index.ts`, `src/container-runtime.ts`,
`src/modules/approvals/primitive.ts`) **are** covered by the
snapshot/reapply step regardless, with the usual caveat that a
conflicting upstream change to the same lines would leave a warning and a
saved `.patch` file to apply by hand rather than silently losing the
work. All untracked new files (the Ollama MCP/test files, all the
Telegram files) are inherently unaffected by `git reset --hard` regardless
of any of this — untracked files are never touched by a hard reset.

**Actionable takeaway, revised:** nothing in this checkout's current diff
needs a manual backup before `CLEAN` — every tracked-file modification is
either auto-protected by the snapshot/reapply mechanism or (for
`container/Dockerfile`/`container/entrypoint.sh`) already owned and
regenerated by this repo's own idempotent patch functions, and every new
file is untracked and therefore untouched by `git reset --hard` outright.
(An earlier version of this entry asserted the opposite for
`container/Dockerfile`/`container/entrypoint.sh` — reasoned from the file
names alone, without actually diffing their contents against `run.sh`'s
patch functions first. Left here, struck through in spirit rather than
deleted outright, as a reminder to verify a "these two files are excluded
from the safety net" claim against what's actually *in* the diff before
telling anyone to go back up files that turn out to already be safe.)

### General Lessons

- **"Untracked" in `git status` doesn't always mean "someone's new work."**
  `start-nanoclaw.sh` and `nanoclaw.pid` show up identically to genuine new
  feature files but are ordinary generated runtime state this repo's own
  tooling (`setup/service.ts`'s nohup fallback) writes on its own — worth
  checking what actually produces a file before folding it into a feature
  inventory.
- **A file's name being on an exclusion list doesn't mean whatever's
  currently in it is at risk — check what the diff actually contains
  before warning anyone about it.** `container/Dockerfile`/
  `container/entrypoint.sh` being excluded from `CLEAN`'s snapshot/reapply
  step (issue #3 above) is deliberate and correct *because* this repo's
  own patch functions already own and regenerate their content — the
  exclusion is what makes them safe, not what puts them at risk. The first
  pass of this very entry got that backwards by reasoning from the
  filenames and the exclusion pathspec alone, without diffing the actual
  file contents against what `apply_mnemon_patch()`/
  `apply_media_tools_patch()` write.

## `apply_mnemon_patch()` Silently Dropped entrypoint.sh's Executable Bit

**Status:** fixed, confirmed root-caused directly against `run.sh`'s own
source (not yet re-verified against a live redeploy at time of writing).

### Summary

A real checkout showed `container/entrypoint.sh`'s file mode changed from
755 to 644 (executable bit gone) after this environment's mnemon patch
had run against it — found while reviewing the same live checkout covered
in the entry above.

### Issue Found & Fixed

**Symptom:** `container/entrypoint.sh` lost its executable bit in a real,
patched NanoClaw checkout, despite no one having manually `chmod`'d it.

**Root cause:** `apply_mnemon_patch()`'s entrypoint-wiring step (`run.sh`,
~lines 255-262) writes the patched file to a `mktemp` temp file, then
`mv`s it over `$entry`:
```bash
local tmp; tmp=$(mktemp)
{ ... } > "$tmp"
mv "$tmp" "$entry"
```
`mktemp` creates its file with default/umask-derived permissions, not a
copy of `$entry`'s existing mode — `mv` then replaces `entrypoint.sh`
with that non-executable file wholesale. This runs on every deploy where
the idempotency check (`grep -q 'mnemon setup' "$entry"`) doesn't already
find the patch applied, i.e. any time the file is freshly synced from
upstream (a fresh install, or right after `CLEAN`'s `git reset --hard`).

**Fix:** `chmod +x "$tmp"` immediately before the `mv`. Used plain
`chmod +x` rather than `chmod --reference="$entry" "$tmp"` — the latter
is GNU-only and not available under BSD/macOS `chmod`, and this repo
targets both (see this repo's own bash-3.2/macOS-portability constraint).
`apply_mnemon_patch()`'s other `mktemp`+`mv` (for `container/Dockerfile`,
~line 218) doesn't need the same fix — Dockerfiles aren't executed
directly, only `docker build`-parsed, so a dropped exec bit there has no
functional effect.

**Lesson:** a `mktemp` + rewrite-in-place + `mv` pattern silently
resets file mode to whatever `mktemp`'s own default is, not the original
file's — worth checking for on any script that patches an existing file
this way, not just this one. Whether the dropped bit actually breaks
anything downstream (e.g. if NanoClaw's own Dockerfile invokes
`entrypoint.sh` via `COPY --chmod=`, the exec bit might get re-asserted at
build time regardless) wasn't verified either way; fixed unconditionally
since a correct exec bit on a script named `entrypoint.sh` is the correct
default regardless of whether the specific build happens to tolerate its
absence.

### Related PRs

- [#154](https://github.com/tantimothy/pi-bootstrap/pull/154) — this fix,
  bundled with the corrected CLEAN-risk documentation above

## Telegram Down for 3 Days After a Host Reboot — entrypoint.sh's One-Shot Relaunch Check Wasn't Enough

**Status:** fixed (same shape applied to the sibling `nanoclaw` environment
too, since both share this entrypoint.sh).

### Summary

A Mac mini host reboot raced Docker's own startup against NanoClaw's
container-runtime readiness check, NanoClaw's Node process exited FATAL
seconds after being launched, and nothing ever relaunched it — the
`nanoclaw-mnemon` container itself stayed up and healthy throughout
(`docker ps` would have shown nothing wrong), while the actual service
inside it — Telegram included — was dead for 3 days until someone
happened to check.

### Issue Found & Fixed

**Symptom:** Telegram (and every other channel) unreachable. `docker ps`
showed the `nanoclaw-mnemon` container running normally the whole time —
nothing about the container's own health looked wrong. `nanoclaw.pid`
held a long-gone PID.

**Root cause, two layers:**

1. NanoClaw's own `ensureContainerRuntimeRunning()`
   (`container-runtime.ts:45`) hit `spawnSync /bin/sh ETIMEDOUT` trying to
   reach Docker's sibling daemon at boot — a real race, not specific to
   this container: on a host reboot, this container can start (and pass
   its own `--restart unless-stopped` gate) before the host's Docker
   daemon has actually finished coming up. NanoClaw's readiness check has
   no retry/backoff of its own; the first timeout is fatal, and the whole
   process exits.
2. This repo's own `scripts/entrypoint.sh` (PID 1 of the container) only
   ever checked *once*, at container start, whether NanoClaw's nohup'd
   background process (`setupNohupFallback()` in NanoClaw's own
   `setup/service.ts` — there's no systemd inside this container for it
   to use instead) was alive, then blocked forever on `exec tail -F
   logs/nanoclaw.log`. That one check ran and found the process alive
   (entrypoint.sh had just launched it) — the crash in (1) happened
   *after* that check, with nothing left watching. The container's own
   PID 1 (this script, now just tailing a log file) never exited, so
   Docker's `--restart unless-stopped` policy — which reacts to the
   *container* exiting, not to a process living inside it dying — never
   had anything to react to either. Two independently-reasonable
   mechanisms (a one-shot start-time check, and container-level restart
   policy) each assumed the other layer covered the "process crashes
   mid-flight" case; neither did.

**Fix:** replaced the one-shot check in both `nanoclaw-mnemon`'s and
`nanoclaw`'s `scripts/entrypoint.sh` with a real supervision loop —
polls every 10s whether `nanoclaw.pid`'s process is still alive via
`kill -0`, and relaunches `node dist/index.js` (updating `nanoclaw.pid`)
the same way the original one-shot check did if not. Kept the exact same
`nohup` + PID-file shape rather than switching to a simpler foreground
`while true; do node dist/index.js; done` loop, because `nanoclaw.pid` is
load-bearing elsewhere: `scripts/systemctl-shim.sh`'s `is-active` check
reads it directly (NanoClaw's own channel-skill "restart the service"
step shells out to `systemctl --user restart`, faked by this repo's shim
since there's no real systemd in this container), and NanoClaw's own
generated `start-nanoclaw.sh` wrapper follows the same convention — a
different supervision shape here would have silently broken both.
`tail -F logs/nanoclaw.log` (for `docker logs -f`) is now backgrounded
rather than `exec`'d, since the watchdog loop needs to be the container's
real PID 1 instead. Added an explicit `wait "$pid"` right before each
relaunch to reap the just-exited process — without it, a sustained crash
loop (e.g. Docker's sibling daemon staying unreachable for an extended
stretch) would accumulate zombie processes under this script's PID 1
indefinitely, since nothing else in this container would ever reap them.

Verified against a fake `node` binary that crashes on its first two
invocations and stays up on the third: the watchdog correctly relaunched
twice within the poll interval, and a mid-run process-table check
between crash cycles showed no zombie accumulation.

**Not fixed here — flagged instead:** `container-runtime.ts`'s own lack
of retry/backoff on its Docker-readiness check is NanoClaw's own upstream
source, not this repo's. The watchdog fix above makes it a non-issue in
practice regardless (any crash it causes now self-heals within ~10s), so
this wasn't patched blind against a repo this environment doesn't own the
source of — same reasoning as leaving `container/Dockerfile`/
`entrypoint.sh` to this repo's own idempotent patch functions rather than
hand-editing NanoClaw's own generated output elsewhere in this file.

### General Lessons

- **A container staying up (`docker ps` looks fine) is not evidence the
  service inside it is fine.** `--restart unless-stopped` reacts to the
  *container's* PID 1 exiting — a supervisor script blocking forever on
  `tail -F` satisfies that condition trivially while the actual
  application it was supposed to be watching has been dead for days.
  Health has to be checked at the layer that actually matters, not
  inferred from a layer above it staying green.
- **A "check once at start, then just block" pattern is not the same
  thing as supervision, even though it looks like it covers the
  "relaunch after a restart" case.** It only catches processes that were
  already dead *before* the check ran — anything that dies immediately
  after is invisible to it forever, silently, since nothing else is
  watching afterward.
- **When two failure-handling mechanisms sit at different layers (here:
  a process-level relaunch check, and a container-level restart policy),
  don't assume together they form a complete safety net without tracing
  the exact boundary between what each one actually covers.** Each layer
  here was individually reasonable and each individually left the exact
  same gap uncovered.

---

## `ensure_ollama_ready()` Checked `host.docker.internal` From the Host Itself, Where It Doesn't Resolve

**Status:** fixed.

### Summary

A real deploy reported `run.sh` unable to reach a genuinely-running,
genuinely-reachable Ollama daemon ("Still couldn't reach Ollama at
http://host.docker.internal:11434 — mnemon will run graph-only for
now."), immediately after this same function had just tried (and
apparently failed) to start it. Ollama was fine the whole time — the
check itself was probing the wrong address for the context it actually
runs in.

### Issue Found & Fixed

**Symptom:** `MNEMON_EMBED_ENDPOINT` left at its documented default
(`http://host.docker.internal:11434`), Ollama genuinely installed and
reachable on the host — but every deploy logged "Still couldn't reach
Ollama," and mnemon fell back to graph-only every time, never actually
using the embeddings that were supposed to be enabled.

**Root cause:** `ensure_ollama_ready()` executes directly on the HOST as
part of `run.sh` — it is never invoked inside any container. But
`host.docker.internal` is a hostname Docker's own embedded DNS resolves
*only inside containers*, specifically so a container can reach back out
to its host — it carries no meaning to the bare host's own shell/DNS
resolution at all. Every `curl`/`ollama` call in this function was built
against `$endpoint` directly (the same variable also baked into the
container's own image via `apply_mnemon_patch`, where `host.docker.internal`
*is* the correct value) — so the host-side check was, in effect, asking
"can the host reach itself via a hostname that only containers can
resolve," which fails regardless of whether Ollama is actually running.

**Fix:** introduced a separate `probe_endpoint` local
(`${endpoint//host.docker.internal/localhost}`), used for every
functional `curl`/`OLLAMA_HOST` call in this function; `$endpoint` itself
is untouched everywhere else (log messages, and the value that ends up
baked into the container's own `Dockerfile` patch) so the container's own
real reachability need is unaffected. A remote, non-local
`MNEMON_EMBED_ENDPOINT` is unaffected either way — the substring
substitution is a no-op when `host.docker.internal` isn't present.

### General Lessons

- **The same variable serving two different execution contexts (a host
  shell vs. a container's own runtime) can need two different actual
  values, even when it's semantically "the same endpoint" in both
  places.** `host.docker.internal` is exactly this kind of context-
  dependent name: correct and necessary from inside a container, actively
  wrong from the host that's asking the question in the first place.
  Don't assume a single variable is safe to reuse verbatim just because
  the concept ("where's Ollama") is identical in both places.
- **A function's own log output can look completely plausible while
  testing the wrong thing.** "Checking Ollama at
  http://host.docker.internal:11434" reads as a reasonable, specific
  diagnostic — nothing about the message itself hints that the actual
  `curl` call underneath is doomed regardless of whether Ollama is
  running, because the hostname in it was never resolvable from where the
  check actually executes.

## `~/.claude.json` Volume Mount Failure — Three Rounds of Debugging, Then Reverted Entirely

**Status:** reverted. `${CONTAINER_NAME}_claude_home`/`_claude_json` no
longer exist in either environment — this whole persistence feature was
removed, not fixed. Recorded in full because the wrong turns, and the
final decision to walk away from it, are both the useful part.

### Summary

A `${CONTAINER_NAME}_claude_home` / `${CONTAINER_NAME}_claude_json` named
volume pair was added to persist the admin `claude` session's OAuth
state/history and `~/.claude.json` (MCP registrations, onboarding state)
across container recreation. A real CLEAN deploy then failed with:

```
docker: Error response from daemon: source .../merged/root/.claude.json is not directory
```

This took three rounds to diagnose, and was reverted outright once
diagnosed rather than shipped — see "Why This Was Reverted" below.

### Investigation

**Wrong theory #1 — stale volume, wrong type from an earlier attachment.**
The user removed the volume entirely (`docker volume rm
nanoclaw-mnemon_claude_json`, confirmed via a second `rm` reporting "no
such volume") and retried; the exact same error came back against a
volume that had never existed before that moment. Ruled out by direct
retest.

**Wrong theory #2 — moby's mount-ordering bug (moby#8055), triggered by
`/root/.claude` being a literal string prefix of `/root/.claude.json`.**
Converted both mounts from the legacy `-v name:path` shorthand to
Docker's fully-explicit `--mount type=volume,source=...,destination=...`
form, on the theory that `--mount` bypasses whatever path-string
heuristic `-v` was hitting. Shipped, merged, retested live — **identical
error, byte-for-byte.** That ruled this out too: `-v` and `--mount` hit
the exact same failure, so it was never about CLI-flag parsing.

Two further isolated `docker run --mount type=volume,...` tests against a
bare `busybox` image, with NO sibling `/root/.claude` mount present at
all, reproduced the failure in complete isolation — killing the
prefix/sibling-mount theory outright regardless of syntax. A follow-up
pair of tests (empty placeholder file vs. `echo '{}' >` non-empty one,
and `.claude.json` vs. no-leading-dot `claude.json`) also both failed
identically, ruling out file emptiness and dotfile-naming as triggers too.

**Actual root cause:** the user's Docker Engine is **OrbStack's own
reimplementation**, not upstream `dockerd` (`docker build` output shows
`docker:orbstack` as the builder). OrbStack has multiple open upstream
issues describing exactly this failure class for single-file volume/bind
mounts (orbstack/orbstack#1274, #1485) — its volume driver doesn't
reliably auto-detect file-vs-directory destination type the way genuine
dockerd's copy-up mechanism does. This is a real gap in OrbStack itself,
not a bug in this repo's Docker usage.

A structural fix was designed and briefly shipped (a separate PR, later
closed unmerged): switch `~/.claude.json` from a named volume to a host
bind mount backed by a real file under `$NANOCLAW_INSTALL_PATH`, since a
bind mount's source must already exist as a real file — no type to guess,
so the bug class becomes structurally impossible rather than avoided.

### Why This Was Reverted

Before that bind-mount fix could even be tested live, the user pointed
out the thing this whole investigation had missed: **the persistence
feature was never actually requested.** The original ask was narrower —
a fresh admin session should know it's running inside `nanoclaw`
(self-identification) — and the user had explicitly said losing
conversation history on recreation was fine ("I'm ok if history is lost,
it's happened before and it's not an issue"). The self-identification
part was already fixed, independently, by a regenerated-on-every-start
`/root/CLAUDE.md` (`scripts/entrypoint.sh`) — no volume involved at all.

Adding `claude_home`/`claude_json` on top was scope creep, and it made
things *worse* than the original complaint: the original gap was "history
doesn't survive recreation" (accepted as fine), but the volume feature's
own bug made the container **fail to deploy at all** — a strictly worse
failure mode, introduced by fixing something nobody asked for. Once the
real root cause (an unfixable-from-this-side OrbStack bug) was confirmed,
continuing to chase a workaround for an unrequested feature stopped
making sense. The feature was removed entirely: both named volumes are
gone from `run.sh`/`Dockerfile`/`info.yaml` in both environments, and
`/root/.claude`/`/root/.claude.json` are back to living only on the
container's own ephemeral writable layer, exactly as they did before any
of this started.

### General Lessons

- **A fix that changes CLI syntax but not the underlying mechanism proves
  nothing until it's retested live.** `--mount` vs `-v` felt like a real
  fix (different code path, cited a real upstream issue) and shipped/
  merged before the live retest came back — the retest is what actually
  falsified it. Don't treat "plausible mechanism + real upstream bug
  report" as confirmation; treat it as a hypothesis until the exact same
  live repro comes back clean.
- **When a fix doesn't work, isolate before guessing again.** Two rounds of
  guessing (stale volume, then moby's mount-ordering bug) both got
  falsified by user-run diagnostics, not by more reasoning from this end.
  A minimal, from-scratch `busybox` reproduction with one variable changed
  at a time (sibling mount present/absent, file empty/non-empty, dotfile/
  non-dotfile) is what actually found the real cause, in far fewer
  round-trips than continuing to guess whole-environment fixes.
- **Before investing further rounds fixing a bug, check whether the
  feature it's in was actually requested.** Three rounds of live
  debugging went into a persistence mechanism nobody asked for, when the
  user had already said the underlying gap (lost history) was acceptable.
  "This would also be nice while I'm in here" is worth surfacing as a
  question before building, not after three failed fix attempts —
  especially when the failure mode of getting it wrong is "breaks
  deployment entirely," strictly worse than the status quo it was meant
  to improve.
- **`docker version`/`docker info`/`docker build` output naming the actual
  engine implementation (`docker:orbstack` here) is a real diagnostic
  signal, easy to miss when every command otherwise looks like standard
  Docker CLI usage.** A Docker-compatible reimplementation can diverge from
  upstream `dockerd` in exactly the corners (volume type auto-detection)
  that are least likely to be covered by day-to-day testing.

## "Open a Claude Session" Opened Plain Bash, and a Freshly-Picked Model Never Took Effect

**Status:** fixed and confirmed live on `nanoclaw-mnemon` (user confirmed
"Open a Claude Session" launches `claude` correctly on a fresh container).
Fixed in `nanoclaw-mnemon`, `nanoclaw` (both `scripts/claude-tmux.sh` and
`open-claude-session.sh`'s host-mode branch), and `claude-cli`'s
`bashrc-tmux-attach.sh` — all four copies of the same grouped-session tmux
pattern.

### Summary

After the `claude_home`/`claude_json` revert (see the entry above), the
user reported "Open a Claude Session" landing in a plain `bash` shell
instead of `claude`, and separately that a freshly-picked `CLAUDE_MODEL`
(`claude-sonnet-4-6`) never actually took effect — the session still
reported itself as Sonnet 5.

### Issue Found & Fixed

**Symptom:** confirmed via live diagnostics that the container had
genuinely been recreated recently, and `docker exec ... env | grep
CLAUDE_MODEL` showed the correct new value baked into the running
container — ruling out both "stale container" and "env var didn't get
set" as explanations. `docker exec ... tmux list-sessions` then showed
`no server running` — no tmux session existed at all yet. Opening a
session and immediately checking `ps aux | grep claude` from a separate
terminal showed only the wrapper script and two `tmux new-session -t
claude -s client_NNNN ...` processes — no `claude` process anywhere —
while `tmux list-windows -t claude` reported "can't find session: claude".

**Root cause:** the grouped-session pattern (`tmux new-session -t claude
-s "client_$$" ... 2>/dev/null || tmux new-session -s claude ... claude
--continue $MODEL_ARGS`, copied across `claude-cli`, `nanoclaw`, and
`nanoclaw-mnemon`) assumed the first command would *fail* when no session
named "claude" existed yet, falling through to the `||` branch that
actually launches `claude`. It doesn't fail. Confirmed directly with an
isolated reproduction (no Docker needed — plain local `tmux`): `tmux
new-session -t <group> -s <name>` silently *creates* the named group if
it doesn't already exist, rather than erroring, when a real client is
attached (this diverges from a `-d`/detached test, which can look like a
failure due to `destroy-unattached` firing on a client-less session — a
red herring the first pass at reproducing this hit). So the very first
connection ever always "succeeded" at the first command, creating a
session named `client_<pid>` (grouped under a freshly-created "claude"
group) whose only window ran a plain shell — no `claude`, no `--continue`,
no `--model`, ever, on a truly fresh tmux server. Every later connection
correctly grouped onto that first (broken) session, so the bug was
permanent for that container's lifetime once it happened once.

**Fix:** stopped relying on the first command's exit status entirely.
Gate explicitly on `tmux has-session -t claude 2>/dev/null` first, then
branch:

```sh
if tmux has-session -t claude 2>/dev/null; then
    tmux new-session -t claude -s "client_$$" \; set-option destroy-unattached on
else
    tmux new-session -s claude -c /root claude --continue $MODEL_ARGS
fi
```

Verified end-to-end with an isolated local `tmux` reproduction (a
stand-in command in place of the real `claude` binary, since this
sandbox has no live Docker daemon): first connection against a fresh
server correctly takes the `else` branch and invokes the real command
with `CLAUDE_MODEL` passed through; a second, immediate connection
correctly finds the now-existing "claude" session and groups onto it
instead of relaunching.

`pi-barebones/.bashrc.tmux` has the same structural pattern (`-t 0 ... ||
new-session -s 0`) but wasn't touched — both of its branches just start a
plain shell with no first-time-only special behavior (no model flag, no
`--continue`), so the same "first command never actually fails" quirk has
no observable effect there.

### General Lessons

- **A grouped-session tmux idiom copied across four files was never
  actually exercised against a truly cold tmux server in this repo's own
  testing before this bug surfaced.** Something can look like a well-
  reasoned, thoroughly-commented pattern (it even correctly explains *why*
  it uses grouped sessions instead of plain `-A` attach-or-create) while
  still getting the one load-bearing assumption — "the first command fails
  when the target doesn't exist" — wrong, because that assumption was
  never actually tested, only reasoned about.
- **Test the "cold start" path, not just steady-state reattachment.** Every
  manual test after the first real connection would have looked fine
  (grouping onto the already-existing, if broken, "claude" session works
  correctly) — the bug is only visible on a genuinely fresh tmux server,
  which is easy to stop hitting once a session already exists from earlier
  testing.
- **A local, Docker-free reproduction of a specific subsystem's behavior
  (here, bare `tmux` on the sandbox host) can verify a hypothesis just as
  decisively as a live container test, when the bug is in that subsystem
  itself rather than anything Docker-specific.** This one didn't need the
  user's host at all once the actual mechanism (tmux group-session
  semantics) was identified as the suspect.

## `claude --continue` With Nothing To Continue Exits Instead Of Starting Fresh — Closing the Whole Session

**Status:** fixed and confirmed live on `nanoclaw-mnemon` (a fresh "Open a
Claude Session" after a real container recreation now stays open with a
usable conversation, model flag intact). Fixed in the same four files as
the `has-session` fix above.

### Summary

Immediately after the `has-session` fix (which correctly got `claude`
launching on first connection), the user reported "Open a Claude Session"
now exits straight back to `deploy.sh`'s menu right after logging in,
with `No conversation found to continue` flashing and disappearing first.

### Issue Found & Fixed

**Symptom:** the base tmux session's only window ran `claude --continue`;
when no conversation existed yet for `/root` (true on every single launch
after this environment's own `claude_home`/`claude_json` persistence
revert — see the entry above), `--continue` printed "No conversation
found to continue" and exited, rather than falling back to starting a
fresh conversation itself. Since that was the window's only command, the
window closed, then the session (it was the only window), then the
`docker exec -it` connection along with it — landing back at `deploy.sh`'s
menu with `[exited]` and no usable session ever having actually opened.

**Root cause:** the fix for the previous bug correctly identified *that*
`claude` needed to launch on first connection, but the exact invocation
(`claude --continue $MODEL_ARGS`) still assumed `--continue` degrades
gracefully when there's nothing to continue. It doesn't, at least not in
the interactive TUI (confirmed directly against a real deploy — a
non-interactive `-p` invocation with `--continue` and no history *does*
degrade gracefully and starts fresh, which is a different code path and
not what "Open a Claude Session" launches).

**Fix:** wrapped the launch in a shell fallback — `sh -c "claude
--continue $MODEL_ARGS || claude $MODEL_ARGS"` — so a failed `--continue`
falls through to a plain fresh launch instead of exiting the whole
session. Verified with an isolated local `tmux` reproduction using a
stand-in `claude` script that mimics the exact observed behavior (exits
1 with the same message on `--continue`, succeeds otherwise): the session
survived the failed `--continue` attempt and correctly relaunched with
`--model` intact.

Since `nanoclaw`/`nanoclaw-mnemon` have no persisted `~/.claude` state
across recreation by design (the revert above), this isn't a rare edge
case for them — it's the case on *every* first launch after every
recreation. For `claude-cli` (which still has `claude_cli_home`) and
`nanoclaw`'s host-mode branch (a real host directory), it's a rarer
first-ever-login case, but the same fix applies there too for the same
reason.

### General Lessons

- **Fixing "the command that should run doesn't run" doesn't guarantee
  the command itself handles its own edge cases once it does.** The
  previous fix (this file's own entry above) was necessary but not
  sufficient — it got `claude` invoked at all, but the flag combination
  being invoked with (`--continue` against empty history) had its own,
  separate failure mode that only became visible once the first bug was
  out of the way.
- **A CLI tool's non-interactive and interactive behavior for the "same"
  flag can genuinely differ** — `claude --continue` with nothing to
  resume degrades gracefully under `-p`, but not interactively. Don't
  assume a flag's behavior transfers across invocation modes without
  checking the specific mode actually in use.
- **When a command is the sole process in a tmux window, that command
  exiting for *any* reason tears down the window, and if it's the last
  window, the whole session** — a `|| fallback` at the shell level is the
  simplest way to keep a single bad exit from closing everything above it
  in a grouped-session design like this one.

## `CLAUDE_MODEL`/"Choose Claude Model" Only Affects the Admin Session — Telegram Groups Need NanoClaw's Own `ncl` CLI

**Status:** not a bug — documented behavior, confirmed working as designed.

### Summary

After picking a new model via "Choose Claude Model" and restarting, the
Telegram bot (a per-conversation-group agent, NanoClaw's own concern, not
this repo's admin session) was still visibly running the old model. This
isn't something `CLAUDE_MODEL` was ever supposed to control — it's a
real, working distinction that just wasn't obvious enough from where the
user went looking.

### The Actual Mechanism

`CLAUDE_MODEL` (`.env`, "Choose Claude Model") only ever sets which model
the **admin** `claude` session launches with — the one you reach via
"Open a Claude Session". It has never applied to NanoClaw's own
per-conversation-group agent containers (Telegram, Discord, etc.) — this
is already noted in both `README.md` files ("Can NanoClaw Itself Talk to
Ollama?") and `info.yaml`'s own comment on that menu action, but nothing
surfaces the distinction at the point someone's actually trying to change
a *group's* model, which is where this bit.

**To change a specific group's model**, NanoClaw has its own CLI for
exactly this, entirely separate from this repo's `.env`:

```bash
docker exec -it nanoclaw-mnemon bash -lc "cd \$NANOCLAW_INSTALL_PATH && pnpm ncl groups list"
docker exec -it nanoclaw-mnemon bash -lc "cd \$NANOCLAW_INSTALL_PATH && pnpm ncl groups config update --id <group-id> --model claude-sonnet-4-6"
docker exec -it nanoclaw-mnemon bash -lc "cd \$NANOCLAW_INSTALL_PATH && pnpm ncl groups restart --id <group-id>"
```

Stored per-group in NanoClaw's own database, takes effect on that group's
own restart (not the orchestrator container's), and covers every
Telegram/Discord group wired to that same agent group at once.

**`ncl` is not a global binary inside the container** — it only exists as
a `pnpm` script alias (`package.json`'s `"ncl": "tsx src/cli/client.ts"`)
inside NanoClaw's own source tree. Running bare `ncl ...` from a plain
`bash` shell fails with "command not found" regardless of correctness —
it needs both `cd $NANOCLAW_INSTALL_PATH` *and* the `pnpm` prefix, whether
run from inside an admin `claude` session (which already has a shell and
the right `cd`) or a fresh `docker exec` shell that doesn't.

### Verifying It Actually Took Effect

After the update+restart, the bot's own self-report ("what model are
you?") still said Sonnet 5. Checking the real source of truth —
`ncl groups config get` — showed `claude-sonnet-4-6`, confirming the
change genuinely took effect and the self-report was just stale/
unreliable metadata. This is the same principle already documented
elsewhere in this repo (`claude-cli`'s and `nanoclaw`'s own READMEs:
"don't trust asking `claude` itself 'which model are you'... use
`/status` instead, or check the actual config/env directly") — this is
simply the NanoClaw-group-specific version of the same check
(`ncl groups config get` instead of `/status` or `docker exec ... env`).

### General Lessons

- **A correctly-documented distinction can still cause real confusion if
  it isn't surfaced at the exact point someone's acting on the wrong
  assumption.** The admin-session-vs-per-group-model split was already
  written down in two places before this happened — the gap wasn't
  missing documentation, it was documentation not being in front of the
  user at the moment they needed it.
- **"Which model are you?" is not a reliable check for ANY Claude Code
  surface** — not the admin session (established earlier this session),
  and not a NanoClaw group agent either. Always check the actual
  governing state directly (`ncl groups config get`, `docker exec ... env
  | grep CLAUDE_MODEL`, `/status`) rather than trusting a self-report.
- **A CLI tool's own `bin` entry only works where it's actually
  installed/linked** — a `package.json` `bin` field doesn't put anything
  on a plain shell's `PATH` unless the package was installed globally;
  inside a project's own checkout, its `pnpm <script-name>`/`npm run
  <script-name>` alias is usually the reliable way to invoke it
  regardless of global-link state.

## Upgrade Tripwire Crash Loop

**Status:** fixed, confirmed against a real incident.

**Summary:** NanoClaw's own startup tripwire compares the running code's
version against the version recorded in `data/upgrade-state.json`, and
refuses to start (crash-looping under the circuit breaker) whenever they
disagree — by design, to catch an install whose source was updated outside
NanoClaw's own sanctioned upgrade flow.

**Symptom:** the container crash-looped from boot, stuck on circuit-breaker
attempt 14 by the time it was investigated, logging:

```
ERROR  Upgrade tripwire: install not on the sanctioned path  code=2.1.54  recorded=2.1.53
```

**Root cause:** `run.sh`'s own source-sync steps — the plain `git pull
--ff-only` on a FAST redeploy, and CLEAN's `git fetch` + `git reset --hard
'@{u}'` — update NanoClaw's code and then rebuild+restart it (`pnpm run
build` + `start-nanoclaw.sh`) without ever running NanoClaw's sanctioned
`pnpm exec tsx scripts/upgrade-state.ts set` afterward. That makes this
script itself exactly the kind of "unsanctioned update" the tripwire exists
to catch: the running code's version moves forward but the recorded
version in `data/upgrade-state.json` doesn't, so the very next boot trips
the tripwire.

**Immediate recovery (for a live install already stuck like this):** run
`pnpm exec tsx scripts/upgrade-state.ts set` inside the install path (host-
native) or via `docker exec <container> bash -lc "cd \$NANOCLAW_INSTALL_PATH
&& pnpm exec tsx scripts/upgrade-state.ts set"` (this environment) to stamp
the current code version as sanctioned, then let the circuit breaker's next
retry restart NanoClaw normally.

**Fix:** `run.sh` now has a `stamp_upgrade_state()` helper (a no-op on any
install predating `scripts/upgrade-state.ts`) called right after both
rebuild+restart sequences that follow a source sync — the patch-triggered
rebuild (host-gateway/approval-delivery patches signaling exit code 2) and
CLEAN's own post-sync rebuild — so the recorded version in
`upgrade-state.json` is always stamped to match the code that's actually
about to run, before that code's next restart.

### General Lessons

- **A "sanctioned upgrade path" tripwire needs every code path that updates
  the source to also be the sanctioned path** — not just the one entry
  point (e.g. an `/update-nanoclaw` command) it was designed around. Any
  other mechanism that mutates the tracked source (a deploy script's own
  `git pull`/`git reset --hard`, a manual `git pull` on the host) is
  "unsanctioned" from the tripwire's point of view unless it also performs
  the same stamping step.
  - **Reference:** NanoClaw's own upgrade-recovery documentation lives at
    `docs/upgrade-recovery.md` inside a NanoClaw install itself (not in this
    repo) — check there first for anything upgrade-tripwire-related in a
    future NanoClaw version, since the sanctioned command/flow is owned and
    versioned by NanoClaw upstream, not by this environment.

## Ollama MCP Tool — Auto-Applied by Default, With a Drift-Diagnosis Manifest

**Status:** implemented, verified against a live user's own already-patched
NanoClaw checkout (see below), not yet confirmed via a fresh end-to-end
deploy in this repo's own CI-less workflow.

### Summary

NanoClaw's own `/add-ollama-tool` skill registers an MCP server that
exposes local Ollama models (`ollama_list_models`, `ollama_generate`, plus
opt-in admin tools) to every per-group agent container. It's an opt-in,
manually-run skill upstream, and its shipped `ollama-env.ts` output has two
real bugs. This environment now applies a hand-written, bug-fixed
equivalent automatically, every deploy, via a new `apply_ollama_tool_patch()`
in `run.sh` (same idempotent text-splice mechanism as `apply_mnemon_patch()`/
`apply_media_tools_patch()`), called unconditionally after the
`NANOCLAW_SETUP` mnemon/plain branch — this is a general per-group agent
capability, not a mnemon-profile feature.

### The real shipped-skill bug, and three rounds on a NO_PROXY side-question

**The real bug (`.env` vars never read):** the skill's `ollamaEnvArgs()`
reads `process.env.OLLAMA_HOST`/`OLLAMA_ADMIN_TOOLS` directly, but NanoClaw
loads `.env` through its own `readEnvFile()` — those values never reach
`process.env` on their own. Fix: `src/config.ts` needs `OLLAMA_HOST`/
`OLLAMA_ADMIN_TOOLS` added to the `readEnvFile([...])` key list and
exported the same way every other config value is (`process.env.X ||
envConfig.X`). Confirmed by a live user who ran the skill, hit this, and
fixed it by hand — the fix matches their own already-working `config.ts`
exactly.

**The `NO_PROXY` side-question went through three rounds before landing.**
It's worth recording the sequence, not just the final answer, since the
middle round overturned the first and then itself got partially overturned
by the third — a good example of why secondhand debugging narratives need
primary evidence before shipping code around them.

**Round 1 (shipped first):** an early replication summary this session was
given described a second bug — "OneCLI's own `NO_PROXY=host.docker.internal`
default breaks Ollama routing" — fixed by overriding `NO_PROXY`/`no_proxy`
to a dummy value (`0.250.250.254`, made `.env`-configurable as
`OLLAMA_NO_PROXY_OVERRIDE`). This shipped in the first version of
`apply_ollama_tool_patch()`.

**Round 2 (overturned round 1):** a follow-up cross-check against a
timestamped env dump from the actual debugging session showed
`NO_PROXY=<OneCLI's own gateway IP>` was already the platform default
*before* any fix was applied, and was never the problem — the real bug was
`OLLAMA_HOST` itself pointing at that same gateway IP (the OneCLI
credential-vault address, not Ollama, which 403s regardless of proxying).
This round concluded `NO_PROXY` didn't need touching at all and removed
`OLLAMA_NO_PROXY_OVERRIDE` entirely.

**Round 3 (partially restored round 1, for a different reason):** a
reconciled account from the admin `claude` session running inside the real
container, cross-checked directly against `container-runner.ts`'s own
source, filled in the missing piece: `host.docker.internal:11434` isn't a
direct Ollama socket on this platform at all — it only resolves because
`HTTPS_PROXY` routes the request through OneCLI's own gateway, which
forwards it to the real backend. Excluding `host.docker.internal` from
proxying via `NO_PROXY` breaks that routing outright (confirmed: this was
reproduced live during debugging, as a direct TCP connection refusal to the
Docker gateway IP). OneCLI's own platform default correctly excludes
`host.docker.internal` — but this repo's own `apply_mnemon_patch()` bakes
`ENV NO_PROXY=host.docker.internal` into the agent-sandbox Dockerfile for
unrelated reasons (its own "cheap insurance" against an HTTPS embed
endpoint being proxied — see that function's own comment), and `docker run
-e` wins over a Dockerfile `ENV`. So re-asserting the correct value at
container-spawn time in `ollamaEnvArgs()` isn't redundant with OneCLI's own
default — it's what actually protects against this repo's *own* other
patch quietly breaking it. `OLLAMA_NO_PROXY_OVERRIDE` was restored, with
the reasoning corrected: not "OneCLI's default is wrong," but "something
else in this specific deployment can and does make it wrong, and this is
what corrects it back at the point that actually matters (container spawn,
which happens after image build)."

**Round 4 (closed the open question from round 3):** NanoClaw's own admin
session checked `@onecli-sh/sdk`'s actual source directly — something
unavailable from inside this repo — and confirmed `onecli.applyContainerConfig()`
(the call that runs *after* `ollamaEnvArgs()` in `container-runner.ts`,
line 538 vs. line 491) pushes `-e` args from OneCLI's server-provided
`config.env` response. That response carries `HTTPS_PROXY`/`HTTP_PROXY`
(+ lowercase), `NODE_EXTRA_CA_CERTS`, `NODE_USE_ENV_PROXY`, `GIT_*`, and
`CLAUDE_CODE_OAUTH_TOKEN` — no `NO_PROXY` entry at all. So there's no
downstream key collision: `ollamaEnvArgs()`'s `NO_PROXY` value is never
overridden, and the round-3 mechanism is confirmed to work as intended, not
just plausible in theory.

**A loose thread this surfaced, not yet chased down:** where the
`NO_PROXY=0.250.250.254` value Clawdia originally observed (before *any* of
this session's changes existed) actually came from, if it wasn't OneCLI's
`config.env` and wasn't this repo's code at that point. Possibly the base
container image, possibly something in NanoClaw's own entrypoint/startup —
genuinely unknown, and doesn't block anything here (this patch's own value
is confirmed to land correctly regardless of where that original one came
from), but worth another look if `NO_PROXY` behavior on this platform is
ever revisited.

### Verification approach

WebFetch could not reliably reproduce NanoClaw's actual TypeScript source
byte-for-byte (the underlying summarization model refused/truncated full
files); `add_repo` for the upstream `nanocoai/nanoclaw` repo failed twice
with an MCP approval error. Resolved by asking the user to paste the exact
files from their own already-working, already-patched NanoClaw checkout
(`ollama-mcp-stdio.ts`, `index.ts`, `container-runner.ts`, `config.ts`).
Every anchor `apply_ollama_tool_patch()`'s `grep -n` calls search for was
confirmed to match those real files exactly, and the generated splice
output was confirmed byte-identical to the corresponding already-patched
sections of the user's own working copy.

### Drift-diagnosis design (the actual ask this session)

Deliberately **not** pinning NanoClaw's git ref — this environment still
tracks upstream `main`, same as always. Instead, the risk that an upstream
change one day shifts an anchor line and silently breaks a sub-patch is
addressed with two new files, written into `$NANOCLAW_INSTALL_PATH` (inside
the deployed NanoClaw checkout, not this repo):

- **`pi-bootstrap-patches.md`** — regenerated on every deploy by a new
  `write_patches_manifest()` in `run.sh`, listing every patch this
  environment applies (mnemon, media-tools/whisper, ollama-tool) and each
  one's PASSED/SKIPPED/FAILED status, sourced from `_LOG`/`_OK` status
  variables each `apply_*_patch()` function now sets
  (`MNEMON_PATCH_OK`/`_LOG`, `MEDIA_TOOLS_PATCH_OK`/`_LOG`,
  `OLLAMA_PATCH_OK`/`_LOG` — retrofitted onto the two older functions to
  match the new one's pattern, since the ask was "document everything that
  was done", not just the newest patch).
- **`pi-bootstrap-patch-fixes.md`** — touch-created once with an
  instructional header, then never overwritten by any later deploy. The
  admin `claude` session running inside the container (see
  `entrypoint.sh`'s `/root/CLAUDE.md`, which now points at both files) is
  meant to record whatever it diagnoses or hand-fixes here, so a human (or
  a future pi-bootstrap session) can read it later and decide whether to
  update the actual patch scripts in this repo.

### General Lessons

- **A drift-mitigation strategy doesn't have to mean pinning.** Pinning a
  fast-moving upstream trades one class of problem (silent breakage) for
  another (silent staleness — a pinned ref never gets security fixes or new
  features without a deliberate bump). Tracking `main` and instead making
  breakage *loud and diagnosable in place* — every sub-patch checks its own
  anchor and reports SKIPPED rather than guessing, plus a persistent status
  file an admin session or a human can read — is a real alternative worth
  considering before defaulting to pinning.
- **"Fill in if missing" vs. "always overwrite" is the same fork every
  self-owned generated file eventually needs.** For a file this repo's own
  patch function fully owns (nothing upstream creates it) but that a live
  admin session might reasonably hand-edit inside a running container
  (`ollama-mcp-stdio.ts`, `ollama-env.ts`), unconditionally overwriting it
  every deploy would silently clobber that live fix. The status-report file
  (`pi-bootstrap-patches.md`) is the opposite case — nothing else ever
  writes to it, so overwriting it every deploy is correct, not lossy. The
  fix-report file (`pi-bootstrap-patch-fixes.md`) is a third case again —
  owned by the admin session, not by `run.sh`, so `run.sh` may only
  touch-create it once and must never overwrite it afterward.
- **WebFetch is unreliable for extracting exact source code**, especially
  anything non-trivial (a full TypeScript module) — its underlying
  summarization step will refuse or truncate rather than reproduce
  something byte-exact. Asking the user directly for a pasted/uploaded copy
  of their own real, working file was faster and more reliable than several
  rounds of retrying WebFetch with narrower prompts or raw-URL redirects.
- **A secondhand, prose "replication summary" of a debugging session is not
  the same evidence as the session's own transcript**, even when it's
  detailed, specific, and was personally verified as working by the person
  who wrote it. Three rounds landed on this one setting (see above) before
  the *mechanism* was actually right — round 1's root-cause story was wrong
  (OneCLI's default was never the problem), round 2 correctly caught that
  but over-corrected by assuming "not the platform default" meant "safe to
  never set," and only round 3 — reasoning from actual source
  (`container-runner.ts`) instead of another paraphrase — surfaced the real
  mechanism (HTTPS_PROXY-only routing, plus this repo's own
  `apply_mnemon_patch()` as the thing that actually puts a container at
  risk). Each round's fix was plausible and internally consistent on its
  own; only checking against primary evidence (a transcript, then real
  source code) caught what prose summaries alone kept getting subtly wrong.
  Fixing forward from a narrative reconstruction is fine when it's the best
  evidence available, but it should stay explicitly provisional — flagged
  for re-verification — rather than committed to shipped code as settled
  fact. And "the previous round was wrong" doesn't mean "revert to the
  simplest theory" either — round 2's correction was real, but its own
  conclusion needed the same scrutiny round 1's did.

## Standing Smoke-Test Instructions for the Admin Session

**Status:** implemented, not yet exercised against a real deploy.

### Summary

The patches manifest (`pi-bootstrap-patches.md`, see the entry above) only
ever proves a patch's *text* landed — `grep -c`/anchor-presence checks run
by `run.sh` on the host, before the container or its dependencies
necessarily even exist. It can't prove the patched *functionality* actually
works at runtime (Ollama genuinely reachable, mnemon genuinely embedding,
whisper/yt-dlp genuinely present in the built image) — that requires
something running live inside the container, with the Docker socket, after
real dependencies exist.

Rather than build a host-side automated test harness for this (impractical
— `run.sh` runs before the orchestrator container, let alone any agent
container, exists), `entrypoint.sh`'s `/root/CLAUDE.md` now gives the admin
`claude` session a standing instruction: before doing anything else, check
whether `pi-bootstrap-smoke-test.md` exists in the install path. If it
doesn't, this is either a genuine first connection or the first one since
TEARDOWN/CLEAN reset the environment — run a checklist covering all three
patches (manifest status, media-tool binaries in the built agent-sandbox
image, and — best-effort, since it needs a live agent container which may
not exist yet — mnemon's own `embed --status` and the Ollama MCP tool) and
write the results to that file. Proactive, not reactive: the point raised
in conversation was that "wait for something to look broken" is the wrong
default for the one moment (right after TEARDOWN/CLEAN) where nobody's
necessarily watching closely.

### Why TEARDOWN too, not just CLEAN

Only CLEAN actually re-applies the patches from a fresh `git reset --hard`
— a plain TEARDOWN+redeploy doesn't touch NanoClaw's source at all, so in
principle nothing *needs* re-verifying. But TEARDOWN destroys the
orchestrator container (and all agent containers) just as thoroughly as
CLEAN does, which means the admin session's own `/root/.claude` state is
gone either way — a genuinely fresh claude-cli connection is happening
either way, at a moment a human may not be watching either way. Correctness
of "does the patch still apply" isn't the only thing worth verifying;
"is everything still actually running correctly after this container got
destroyed and recreated" is a reasonable bar too, and costs nothing extra
to check at the same moment.

### Mechanism

`remove_agent_containers()` — already called from both the TEARDOWN and
CLEAN policy branches, never from FAST — now also deletes
`pi-bootstrap-smoke-test.md` if present. This is the single point that
correctly invalidates the smoke-test record exactly when it should (both
policies the ask covered) without needing separate logic duplicated in
each branch, and without ever false-triggering on a plain FAST restart or
reconnect. The file itself lives in `$NANOCLAW_INSTALL_PATH` (host-mounted,
not the container's ephemeral layer), so it persists correctly across
ordinary container restarts (a host reboot, `docker restart`, "Choose
Claude Model"'s stop+rm+relaunch of the *orchestrator* container alone —
none of which call `remove_agent_containers()`) — only TEARDOWN/CLEAN
clears it.

### General Lessons

- **A host-side manifest and a live-session smoke test answer different
  questions, and neither substitutes for the other.** `pi-bootstrap-patches.md`
  answers "did the patch text land" — cheap, always available, but blind to
  runtime behavior. A live check answers "does it actually work" — requires
  a running environment with real dependencies, so it can only happen from
  inside a session that has that environment, not from the host script that
  set it up.
- **The right question for "when should this re-run" is usually "what
  state actually got invalidated," not "which policy name was used."**
  Tying the smoke-test file's deletion to the one function both TEARDOWN
  and CLEAN already shared (`remove_agent_containers()`) was simpler and
  more correct than adding an `if [ "$POLICY" = "CLEAN" ] || [ "$POLICY" =
  "TEARDOWN" ]` check in two separate places — it fell out of what those
  two policies already had in common, rather than needing to be reasoned
  about separately for each.

## Two live-container findings from an admin session (2026-08-06), fixed in pi-bootstrap

**Status:** merged. Both items were reported by a `claude` admin session
running inside a deployed container (into
`pi-bootstrap-patch-fixes.md`, per that file's own instructions) and then
folded back into this repo so the fix survives the next CLEAN/fresh install
rather than staying a container-local workaround.

### Issue 1: upstream NanoClaw silently dropped the Telegram channel import

**Symptom:** Telegram stopped responding after a FAST restart (not a CLEAN
— FAST does a plain `git pull --ff-only`, no re-clone). No error anywhere;
messages sent to the bot in the meantime were queued by Telegram itself and
delivered once fixed.

**Root cause:** Upstream NanoClaw commit `675a6d87` ("remove accidentally
merged Telegram channel code") removed `import './telegram.js';` from both
`src/channels/index.ts` and `dist/channels/index.js`. A plain FAST sync
picks up any upstream commit, including a regression like this one — there
was previously no defense against upstream breaking its own wiring.

**Fix:** Added `apply_telegram_import_patch()` to `run.sh`, applied
unconditionally (like `apply_ollama_tool_patch()`, since Telegram isn't a
mnemon-profile-specific feature) right after the CLEAN/FAST source sync.
Idempotently re-adds `import './telegram.js';` after the `import
'./cli.js';` line in both files if the line is missing, and records status
in `pi-bootstrap-patches.md` under a new "Telegram channel import
self-heal" section, following the same anchor-based text-splice pattern
`apply_mnemon_patch`/`apply_media_tools_patch`/`apply_ollama_tool_patch`
already use elsewhere in this file.

### Issue 2: `whisper-cli` (agent-side media tools) missing its shared libraries

**Symptom:** `whisper-cli --help` (and any direct Bash invocation) failed
with `libwhisper.so.1: cannot open shared object file: No such file or
directory`, inside both the orchestrator's own image
(`environments/nanoclaw-mnemon/Dockerfile`) and the agent-sandbox image
(`apply_media_tools_patch()`'s patch block in `run.sh`).

**Root cause:** whisper.cpp's cmake build defaults to dynamic linking
(`libwhisper.so.1`, `libggml*.so`), but both Dockerfiles only `cp` out the
compiled `whisper-cli` binary and then `rm -rf` the build tree the shared
libraries lived in — so the binary that ships in the final image has no
runtime dependency it can actually satisfy. (Code that goes through the
`nodejs-whisper` npm package still worked, since that package separately
extracts matching libraries into `/workspace/agent/bin/whisper-lib/` at
startup and handles its own library loading — but that path never sets
`LD_LIBRARY_PATH`, so a direct `whisper-cli` Bash invocation had nothing to
find.)

**Fix:** Added `-DBUILD_SHARED_LIBS=OFF` to the `cmake -B ... -S ...`
invocation in both the orchestrator's `Dockerfile` and the agent-sandbox
patch block in `run.sh`'s `apply_media_tools_patch()`, producing a
statically-linked `whisper-cli` with no runtime library dependency at all
— simpler than threading `LD_LIBRARY_PATH` through a wrapper script or an
`ldconfig` entry at container-entrypoint time, and it doesn't depend on the
`nodejs-whisper` package having run first to populate the lib directory.

### General Lessons

- **Not pinning NanoClaw's git ref (see the `pi-bootstrap-patches.md`
  header comment on this file's own `write_patches_manifest()`) means
  upstream can regress its own base functionality, not just conflict with
  a pi-bootstrap patch.** The existing text-splice patches all defend
  pi-bootstrap's own additions against upstream drift; this Telegram fix is
  the first one that defends stock upstream behavior against upstream
  itself, applied with the identical mechanism.
- **A binary that builds cleanly and copies into the image without error
  can still be dead on arrival if the build step's own defaults (dynamic
  linking) don't match how the final image actually ships it (binary only,
  build tree deleted).** `docker compose build` succeeding is not evidence
  the binary works — this was only caught by directly exec-ing into a live
  container and running the command, per this repo's `CLAUDE.md` note that
  Docker-based environments have no automated build validation.

## Follow-up (2026-08-06, superseded same day): `ollama_available: false` is real, not cosmetic

**Status:** this entry replaces an earlier version of itself. The first
write-up here (based on a first-pass check that curl and the Ollama MCP
tools both reached `host.docker.internal:11434` fine) concluded the
`false` status mnemon reported was just a cosmetic bug in mnemon's own
status check. That conclusion was wrong — a deeper investigation in the
same admin session, prompted by mnemon's `embed --all` also failing (not
just `--status` misreporting), found a real connectivity gap and fixed it.
Leaving the wrong version of this section around would send a future
session down the same "it's just cosmetic, no action needed" dead end, so
the full story replaces it rather than appending alongside it.

**Root cause:** Go's `http.Transport` (mnemon is a Go binary) bypasses the
configured proxy specifically for `host.docker.internal` — the same class
of bug as the Node `fetch()`/undici proxy issue noted elsewhere in this
environment's docs, just hitting a different HTTP client. `curl` and the
Ollama MCP tools both worked because they go through the proxy correctly;
mnemon's Go HTTP client does not, for this one hostname. Confirmed
directly:
- `curl --noproxy '*' http://host.docker.internal:11434/api/tags` → empty
  (direct path, no proxy — actually unreachable)
- `curl http://host.docker.internal:11434/api/tags` (through the proxy) →
  model list returned fine
- `NO_PROXY=host.docker.internal mnemon embed --all` → still fails, because
  the direct path is blocked at the network level regardless of which env
  var mnemon's own client honors

That last point matters for this repo specifically: `apply_mnemon_patch()`
in `run.sh` already bakes `ENV NO_PROXY=${embed_host}` /
`ENV no_proxy=${embed_host}` into the image whenever `MNEMON_EMBED_ENDPOINT`
is set (added on the reasoning that the proxy is only needed for `https://`
URLs, so excluding an `http://` endpoint from it should be a no-op) — see
that function's own comment. In a network where the proxy is actually
required to reach `host.docker.internal` at all, that `NO_PROXY` setting is
counterproductive: it tells every HTTP client in the container to skip the
one path that works. Worth revisiting if this ever gets patched at the
image-env level instead of the loopback-forwarder level described below.

**Workaround used to unblock this container (not the permanent fix):**
Clawdia (the group's own agent) ran a local Node.js forwarder on
`127.0.0.1:11435`, relaying to Ollama via proxy-aware `curl` subprocesses.
Go connects to loopback directly with no proxy-bypass behavior involved;
the forwarder does the proxy-aware hop on mnemon's behalf. Backfilled with
`MNEMON_EMBED_ENDPOINT=http://127.0.0.1:11435 mnemon embed --all` — went
from 0/342 to 342/342 insights embedded (100% coverage), persisted to the
volume-mounted `/home/node/.claude/mnemon/` data dir, so it survives
ordinary container restarts. The forwarder itself was run ephemerally and
was not still running afterward — new insights created after the next
container restart won't auto-embed until something makes the forwarder
permanent.

**Permanent pi-bootstrap fix actually shipped (this PR), instead of the
forwarder:** rather than adding a permanent background forwarder process
(more moving parts — a long-lived loopback listener, proxy-token
derivation at runtime, a new failure mode if it dies) the forwarder
workaround pointed at a smaller, better-precedented fix already sitting in
this same file: `apply_mnemon_patch()`'s own `embed_env` block was baking
`ENV NO_PROXY=${embed_host}` / `ENV no_proxy=${embed_host}` into the image
*unconditionally* whenever `MNEMON_EMBED_ENDPOINT` was set — including for
the `http://host.docker.internal:11434` default this environment ships
with. That's precisely the value `apply_ollama_tool_patch()`'s own header
comment (a few hundred lines up in this same file, from an earlier
debugging session on the sibling Ollama MCP patch) already documents as
actively wrong on this platform: `host.docker.internal` is only reachable
*through* the proxy here, so excluding it via `NO_PROXY` breaks the
connection outright rather than protecting anything. mnemon has no
per-container-spawn env reassertion step the way `ollamaEnvArgs()` gives
the MCP tool patch — it only ever sees this one baked-in image ENV — so
this wrong value was the actual, sole cause of `ollama_available: false`.

Fixed by scheme-gating the `NO_PROXY`/`no_proxy` assertion: only added for
an `https://` embed endpoint (the original, correct concern — an intended
external HTTPS endpoint getting silently hijacked by NanoClaw's own
`HTTPS_PROXY` injection), never for the `http://` default. A real Pi
deployment with no proxy configured at all sees no behavior change either
way (`NO_PROXY` is inert with no proxy present); this only changes
behavior on a platform where the proxy is actually required for
`host.docker.internal` reachability, which is exactly the case that was
broken. Takes effect on the next CLEAN deploy (the patch's own
`MNEMON_VERSION` idempotency marker means a live image already carrying
the old, wrong `NO_PROXY` needs a fresh `container/Dockerfile` re-clone —
same as every other text-splice patch in this file — a FAST restart alone
won't pick it up).

### General Lessons

- **A "cheap insurance, should be a no-op" env var is only actually
  harmless if the no-op assumption has been verified against the real
  platform, not just reasoned about from protocol conventions.** The
  original `NO_PROXY` bake-in reasoned that `HTTPS_PROXY` routing
  "obviously" doesn't touch `http://` URLs, so excluding the host from it
  was free insurance either way — correct as a general HTTP convention,
  wrong on this specific platform's actual proxy setup, and the assumption
  was never re-checked against a live container until this session did.
- **When two independently-diagnosed bugs in the same file turn out to be
  the same root cause, the fix for the first one is usually the answer for
  the second, not a new mechanism.** `apply_ollama_tool_patch()`'s own
  header comment had already fully diagnosed "`NO_PROXY` must not include
  `host.docker.internal` on this platform" for the Ollama MCP tool's own
  connectivity. `apply_mnemon_patch()` sat right above it in the same file,
  making the identical mistake for mnemon's connectivity — worth grepping
  a file's own prior debugging comments for "the same shape of bug,
  different function" before reaching for a heavier new fix.

## Follow-up (2026-08-06): the Telegram-import self-heal itself broke CLEAN builds

**Status:** fixed, same day as the patch that introduced it. A real user
ran a CLEAN build after `apply_telegram_import_patch()` shipped and hit:

```
src/channels/telegram.ts(6,39): error TS2307: Cannot find module '@chat-adapter/telegram' or its corresponding type declarations.
ELIFECYCLE  Command failed with exit code 2.
ERROR: Deployment task failed for [nanoclaw-mnemon].
```

**Root cause:** commit `675a6d87` ("remove accidentally merged Telegram
channel code") turned out to be a HALF removal, not a clean one — it
dropped the barrel import (`src/channels/index.ts`) and, confirmed by this
build error, the `@chat-adapter/telegram` dependency from `package.json`,
but left `src/channels/telegram.ts` itself sitting in the tree, still
importing that now-missing package. `apply_telegram_import_patch()`
originally only restored the barrel import — which made `tsc` try to
compile `telegram.ts` again during a CLEAN build's fresh `pnpm install` +
build, and it can't: the dependency isn't there. This killed the *entire*
CLEAN build, not just Telegram. A FAST restart never surfaces this,
because it neither reinstalls dependencies nor rebuilds — the
already-installed `node_modules` from before `675a6d87` papered over the
missing dependency the whole time, which is exactly why the live admin
session that originally found and fixed this (via FAST-restart-only
testing) never saw the build break.

**Fix:** added a dependency guard to `apply_telegram_import_patch()` —
before restoring the barrel import, check that `package.json` still lists
`@chat-adapter/telegram`. If it doesn't, skip the whole patch loudly
(logged as SKIPPED in `pi-bootstrap-patches.md`, same as any other
anchor-not-found case) instead of restoring an import to code that can't
build. Telegram simply won't be wired up until upstream's removal is
finished properly (or reverted) — a working CLEAN build for everything
else takes priority over Telegram specifically, and this patch was never
meant to fix upstream's own incomplete work, just defend against upstream
re-dropping something it otherwise still supports.

### General Lessons

- **A patch validated only against a FAST-restart flow can still break a
  CLEAN build, because the two paths exercise completely different
  machinery** (FAST: reuse existing `node_modules`/`dist`, no install or
  rebuild; CLEAN: fresh `git reset --hard`, fresh `pnpm install`, fresh
  build). A fix confirmed working live in a FAST-restarted container is
  not the same claim as "this survives a CLEAN build" — the two need
  separate verification, not just the same live-container check twice.
- **"Remove accidentally merged X" upstream commits are worth treating as
  suspect, not as ground truth that X is now fully gone.** This is the
  second time this exact commit's incompleteness has bitten this
  environment (first the missing import broke the running adapter, now
  the missing dependency breaks the build) — a removal commit that only
  partially removes something is arguably a worse state than either fully
  keeping or fully removing it, since every downstream consumer has to
  independently discover which parts are still there.

## Follow-up (2026-08-06): the dependency guard itself aborted the whole deploy

**Status:** fixed, same day as the guard that introduced it. A real CLEAN
deploy, on the exact `package.json`-missing-dependency case the guard above
was built to handle safely, printed the guard's own SKIPPED message —
and then the *entire deployment task failed* right after it, with no
`write_patches_manifest` output and no further patches attempted:

```
telegram.ts's own dependency (@chat-adapter/telegram) is no longer in package.json — skipping the telegram-import patch.
ERROR: Deployment task failed for [nanoclaw-mnemon].
```

**Root cause:** `run.sh` runs under `set -euo pipefail`. All four
`apply_*_patch` functions (`apply_mnemon_patch`, `apply_media_tools_patch`,
`apply_ollama_tool_patch`, `apply_telegram_import_patch`) are called as
bare statements — `apply_mnemon_patch`, not `apply_mnemon_patch || true`
or wrapped in an `if`. Every one of them has `return 1` paths that are
explicitly designed, and extensively documented throughout this file, to
skip just that one sub-patch, log a SKIPPED status into the relevant
`*_PATCH_LOG` variable for `write_patches_manifest` to pick up, and let the
rest of the deploy continue — the whole point of the
`pi-bootstrap-patches.md` manifest and its SKIPPED/FAILED/PASSED status
model is that a skipped sub-patch is a recoverable, diagnosable event, not
a deploy-ending one. But called bare, that `return 1` is just this
function's exit status as far as the shell is concerned, and `set -e`
terminates the whole script on it. This bug existed in all four call sites
from the moment each function's own "missing file/anchor, skip this one"
path was written — it just hadn't been exercised on a real deploy until
the telegram dependency guard's SKIPPED path (itself only a few hours old)
became the first one actually reachable in an ordinary, expected scenario
rather than a rare "upstream changed unexpectedly" one.

**Fix:** added `|| true` to all four call sites (not just the one that
happened to trigger this), so a skipped sub-patch can never abort the
overall deploy — matching what every one of these functions' own
SKIPPED-logging design already assumed was happening.

### General Lessons

- **A function's own internal error handling doesn't matter if its call
  site can still kill the whole script out from under it.** All the
  care that went into `TELEGRAM_IMPORT_PATCH_LOG`/`*_PATCH_OK` variables,
  the manifest, and the "diagnosable from inside the container" design
  was real and correct — but none of it mattered because `set -e` at the
  top of the file could unilaterally veto "keep going after a skip" the
  moment a bare function call returned non-zero. Check the call site's
  shell options (`set -e` in particular), not just the function body, when
  reasoning about whether an error path actually degrades gracefully.
- **A latent bug can hide for a long time behind "this only fires in a
  rare case,"** and get exposed the moment something else (here, a
  brand-new, more specific guard) makes that rare case common. The bug in
  the call sites was there before this session touched the file at all;
  it just needed a SKIPPED path to actually fire on a normal deploy to
  surface, and this session's own telegram guard happened to be that
  trigger.

## Follow-up (2026-08-06): the dependency guard wasn't the real fix — an orphaned file was

**Status:** fixed, same day, after the `set -e` fix above still left a real
user hitting the exact same build error a third time:

```
src/channels/telegram.ts(6,39): error TS2307: Cannot find module '@chat-adapter/telegram' or its corresponding type declarations.
ELIFECYCLE  Command failed with exit code 2.
ERROR: Deployment task failed for [nanoclaw-mnemon].
```

This time the `set -e` fix was confirmed working (the deploy got further —
past the point it died at before), but the underlying `tsc` failure was
still there. The two previous entries in this file had assumed, without
checking, that upstream's own removal (commit `675a6d87`) was incomplete —
"a half removal" that left `telegram.ts` in the tree pointing at a
dependency the same commit had dropped. That assumption turned out to be
wrong, and this time it was checked against upstream's real history
instead of re-guessed:

- `675a6d87` (2026-03-25, "remove accidentally merged Telegram channel
  code") deleted `src/channels/telegram.ts`, `telegram.test.ts`, **and**
  the barrel import together, in one commit. A clean, complete removal —
  not partial.
- `@chat-adapter/telegram` was dropped from `package.json` separately,
  over a month later, in a different commit (`25687dc`,
  "chore(deps): drop @chat-adapter/telegram from trunk").
- Neither commit left upstream `main` itself broken at any point in
  between.

So a fresh clone of `main` today has no `telegram.ts` at all, and no
`@chat-adapter/telegram` reference anywhere. A real deployment's
`telegram.ts` — still present, still importing the long-gone package — has
to have come from somewhere else: NanoClaw's own channel-skill mechanism
(`/add-telegram`-style skills copy their module from a separate `channels`
branch into an existing install — see `src/channels/index.ts`'s own
comment) run at some point directly against this deployment, not from
`main`'s tracked history. Once that file exists on disk, **nothing in a
normal git sync ever removes it again**: `git pull` and `git reset --hard`
both only ever touch *tracked* files, and upstream's history never
re-introduces `telegram.ts` once `675a6d87` lands — there's no tracked
"delete this" instruction for a file that was never tracked locally to
begin with. It just sits there, orphaned, permanently, once its own
dependency stops resolving.

**Why this broke the build even with zero import anywhere pointing at
it:** confirmed directly against NanoClaw's real `tsconfig.json` —
`"include": ["src/**/*"]`. `tsc` type-checks every `.ts` file physically
present under `src/`, whether anything imports it or not. The previous
round's dependency guard (only restore the barrel import if the dependency
still resolves) was necessary but nowhere near sufficient — it stopped
*this function* from making things worse, but did nothing about a
dead file that was already sitting there before the function ever ran,
which fails the build purely by existing.

**Fix:** `apply_telegram_import_patch()` now also quarantines (renames to
`*.orphaned-by-pi-bootstrap`, never deletes) `src/channels/telegram.ts`
and `telegram.test.ts` whenever they exist and `@chat-adapter/telegram`
isn't in `package.json` — regardless of what the barrel import looks like.
It also strips a *stale* barrel import from `src/channels/index.ts` /
`dist/channels/index.js` in that same situation, since quarantining the
target file out from under an import that already pointed at it would
otherwise just trade one unresolvable-module build error for another
(`Cannot find module './telegram.js'` instead of
`'@chat-adapter/telegram'`). Renaming instead of deleting keeps the file
recoverable if an operator ever wants to vendor the dependency themselves;
a `.orphaned-by-pi-bootstrap` suffix is enough on its own to drop out of
`tsc`'s `include` glob, since it only recognizes known source extensions.

### General Lessons

- **A live build error tells you where the failure surfaced, not where it
  came from — check the actual upstream history before writing a root
  cause into a comment.** "Commit X left the repo in a broken half-state"
  was a plausible-sounding story that fit the one data point available (a
  build error mentioning that commit's own hash) and was wrong on both
  counts: the commit was a clean removal, and the actual cause was a file
  that was never part of that commit's history at all. Cloning the real
  upstream repo and reading `git show --stat`/`git log --diff-filter`
  directly took a few minutes and settled it definitively — worth doing
  before writing a root cause down as fact in a comment other sessions will
  trust.
- **`git reset --hard` is not `git clean -fdx` — it only ever touches
  tracked files.** Every fix in this file up to this point implicitly
  assumed a CLEAN deploy's hard reset would return the source tree to a
  known-clean state. That's only true for files git actually tracks in
  this specific local checkout; an untracked file dropped in by some other
  mechanism (here, a channel skill run) survives every reset indefinitely,
  and needs its own explicit handling — checking file existence + its
  dependency, not just checking git state.
- **A blanket `include: ["src/**/*"]` in a `tsconfig.json` means "every
  file that exists," not "every file that's reachable."** An import-graph
  fix (add/remove a barrel import) only ever addresses what's *reachable*;
  it can't fix a build broken by a file that's merely *present*. Worth
  checking a project's actual compiler config before assuming "nothing
  imports it anymore" is equivalent to "it won't be compiled."

## Follow-up (2026-08-06): dependency guard checked package.json, not resolvability — Telegram stayed dead after a "fixed" CLEAN launch

**Status:** fixed, same day. Reported by an admin session running the
repo's smoke test after a fresh CLEAN launch: Telegram never came up on
its own, and only started working after the admin manually created a
missing symlink, restored `telegram.ts`, and re-added the barrel import
by hand. See `pi-bootstrap-patch-fixes.md`'s 2026-08-06 "Telegram
silently broken: pi-bootstrap self-heal SKIPPED on incorrect premise"
entry for the original live-container diagnosis this fix is based on.

**What was broken:** `apply_telegram_import_patch()`'s dependency guard
(added in the very first entry in this file) only ever checked whether
`"@chat-adapter/telegram"` appeared as a literal string in `package.json`.
On this deploy that check was factually correct — the string really
wasn't there, upstream dropped it in commit `25687dc` — but it was the
wrong question. The package was still fully installed and resolvable:
present in pnpm's content-addressable virtual store at
`node_modules/.pnpm/@chat-adapter+telegram@4.29.0/`, nested deps and all.
Only the top-level `node_modules/@chat-adapter/telegram` symlink was
missing — pruned by some earlier `pnpm install` run after `package.json`
stopped listing it, which is normal pnpm behavior (the store itself is
only cleared by an explicit `pnpm store prune`, a separate step nothing
here ever runs). The guard treated "not listed in package.json" and "not
resolvable" as the same condition. They aren't: resolvability is a
property of `node_modules`, not of `package.json`'s text.

Because the guard came back false, the self-heal did the opposite of what
was needed: it quarantined the still-working `telegram.ts` (renamed to
`telegram.ts.orphaned-by-pi-bootstrap`) and skipped restoring the barrel
import — silently disabling a channel that would have worked fine as-is.

**Fix:** `apply_telegram_import_patch()`'s dependency check now verifies
resolvability directly against the filesystem instead of trusting
`package.json` alone, in order: (1) does
`node_modules/@chat-adapter/telegram` already exist (a dangling symlink
correctly falls through, since the check uses `-e`, which follows the
link); (2) if not, does the package exist in the local pnpm virtual store
anyway (`node_modules/.pnpm/@chat-adapter+telegram@*/`) — if so, recreate
just the missing top-level symlink and treat the dependency as present;
(3) only if neither finds it, fall back to the `package.json` listing,
which is the sole signal available on a genuinely fresh install, before
`pnpm install` has ever populated `node_modules`. The function also now
un-quarantines `telegram.ts`/`telegram.test.ts` (moves back from
`*.orphaned-by-pi-bootstrap`) whenever the dependency resolves, undoing
any incorrect quarantine a previous run applied under the old,
package.json-only guard.

### General Lessons

- **A dependency check should test the property you actually care about,
  not a proxy for it that happens to usually agree.** `package.json`
  listing a dependency and that dependency being resolvable at runtime are
  correlated, not identical — package managers prune top-level links
  independently of their content-addressable stores, and a config file's
  text is not the same fact as the filesystem state it's supposed to
  describe. When a guard exists specifically to prevent a broken build,
  check the condition that actually causes the break.

## Follow-up (2026-08-06): whisper-cli and mnemon→Ollama stayed broken after fixes that were already in `master` — one root cause, two symptoms

**Status:** fixed. This closes the "whisper-cli still broken after CLEAN"
investigation that a previous session left open after exhausting the
repo-side leads, and the `ollama_available: false` report that had already
been diagnosed and "fixed" twice.

**Symptoms, as reported from a live deploy:**

- `whisper-cli` inside the running agent container was still dynamically
  linked against a missing `libwhisper.so.1`, even though
  `-DBUILD_SHARED_LIBS=OFF` was confirmed present in both
  `environments/nanoclaw-mnemon/Dockerfile` and `run.sh`'s
  `apply_media_tools_patch()`, and confirmed merged to `master`.
- mnemon kept reporting `ollama_available: false`, even though the
  scheme-gating fix for the `NO_PROXY` ENV that `apply_mnemon_patch()`
  bakes into the agent image had also shipped.

Both had been chased as *patch-content* bugs — were the compile flags
right, was the `NO_PROXY` gating right — and both patches' content was
already correct. Neither symptom was about patch content at all.

**Root cause — the agent-sandbox image was rebuilt too late in the CLEAN
sequence.** These are the steps that mattered, in the order they used to
run:

```
CLEAN's early teardown removes every agent container        (run.sh ~1770)
git reset --hard; patches rewrite container/Dockerfile      (~1824-1931)
orchestrator container starts — NanoClaw is LIVE again      (~1957)
start-nanoclaw.sh restarts NanoClaw                         (~2057)
container/build.sh finally rebuilds the agent image         (~2069)  <-- last
```

Rewriting `container/Dockerfile` changes nothing that runs. The image has
to be rebuilt from it, and then the containers spawned from the *old* image
have to be replaced. But NanoClaw was live and serving from the
orchestrator-start step onward — several steps before the image rebuild. Any
group receiving a message in that window got an agent container spawned from
the still-stale image. Agent containers are long-lived, so it kept serving
from that stale image indefinitely, surviving every later FAST deploy, with
nothing in the flow to notice or replace it.

That single mechanism accounts for both symptoms exactly, including the
detail that made the whisper case so confusing: the *image* was fine and the
*container* was not. An earlier session had already observed precisely that
split — a throwaway `docker run` of the current tag passed `whisper-cli
--help` while the live container failed `ldd` — and correctly changed the
smoke test to check a live container (commit `ff08efd`), but read the split
as a smoke-test accuracy problem rather than as the diagnosis it was.

**Fix:** the agent-sandbox image rebuild now runs *before* both NanoClaw
restart paths, and on success sweeps this install's agent containers, so
anything spawned from the pre-rebuild image is discarded and respawned from
the new one on the next message. `remove_agent_containers()` is the single
point that also clears `pi-bootstrap-smoke-test.md`, so the admin session's
standing self-verification correctly re-triggers afterward.

**Second, contributing cause — content-blind idempotency checks meant a
patch fix could never reach an already-patched install on FAST.** Both
Dockerfile patches tested "is this patched?" with a grep for a single token
the block happens to contain (`yt-dlp`, `MNEMON_VERSION`). That answers
"some generation of this patch is present", never "the current generation
is present". So once a block existed, every later FAST deploy said "already
patched" and left it alone no matter how much the block's text had changed
in this repo since. CLEAN masked this — its `git reset --hard` deletes the
whole block, so the next apply writes current text — which is exactly why it
presented as "fixed in master, still broken live" instead of an obvious
no-op.

Each Dockerfile patch block is now wrapped in versioned markers:

```
# >>> pi-bootstrap:<id> v<N> >>>
...
# <<< pi-bootstrap:<id> <<<
```

giving four distinguishable states instead of two — `current` (no-op),
`stale-marked` (strip the old block, re-splice current text, flag the image
for rebuild), `stale-unmarked` (a pre-marker block, which has no dependable
end boundary because both patches splice at the same anchor: warn loudly,
record it in the manifest, and say plainly that a CLEAN is what fixes it),
and `absent`. A patch that actually rewrites the Dockerfile now sets
`AGENT_IMAGE_NEEDS_REBUILD`, so even a FAST deploy rebuilds the agent image
and sweeps stale containers rather than leaving the write inert.

**Bump the version constant whenever you change a block's text.** That is
the entire mechanism; an edit without a bump is invisible to every existing
install, which is the bug this exists to prevent.

**Third, found while building the above — `_yaml_expand()` hung on any
value containing `&`.** `lib/yaml-lib.sh` substituted with
`result="${result//$expr/$val}"`. In bash 5.2+, an unquoted `&` in a
pattern-substitution *replacement* expands to whatever the pattern just
matched — so a value containing `&` re-injected the `${VAR}` marker into the
result, the loop matched it again, and never terminated. Not a wrong answer:
a hang. Hit for real by a template containing `2>&1`, and it would equally
have hit any `info.yaml`/`desktop-entries.yaml` value with a two-parameter
URL or an "X & Y" label. Fixed by substituting with prefix/suffix splitting
and a quoted `"$expr"` pattern, which inserts the value literally and works
identically on the bash 3.2 macOS still ships (escaping the `&` instead
would have relied on replacement backslash handling that differs across
those versions).

### General Lessons

- **"The fix is in `master` and it's still broken" is a question about
  delivery, not about the fix.** Three separate rounds went into
  re-checking compile flags and proxy gating that were already correct. The
  question worth asking first is: what has to happen for this change to
  reach the thing I'm observing — and did all of it happen, in an order
  that works? Here the change had to reach a file, then an image, then a
  container, and the last hop never ran.
- **An idempotency check that can't tell "patched" from "patched with the
  version I meant" is a silent no-op generator.** It works perfectly until
  the first time you change the patch, and then it fails in the least
  visible way possible: by reporting success. If a patch's text can change
  between releases, its "already applied?" check has to be version-aware.
- **A diagnostic that distinguishes two cases is worth more than one that
  confirms the case you expect.** The image-passes/container-fails split
  was observed and acted on, but as a smoke-test bug rather than as
  evidence. It had already localized the fault to container lifecycle
  rather than patch content; nobody read it that way for several rounds.
- **Ordering bugs hide behind steps that individually all succeed.** Every
  step in the CLEAN sequence worked and reported success. Only their
  relative order was wrong, which no single step's output could reveal.

## Follow-up (2026-08-06, same day): the agent-container sweep never matched anything — a container built 2026-07-21 survived every CLEAN for two weeks

**Status:** fixed. Found immediately after the previous entry's reorder
shipped, when a live CLEAN ran the corrected sequence and the post-rebuild
sweep still reported nothing to remove — while the admin session's smoke
test, written after that same CLEAN, showed a stale agent container still
serving.

**The evidence that made this unambiguous:** the smoke test named the live
container's image as
`nanoclaw-agent-v2-91b144eb:ag-1783945827013-hhyk7w`, built **2026-07-21**,
while `nanoclaw-agent-v2-91b144eb:latest` was from that day and passed the
`whisper-cli` `ldd` check cleanly. The report was provably post-CLEAN on
two independent grounds: it quoted patch statuses as "patched v2" (a marker
string only the versioned-block code emits), and
`remove_agent_containers()` deletes `pi-bootstrap-smoke-test.md`
unconditionally on every CLEAN, so the file could only have been written
afterward.

So the reorder from the previous entry was necessary but not sufficient.
Rebuilding the image before restarting NanoClaw is worthless if the sweep
that replaces the old containers matches nothing.

**Root cause:** `sweep_agent_container_ids()` enumerated with
`docker ps -a --format '{{.ID}} {{.Image}}'` and matched
`^nanoclaw-agent-v2-` on the image field alone. But `docker ps`'s `{{.Image}}`
resolves the container's image ID to a *name at query time*, and falls back
to a bare `sha256:...` when that reference no longer resolves. NanoClaw tags
each agent image ephemerally (`:ag-<timestamp>-<random>`), so once such a tag
is collected or overwritten, the container it produced becomes invisible to
a matcher keyed on the image name — with no error and no output, which reads
exactly like "there was nothing to sweep".

**Fix:** match on the container NAME (`nanoclaw-v2-*`, assigned by NanoClaw
at creation and never rewritten) *as well as* the image reference. That is
also the identifier `scripts/entrypoint.sh`'s own smoke-test checklist tells
the admin session to look for, so the two now agree instead of quietly
using different keys for the same set of containers. Three supporting
changes, all aimed at the same failure mode rather than the specific bug:

- the removal path now lists the container IDs it is acting on, re-runs the
  sweep afterward, and reports any survivor — `docker rm` is deliberately
  best-effort here (`|| true`, so a self-removed container can't abort a
  deploy), which means a failure to remove otherwise produces no output at
  all;
- the "found none" path now says so explicitly and prints the
  `docker ps --filter 'name=nanoclaw-v2-'` command that answers the question
  independently, instead of being silent;
- a container that matches by name/image but is dropped by the bind-mount
  scope check (which exists so a second NanoClaw install on the same host
  isn't swept) is now reported rather than silently skipped, so if that
  check is ever the thing failing, the next run names it.

### General Lessons

- **An identifier that is resolved at query time is not an identifier.**
  `{{.Image}}` looks like a stable property of a container and is actually a
  lookup that can degrade to a different format when the tag it depended on
  goes away. Anything matching on it needs to tolerate both shapes, or key
  on something assigned once and never rewritten — here, the name.
- **"Found nothing" and "did nothing" are different results and must print
  differently.** This sweep had been failing since at least 2026-07-21 and
  produced identical output to a healthy no-op the entire time. The fix that
  matters most long-term is not the matcher — it is that the two cases can
  now be told apart from the log alone.
- **Verify destructive operations that are deliberately best-effort.** `||
  true` is correct here (a container that vanished on its own must not abort
  a deploy) and it also swallows exactly the signal you would want. If a
  step must not silently fail, re-check the postcondition rather than
  trusting the exit status you just discarded.
- **A fix landing and the symptom persisting is information, not a
  setback.** The reorder was right; it just sat downstream of a second,
  independent bug. Reading "still broken" as "the diagnosis was wrong" would
  have reverted a correct change.

## Follow-up (2026-08-07): the real cause of both symptoms was a per-group DERIVED image nothing ever rebuilt — and the two preceding entries were only half right

**Status:** fixed. This supersedes the "stale agent container" conclusion in
the two entries above. Those found real bugs and fixed them, but neither was
the cause of the whisper-cli or mnemon symptoms, and the fixes could not have
resolved them.

**What was actually happening.** NanoClaw does not always run agents from the
base agent-sandbox image. A conversation group that installs custom packages
— via its own `install_packages` self-modification flow, or
`ncl groups add-package` — gets its own **derived image**, built FROM the base
and tagged `nanoclaw-agent-v2-<slug>:<group-id>`. That tag is stored in
NanoClaw's `container_configs` table and `container-runner.ts` passes it
directly to `docker run` on every spawn for that group.

Nothing in pi-bootstrap ever rebuilt those. CLEAN rebuilds the base
(`container/build.sh`) and stops; upstream treats derived images as
operator-managed, refreshed only by `ncl groups restart --rebuild`. So every
patch this environment applies to `container/Dockerfile` landed in the base
and never reached the group that had one. The live install's Clawdia group
(custom packages: `python3`, `yt-dlp`, `ffmpeg`, `cmake`, `build-essential`,
`nodejs-whisper`) ran a **2026-07-21** derived image against a **2026-08-06**
base for over two weeks.

That is the whole explanation for both long-running symptoms:

- `whisper-cli` dynamically linked against a missing `libwhisper.so.1` — the
  derived image was built before the `-DBUILD_SHARED_LIBS=OFF` fix existed.
- `ollama_available: false` — the derived image was built before the NO_PROXY
  scheme-gating fix, so it still had `ENV NO_PROXY=host.docker.internal`
  baked in, which on this platform bypasses the proxy routing that actually
  reaches Ollama.

**Where the previous two entries went wrong.** Both correctly observed that
the base image passed every check while the running agent failed, and both
concluded "stale container — replace it". But replacing the container
achieves nothing here: it respawns from the *same derived image*. The
distinguishing evidence was available and misread — the live container's
image was reported as
`nanoclaw-agent-v2-91b144eb:ag-1783945827013-hhyk7w`, not `:latest`, in
every report. That tag was read as an ephemeral per-spawn tag; it was a
per-group image with the group ID as its tag. One `docker images` listing
would have separated the two readings at any point.

The sweep bug found in the previous entry was real and is still worth having
fixed — the matcher genuinely never matched, and a sweep that reports
"nothing found" identically to "nothing to do" is its own hazard. It just
wasn't this.

**A second, sharper failure mode, hit while cleaning up.** Deleting a derived
image breaks that group **silently and totally**. The tag stays in NanoClaw's
database; `docker run` against a tag with no image and no registry fails
instantly with exit 125; the captured stderr comes back empty, so NanoClaw's
close handler emits nothing at INFO — no "Container exited", no WARN. The
only visible symptom is `Spawning container` repeating every 60 seconds
forever while the pending message count climbs. An operator tidying up "old
nanoclaw images" by hand will hit this, and there is nothing in the logs to
tell them what they did.

**Fix:** `rebuild_stale_group_images()` runs after every base-image rebuild.
It lists `nanoclaw-agent-v2-*` images whose tag isn't `latest`, compares each
one's `.Created` against the base's, and rebuilds any that are older via
`pnpm ncl groups restart --id <tag> --rebuild`. No database access and no
parsing of `ncl groups list` output is needed, because **the image tag is the
group ID** — verified against the live install rather than assumed. A failed
rebuild is reported with the exact manual command and recorded in the
manifest rather than aborting the deploy. `.Created` is compared as an RFC3339
string, which orders correctly without `date -d` (GNU-only, unavailable on
macOS).

A new `templates/patch-details/group-images.md` documents the whole
mechanism, and the smoke-test checklist gained a step 0: establish which
image a group actually runs *before* testing anything inside it.

### General Lessons

- **"The image is healthy but the container isn't" has more than one cause,
  and they need different fixes.** Two consecutive investigations landed on
  "stale container, replace it" because that explanation fits the evidence —
  it just wasn't the only thing that fits. When a diagnosis predicts a fix,
  and the fix ships, and the symptom persists unchanged, the diagnosis is
  the thing to re-examine, not the delivery of it a third time.
- **An identifier you don't recognize is a question, not noise.** The tag
  `:ag-1783945827013-hhyk7w` appeared verbatim in every report from the
  start and was explained away twice with a guess about NanoClaw's internals
  that nobody checked. It was in fact the group ID, which made the whole
  mechanism discoverable from a single `docker images` listing.
- **Patching a base image is only half a delivery path when derived images
  exist.** Anything that builds FROM your artifact is a copy that will not
  update itself. This is the same lesson as "rebuild before restarting",
  one layer further out, and it will generalize to any future per-group or
  per-tenant image NanoClaw adds.
- **A destructive operation with no error output is worse than one that
  fails loudly.** Deleting a derived image produced no log line anywhere in
  NanoClaw at any level. The deploy script cannot fix upstream's silence,
  but it can refuse to leave the situation undetectable — which is what the
  manifest section and the checklist step now do.

## Follow-up (2026-08-07): `ollama_available: false` was Ollama bound to loopback — five rounds of proxy theories, none of them the cause

**Status:** root cause confirmed on the live host. One command settled what
four previous rounds of `NO_PROXY` reasoning could not:

```
$ lsof -nP -iTCP:11434 -sTCP:LISTEN
COMMAND PID  USER   FD   TYPE  DEVICE  SIZE/OFF NODE NAME
ollama  986 homer    3u  IPv4  0x...        0t0  TCP 127.0.0.1:11434 (LISTEN)
```

Ollama's default bind address is `127.0.0.1:11434` — loopback only. An agent
container reaching `host.docker.internal:11434` arrives at the host as
external traffic and is refused. It was never reachable from a container at
any point.

**Why five rounds missed it.** Two independent checks both said "reachable",
and neither was testing what it appeared to test:

- `ensure_ollama_ready()` deliberately rewrites `host.docker.internal` →
  `localhost` so its probe works from a bare host shell. That rewrite is
  correct for what it was added to fix, but it means the probe answers "is
  Ollama running?" and structurally cannot answer "can a container reach it?"
  It passed every deploy.
- `curl` from *inside* the agent container also succeeded — but only via the
  platform's HTTP proxy, which runs on the host and can therefore reach
  loopback. mnemon's Go client goes direct, so it saw the refusal that curl
  never did. The whole "curl works, Go doesn't" signature that anchored four
  rounds of proxy analysis was two different network paths, not two HTTP
  clients disagreeing.

Every `NO_PROXY` change — adding it, removing it, scheme-gating it — was
tuning how requests route to an endpoint that would not accept them either
way. The scheme-gating that shipped is still correct on its own merits; it
just never had anything to do with this symptom.

**Fix:** `warn_if_ollama_is_loopback_only()` runs after the reachability probe
succeeds, and only when the endpoint uses `host.docker.internal` (a
`localhost` endpoint is the orchestrator's own business, where a loopback bind
is correct). It reads the actual listen address via `lsof`, `ss`, or `netstat`
— whichever exists — and if every listener is loopback, warns with the exact
symptom to expect and the platform-specific fix.

It only warns. Rebinding to `0.0.0.0` exposes Ollama to the local network,
which is an operator's security decision, not something a deploy script should
make on their behalf.

**A bug the test caught before it shipped.** The first version extracted the
address with `awk '{print $NF}'`. lsof's NAME column is
`TCP 127.0.0.1:11434 (LISTEN)` — three whitespace-separated fields — so `$NF`
is `(LISTEN)`, which passes every address check downstream. The function would
have run on every deploy and never warned once. Found only by running it
against real `lsof` output rather than eyeballing the parse.

### General Lessons

- **A probe that had to be adjusted to work is a probe worth re-reading.**
  The `host.docker.internal` → `localhost` rewrite was a correct fix for a
  real bug, and it quietly narrowed what the check could ever detect. When a
  check is modified to make it pass, note what it stopped covering.
- **Two clients disagreeing about the same URL may not be disagreeing about
  HTTP at all.** curl and mnemon were taking different network paths — one
  through a host-side proxy, one direct. Everything downstream of "curl works
  so the endpoint is fine" was reasoning from a false premise.
- **Check the listener before debugging the route.** Four rounds went into
  proxy semantics — Go's `httpproxy` rules, curl's uppercase/lowercase
  handling, `applyContainerConfig()` ordering — all of it downstream of
  whether anything was accepting the connection. `lsof -iTCP:<port>` is one
  command and should have been round one.
- **Test a parser against real output, not imagined output.** The `$NF` bug
  was invisible by inspection and obvious the moment real `lsof` output went
  through it.

## Follow-up (2026-08-07): `ollama_available: false` was `host.docker.internal` resolving to a dead address — and nothing ever tested reachability from a container

**Status:** root cause confirmed on the live host, after five rounds of proxy
theories, a bind-address fix, a supervisor fight and an IPv6 red herring. This
supersedes every earlier explanation of this symptom in this file.

**The measurements that ended it:**

```
host:      curl --ipv4 http://192.168.1.50:11434/api/tags   -> 200
container: getent hosts host.docker.internal                -> 192.168.215.1
container: curl --noproxy '*' http://192.168.215.1:11434    -> 000  (refused)
host:      curl http://192.168.215.1:11434                  -> 000
container: curl --noproxy '*' http://192.168.1.50:11434     -> 200
```

`host.docker.internal` resolved to an address nothing listens on. The Mac's own
interface on that bridge was `.0`, containers were handed `.1`, and the only
address reachable from inside a container was the host's plain LAN IP.

**Not a new class of problem for this repo.** The README already documented
"OrbStack's `host.docker.internal`/`host-gateway` resolving to a different
address than the one its own port-publishing actually uses", from an earlier
session. That note existed the whole time and nobody connected it, because the
symptom presented as a mnemon problem rather than a networking one.

**Why it survived so long.** Every check this environment had ran on the host.
`ensure_ollama_ready()` even rewrites `host.docker.internal` to `localhost` so
its probe works from a bare host shell — a correct fix for an earlier bug, which
also guaranteed it could never detect this one. So "is Ollama running?" was
asked repeatedly and "can an agent reach it?" was never asked at all.

Two false signals kept the wrong theories alive:

- **A container-side `curl` appeared to succeed** — but only through a host-side
  HTTP proxy, which can reach the daemon over loopback. `--noproxy '*'` is the
  difference between testing the path your application uses and testing a path
  that happens to exist. The entire "curl works, Go doesn't" signature that
  anchored four rounds of proxy analysis was two different network paths, not
  two HTTP clients disagreeing.
- **`*:11434` looked like a fix.** It was an IPv6 dual-stack listener, which is
  fine, and it was reported as success by a check that only asked "is anything
  bound non-loopback?" The binding was never the remaining problem.

**Fix:** `ollama_reachable_from_container()` runs `curl` inside a throwaway
container from the orchestrator image, against the endpoint agents are actually
configured to use, with `--noproxy '*'`. On failure it derives the host's LAN
address (macOS-capable, unlike `lib/info-lib.sh`'s Linux-only `HOST_IP` logic),
tests whether a container can reach Ollama there, and prints the exact
`MNEMON_EMBED_ENDPOINT` to set. Three outcomes are distinguished — reachable,
unreachable, and not-testable — so a first deploy with no image built yet does
not report a false problem. Everything is recorded into
`pi-bootstrap-patches.md`, because the admin session cannot run any host-side
command from inside its own container.

**A reporting failure worth recording separately.** Three consecutive smoke
tests concluded `ollama_available: false` was "an ongoing known issue, no
practical impact, likely a bug in mnemon 0.1.17's live-probe path". All three
were wrong on both counts: mnemon's probe was accurate every time, and "100%
coverage" meant no new insights had needed embedding — not that embedding
worked. A correct fault was progressively reframed as a known quirk across
successive reports, which is worse than not noticing it.

### General Lessons

- **Test reachability from where the code runs, not from where you are.** Every
  probe here ran on the host; the consumer is a container. That single mismatch
  survived five rounds, a repo-wide refactor, and several correct-but-irrelevant
  fixes. When a service is consumed from inside a container, the only
  meaningful check runs inside a container.
- **A fix that makes a check pass can be the thing that blinds it.** Rewriting
  `host.docker.internal` to `localhost` was correct for the bug it addressed and
  is why this one was undetectable. When you adjust a check to make it work,
  write down what it stopped covering.
- **`curl` succeeding proves a path exists, not that it is *your* path.** A
  host-side proxy silently supplied a route the application did not have. Use
  `--noproxy '*'` when the question is "can this reach it directly".
- **Repeating a benign explanation across reports converts a fault into
  furniture.** "Known issue, no practical impact" appeared three times for a
  live, unresolved defect. A recurring finding should get *more* scrutiny each
  time it recurs, not less.
- **The answer was already in the repo.** A README line documenting OrbStack's
  address-resolution quirk predated this entire investigation. Searching your
  own docs for the *mechanism* — not the symptom — is cheap and was never done.
