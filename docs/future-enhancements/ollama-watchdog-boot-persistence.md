# `ollama-watchdog.sh` boot persistence on a headless macOS host

**Status: open question first, proposal second.** The proposal below is only
worth building if the answer to the question is "yes" — establish that before
writing any code.

## The gap

`ollama-watchdog.sh --install` writes a LaunchAgent to
`~/Library/LaunchAgents/`, with `RunAtLoad` and a `StartInterval` (default
300s). That covers the case it was built for — a running daemon whose HTTP API
has wedged — and, via `RunAtLoad`, also restarts a stopped one as soon as the
agent loads.

**LaunchAgents load at user login, not at boot.** So on a host that reboots and
sits at the login window:

- Ollama does not start (no login item fires either).
- The watchdog does not start, so nothing notices.
- Both stay down until a human logs in or intervenes.

This is not hypothetical — it happened on 2026-08-15 and left mnemon running
graph-only for an unknown period with no symptom anywhere. Full account in
`docs/lessons-learned/general.md`.

## The question to answer first

**Does the host in question auto-log-in after a reboot?**

- **If yes**, `--install` is already sufficient. The agent loads at auto-login,
  `RunAtLoad` fires immediately, Ollama is back within seconds, and there is
  nothing to build. Document that the guarantee depends on auto-login and stop.
- **If no**, the LaunchAgent can never cover a reboot, and the rest of this
  document applies.

Checking it costs one reboot and is worth more than any amount of design
discussion, since it decides whether this file describes a real gap or a
non-issue.

## Proposal, if the answer is "no"

Add a `--install-daemon` mode (name it distinctly — do **not** silently change
what `--install` does, since the existing behavior is correct for interactive
Macs and for the Linux/cron path) that writes a system LaunchDaemon to
`/Library/LaunchDaemons/`, which launchd starts at boot with no login required.

Constraints that make this more than a path change:

- **Root.** `/Library/LaunchDaemons` needs `sudo`, and the plist must be
  root-owned with restrictive permissions or launchd refuses to load it. That
  makes it the first thing in this repo whose install step requires elevation,
  so it must be explicitly opt-in and prompted, in the same spirit as
  `ensure_ollama_ready()`'s y/N install gate.
- **Which user runs Ollama.** A LaunchDaemon runs as root unless `UserName` is
  set. Ollama's models live in a user's home (`~/.ollama`), so the daemon almost
  certainly needs `UserName` set to the operator's account, not root — otherwise
  it starts an Ollama that can't see any pulled model. This is the detail most
  likely to produce a "running but useless" daemon, which is precisely the
  failure shape the 2026-08-07 loopback-bind entry warns about.
- **Interaction with Homebrew's own service.** If Ollama is managed by `brew
  services`, that is itself a LaunchAgent with the same login-scoped limitation,
  and two supervisors for one daemon is a worse failure than none. `--status`
  should report what is currently supervising Ollama before anything else is
  installed.
- **`OLLAMA_SERVE_HOST` must carry through**, same as the existing plist and
  cron paths already do. A boot-time daemon that comes up bound to loopback
  restores nothing for the containers that need it.

## Cheaper alternatives worth considering first

- **Enable auto-login on the host.** One system setting, no code, and it makes
  every existing LaunchAgent (including `brew services`) behave as intended
  after a reboot. Security tradeoff on a machine with a physical console; likely
  irrelevant for a headless box in a cupboard, which is the point.
- **Add a reachability line to an existing periodic job** rather than a new
  daemon, so the *absence* of embeddings becomes visible even when nothing
  restarts it. This doesn't fix the outage, but it converts a silent
  degradation into a reported one — which, per the lessons-learned entry, was
  the actually damaging part.

## Related

- `docs/lessons-learned/general.md` — the 2026-08-15 outage, and the 2026-08-07
  `OLLAMA_HOST`/`OLLAMA_SERVE_HOST` collision that explains why the bind address
  has to be threaded through every install path.
- `ollama-watchdog.sh` — `--install`, `--status`, `--uninstall`, and the
  `OLLAMA_SERVE_HOST` handling this would extend.
