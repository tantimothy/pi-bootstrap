# Pending Activities

A snapshot of open follow-ups as of **2026-08-07**. GitHub itself (PR/issue
state) is always the authoritative source for anything below that
references a PR — this file is a convenience index, not a system of
record, and goes stale the moment something merges or gets tested. Prune
an entry the moment it's resolved rather than marking it done in place;
an out-of-date "pending" list is worse than none.

---

## Needs a live test to close out

Both from `docs/future-enhancements/claude-cli-gateway-hardening.md` —
full context there, summarized here for visibility:

- **`claude-cli` gateway redirect API-shape compatibility** — confirm
  LiteLLM/Portkey (as deployed by this repo's `llm-gateways` environment)
  actually serve an Anthropic-Messages-API-compatible endpoint at the
  base URLs `environments/claude-cli/.env.gateway.litellm`/
  `.env.gateway.portkey` currently assume. Currently shipped with an
  explicit "not independently verified" caveat in both files and
  `environments/claude-cli/README.md`.
- **`claude-cli` gateway redirect + `/remote-control` interaction** —
  confirm whether an already-linked `/remote-control` session survives a
  live `point-to-gateway.sh` redirect without needing to re-link.

`claude-cli` multi-instance support (`new-instance.sh`, `deploy.sh`'s A-Z
menu tags — PRs #135/#139, both merged) — nothing below has been run
against a real Docker host yet, only simulated/verified in isolation:

- **End-to-end instance creation** — run the "New Claude CLI Instance..."
  `custom_actions` entry (or `new-instance.sh` directly) and confirm a
  second instance actually builds, deploys, and is independently
  SSH-reachable on its own port, with its own `claude_home`/
  `ssh_host_keys` volumes.
- **The action's own visibility** — confirm "New Claude CLI Instance..."
  actually appears in `deploy.sh`'s real policy menu for `claude-cli`
  (alongside FAST/STOP/CLEAN/etc.), not just in the `custom_actions`
  YAML/parsing logic that was checked directly.
## nanoclaw-mnemon: yt-dlp/python3 fix shipped and confirmed, follow-ups still open

Full account in `docs/lessons-learned/nanoclaw-mnemon.md`'s "yt-dlp /
python3 Dependency Chain" section. The bug itself is fixed and confirmed
end-to-end (PRs [#124](https://github.com/tantimothy/pi-bootstrap/pull/124),
[#126](https://github.com/tantimothy/pi-bootstrap/pull/126),
[#127](https://github.com/tantimothy/pi-bootstrap/pull/127), all merged —
a live agent successfully ran `yt-dlp` and transcribed a real video after
the fix). Not yet done:

- **`lib/locale-lib.sh` sourcing in every other environment's `run.sh`** —
  confirmed missing repo-wide (see
  `docs/future-enhancements/nanoclaw-mnemon.md` #2), fixed only in
  `environments/nanoclaw-mnemon/run.sh` so far. Each other environment's
  `run.sh` needs the same one-line `source` added, then a real direct
  invocation (bypassing `deploy.sh`'s menu) to confirm the fix actually
  applies there too — not verified by inspection alone yet.
- **CI build + smoke-test validation** (`docs/future-enhancements/nanoclaw-mnemon.md`
  #1 and #4) — not built. Would have caught the original wrong-asset bug
  at PR time instead of requiring a live agent to hit it.
- **Whether the reinstalled whisper.cpp libs/model actually landed under
  `/workspace/agent` this time** — the agent that lost them to its own
  home directory (lessons-learned issue #5) confirmed reinstalling and
  successfully transcribing a ~37-minute audio file, but not explicitly
  where the libs/model were reinstalled to. If still outside
  `/workspace/agent`, the next routine container respawn (which happens
  on its own, unprompted) will wipe them again.

## nanoclaw-mnemon: approval-delivery patch not yet verified against a live deploy

Full account in `docs/lessons-learned/nanoclaw-mnemon.md`'s "Approval-Card
Silent Delivery Failure" section. The underlying bug and fix were confirmed against a real,
live NanoClaw install (see that section for the investigation) — what's
**not** yet confirmed is that `scripts/patch-approval-delivery.cjs`'s own
text-splice actually applies cleanly against a fresh `git clone` of
`nanocoai/nanoclaw`. It was written directly from the incident report's
own diff (exact anchor text, indentation included) and passes `node -c`
plus a byte-for-byte match against `patch-host-gateway.cjs`'s established
pattern, but this repo doesn't vendor NanoClaw's source, so there's no
local copy to run the patch against and confirm the anchor still matches
upstream today. Not yet done:

- **Run a real `CLEAN` deploy of `nanoclaw-mnemon`** against a fresh clone
  and confirm the patch's own
  console output says "Patched src/modules/approvals/primitive.ts..."
  rather than the "expected body ... has changed upstream — skipping"
  warning path.
- **`pnpm exec tsc --noEmit` / `pnpm run build` after the patch applies**
  — confirm the patched file still compiles cleanly (the incident report's
  own diff was verified this way against the operator's local checkout,
  but that verification doesn't carry over automatically to this repo's
  copy of the patch text).
- **An actual end-to-end repro**: null out the delivery adapter somehow
  (or wait for the original race condition) and confirm a fresh approval
  request now logs the new error + notifies the agent instead of silently
  vanishing.

## mac-terminal-setup: core feature merged and tested, two auto-install paths unverified

Full account in `docs/lessons-learned/mac-terminal-setup.md`. The
environment itself, the whimsy-toggle confirmation fix, and the README
sources documentation are all merged to `master` and confirmed working by
the user on their own Mac. Not yet done:

- **Homebrew and `cpan` auto-install paths in `run.sh`** — both were
  written to handle a Mac missing Homebrew /
  `Acme::Scurvy::Whoreson::BilgeRat`, but the development machine already
  had both, so neither branch has actually executed. See
  `docs/future-enhancements/mac-terminal-setup.md` #1.
- **Calendar data re-sync cadence** — `bin/calendars/` was refreshed
  against `freebsd/calendar-data` once, as a point-in-time snapshot; no
  process exists yet to catch it drifting again over time. See
  `docs/future-enhancements/mac-terminal-setup.md` #3.

## nanoclaw-mnemon: per-group derived agent images — stale case fixed, deleted case still open

Full account in `docs/lessons-learned/nanoclaw-mnemon.md` ("the real cause
of both symptoms was a per-group DERIVED image nothing ever rebuilt"), the
mechanism in `environments/nanoclaw-mnemon/README.md`'s "Per-group agent
images" section, and the design options in
`docs/future-enhancements/nanoclaw-mnemon.md` #7.

- **Shipped and needs a live confirmation:** `rebuild_stale_group_images()`
  rebuilds any `nanoclaw-agent-v2-*:<group-id>` image older than the base
  after each base rebuild. Verified only against a mocked Docker — no live
  CLEAN has exercised it yet. What to look for: a
  `Group '<id>' runs a derived agent image older than the base` line,
  followed by a multi-minute package reinstall, after which `ldd` inside
  that group's agent reports `not a dynamic executable`.
- **Now handled, needs a live confirmation:** a derived image that is
  *deleted or never built on this host* is detected via the tag list `run.sh`
  records at `data/pi-bootstrap-group-images.txt` (inside the backup, so it
  survives a restore) and rebuilt automatically. This matters most for
  **restore onto a new host**: the database comes back with each group's
  stored `imageTag`, but Docker images are never in a backup, so the image has
  never existed there. Previously that failed silently — spawn retried every
  60s, exit 125, empty stderr, no WARN. Verified against a mocked Docker only.
- **Also unverified:** whether mnemon's `ollama_available` actually flips to
  true once a group runs a derived image rebuilt on the current base. The
  live proxy diagnostic (direct connection refused, via-proxy HTTP 200, both
  `HTTP_PROXY` and `http_proxy` set) confirms the current `https://`-only
  `NO_PROXY` scheme-gating is correct, so this is expected to resolve with
  the image — but it has not been observed resolving.

## Known, deliberately-deferred code quality items

Tracked in full in `docs/refactoring-opportunities.md`, not duplicated
here — includes shared logic between `point-to-gateway.sh`/
`revert-to-claude.sh`, three independent "auto-discover, else prompt,
else fall back" implementations, `backup.sh`'s manually-maintained
`is_deployed()` case statement, `new-instance.sh`'s `sed`-based
`config/environments.yaml` registration and its SSH-port suggestion not
checking real port availability, `nanoclaw-mnemon`'s yt-dlp arch-detection
logic duplicated across three files, `mac-terminal-setup`'s
backup-before-overwrite helpers having no shared home with any other
`run.sh`-based environment, and the total absence of automated tests for
`lib/*.sh`'s `${VAR}`-expansion contract.
