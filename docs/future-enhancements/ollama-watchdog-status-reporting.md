# `ollama-watchdog.sh --status` should report the scheduled config, not the live one

**Status: open, small, and worth doing.** Found by inspection rather than by a
failure — full account in `docs/lessons-learned/general.md` (2026-08-15).

## The problem

`--status` exists to answer "is this set up correctly?". On the one field where
being wrong is both silent and costly — the bind address — it reports a value
that is not necessarily the one the scheduled job will use.

Two copies of `OLLAMA_SERVE_HOST` are in play:

- the **live** one, read from `environments/ollama/.env` as loaded right now;
- the **baked** one, written into the LaunchAgent plist's `EnvironmentVariables`
  dict at `--install` time (`ollama-watchdog.sh:200-214`), or into the cron
  line's inline assignment on Linux — and this is what every scheduled restart
  actually runs with.

`--status` prints the first and never reads the second. Install the schedule
before setting `.env`, then set `.env` afterwards, and the two disagree
permanently while `--status` reports the value that isn't in charge.

*Since 2026-08-24 `--status` does read the installed plist* — for the version
marker, to report a schedule that predates a fix to the plist's contents. So the
"read it back out of the plist" mechanics below no longer start from nothing;
`_plist_is_current()` is the existing reader to extend.

The divergence only takes effect on the next *watchdog-initiated* restart, which
binds loopback, refuses every container, and reports healthy on every cycle
thereafter — the 2026-08-07 loopback bug reached by a different route.

A real `--status` run makes the shape clear: correct bind address, `Schedule:
installed (launchd, every 300s)`, health responding, `Ollama is listening on:
*:11434`. Every line true, none of them evidence about the plist.

## Proposed change

- When a schedule is installed, read `OLLAMA_SERVE_HOST` back **out of the
  plist** (`PlistBuddy`, `plutil -convert json`, or a plain `grep -A1` on the
  known key) or out of the cron line, and report that as the operative value.
- Print the live `.env` value beside it and flag a mismatch explicitly —
  `⚠️ scheduled job will use <baked>, .env says <live> — re-run the install
  action to reconcile`. A mismatch is not an error state (it's exactly what
  exists between editing `.env` and re-installing), so it warns rather than
  exiting nonzero.
- Same treatment for `OLLAMA_HOST` and the timeout, baked by the same mechanism
  with the same drift.
- While in there: report **what currently supervises** Ollama (Homebrew
  service, a bare `ollama serve`, Ollama.app), since two supervisors for one
  daemon is a worse failure than none, and `--status` is where an operator would
  look for it.

## Boot persistence — the *loading* half is closed; the rest was not, and is now fixed

This file previously proposed a `--install-daemon` mode writing a system
LaunchDaemon to `/Library/LaunchDaemons`, because `--install` writes a
**LaunchAgent** and LaunchAgents load at user login rather than at boot. On a
host that rebooted to the login window, neither Ollama nor the watchdog would
come back — which is exactly the 2026-08-15 outage.

**That host auto-logs-in on reboot** (confirmed 2026-08-15), so the LaunchAgent
loads at auto-login and `RunAtLoad` fires immediately. That part still holds, and
the LaunchDaemon proposal stays dropped. The dependency it rests on is worth
knowing because it is load-bearing and invisible: **auto-login staying enabled.**
Disable it later — for a security review, a hardware change, a new operator — and
the boot gap silently returns, with no warning from anything in this repo. The
LaunchDaemon design is recoverable from this file's history along with its
constraints: a root-owned plist, `UserName` set to the operator's account
(Ollama's models live in `~/.ollama`, so a root daemon starts fine and sees no
pulled model), collision with Homebrew's own LaunchAgent, and `OLLAMA_SERVE_HOST`
threaded through so a boot-time daemon doesn't come up bound to loopback.

**What this section got wrong, and what the 2026-08-24 reboot cost.** It
concluded "`--install` is sufficient" from the agent *loading*, and never asked
what the agent could do once loaded. It could do very little: launchd hands a job
a `PATH` without Homebrew on it, so the scheduled run could not find `ollama` or
`brew` at all, and launchd kills whatever is left in a finished job's process
group, so a tick that did manage to start the daemon had it killed seconds after
logging the restart as successful. The host rebooted on 2026-08-24 and Ollama
stayed down exactly as before. Both are fixed — `set -m` and `ollama_ensure_path()`
in `lib/ollama-lib.sh`, `PATH` and `AbandonProcessGroup` in the generated plist —
and the full account is the 2026-08-24 entry in `docs/lessons-learned/general.md`.

The general form of the mistake is worth keeping in view for the rest of this
file: a boot-persistence question is not answered by "the supervisor starts", it
is answered by "the daemon is still serving five minutes later."

## Related

- `docs/lessons-learned/general.md` — the 2026-08-15 `--status` entry, the
  2026-08-15 outage that led to it, and the 2026-08-07
  `OLLAMA_HOST`/`OLLAMA_SERVE_HOST` collision that explains why the bind address
  has to be threaded through every install path in the first place.
- `environments/ollama/info.yaml` — the `custom_actions` entries these commands
  are reached through, and where `OLLAMA_SERVE_HOST` comes from.
