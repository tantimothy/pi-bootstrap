**What this is.** Not a patch: a check. `/add-telegram` and `/add-onecli` are
upstream-NanoClaw skill installs that edit tracked files (`package.json`,
the channel barrel, `src/gateway-providers/installed.ts`) and copy in new
source files. CLEAN's `git reset --hard` silently reverts the tracked half.
pi-bootstrap cannot re-run those skills headlessly — they are upstream's
interactive installs, and guessing their steps would splice blind — so it
detects the loss instead and stops the deploy.

**What it checks.** Before the reset, run.sh records whether Telegram
(`TELEGRAM_BOT_TOKEN` in NanoClaw's `.env`) and OneCLI (`ONECLI_URL` in
`.env`, or `installed.ts` already naming it) were configured. After every
patch has run, and before any rebuild or restart, it requires:

| Feature | Required on disk |
|---|---|
| Telegram | `src/channels/telegram.ts` (not quarantined to `*.orphaned-by-pi-bootstrap`) |
| OneCLI | `src/gateway-providers/onecli.ts`, and `installed.ts` referencing it |

If a configured feature fails its check the deploy exits non-zero with the
skill to re-run. Reason for failing rather than warning: with no gateway
provider registered NanoClaw throws `No gateway provider is registered in
this build` on every boot and crash-loops with a backoff of up to 900s, so
the whole service looks dead while the cause is a deploy-time loss.

**Fixing it.** Run `/add-telegram` or `/add-onecli` in a Claude Code session
inside the install directory, then redeploy. The setup of both reuses the
existing token/gateway, so no credentials need re-entering.

**Bypass.** `SKIP_SKILL_WIRING_CHECK=1 ./deploy.sh` (or in the env that runs
`run.sh`) logs the failure and continues. Use only if you intentionally
removed the feature but left its credential in `.env`; the better fix is
deleting the stale `.env` entry.

**Known limits.** The pre-existing snapshot-and-reapply of local edits is
still best-effort and unchanged. Only these two skills are checked. The
Telegram check does not verify the dependency resolves; the telegram-import
patch above owns that.
