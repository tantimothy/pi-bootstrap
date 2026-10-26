**What this is.** Not a patch to NanoClaw: a restore-then-check. `/add-telegram`
and `/add-onecli` are upstream-NanoClaw skill installs that edit tracked files
(`package.json`, the channel barrel, `src/gateway-providers/installed.ts`) and
copy in new source files. CLEAN's `git reset --hard` silently reverts the
tracked half, while the untracked copied files survive and go stale as core
moves. Upstream made the gateway an installed skill in 2.4.0 ("the host
refuses to start without a registered gateway"), so a reverted install is a
crash loop, not a degraded feature.

**Restore.** `scripts/skill-restore-lib.sh` (`restore_skill_install`) replays
only the *declarative* directives in the skill's own `SKILL.md`, read at deploy
time: `nc:copy` (from the skill's payload, or from a git branch such as
`origin/channels`), `nc:append` (an import line, only if absent) and `nc:dep`
(`pnpm add --save-exact`, only if `package.json` lacks that exact pin). File
lists, import lines and version pins are therefore never duplicated here.
`pnpm` runs in a throwaway container from the orchestrator image with the
install mounted at the same path, so the host needs neither node nor pnpm.

It deliberately **never runs a skill's `nc:run` steps.** For `/add-onecli`
that is `setup.ts`, whose default path re-runs the OneCLI *installer* whenever
the `onecli` CLI is absent from the container — which it always is right after
the orchestrator is recreated. That rebinds the gateway listener and installs
upstream's pinned gateway version. The gateway service and its credentials
survive CLEAN; only source wiring needs restoring. Build and tests happen later
in the normal deploy.

**When it runs.** Before the reset, run.sh records whether Telegram
(`TELEGRAM_BOT_TOKEN` in NanoClaw's `.env`) and OneCLI (`ONECLI_URL`, or
`installed.ts` already naming it) were configured. After the patches:

- **CLEAN:** a configured skill is always refreshed, even if its files are
  still present — they are untracked, so they survive the reset while core
  changes underneath them (a stale `telegram.ts` failed `tsc` against
  2026.10.1-rc.2). Files are overwritten from the skill's current
  payload/branch.
- **FAST:** restored only if a feature is configured but not wired.

"Wired" means: source present, registered (barrel / `installed.ts`), and the
dependency declared in `package.json`.

**Then the check.** If a configured feature still fails its check, the deploy
exits non-zero before any rebuild or restart, naming the skill to re-run.
After the deploy, `check_startup_health` also greps this deploy's slice of
`logs/nanoclaw.error.log` for `No gateway provider is registered` and fails
loudly, since that error is otherwise indistinguishable from any other crash.

**CLEAN's local-edit snapshot is now per file.** The pre-reset snapshot of
tracked-file edits used to be one `git apply`, all-or-nothing: one conflicting
file (usually `package.json`) dropped every other edit with it, including the
barrel and `installed.ts` imports. Each file is now saved and reapplied
separately, and the ones that conflict are named.

**Bypass.** `SKIP_SKILL_WIRING_CHECK=1` logs the failure and continues. Use
only if you intentionally removed the feature but left its credential in `.env`.

**Known limits.** Only these two skills. A restore failure (no network, a
changed `SKILL.md` format) falls through to the check, which then fails the
deploy. `nc:append ... at:<marker>` lines are only checked, never spliced.
Telegram multi-bot state lives in `.env` and `data/`, which CLEAN does not touch.
