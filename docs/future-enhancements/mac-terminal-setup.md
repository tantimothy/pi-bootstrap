# Mac Terminal Setup — Future Enhancements

**Status:** ideas only — none of this is implemented. See
`docs/lessons-learned/mac-terminal-setup.md` for what was actually found
and fixed while building this environment; these are the follow-ups worth
doing deliberately rather than reactively.

## 1. Verify the Homebrew and `cpan` auto-install paths on a genuinely missing-dependency Mac

`run.sh` handles two "install this if it's missing" cases: Homebrew itself
(via the official install script, after confirming with the user) and the
`Acme::Scurvy::Whoreson::BilgeRat` CPAN module the insult generators need
(via `cpan -T`, only attempted when whimsy is enabled). Both were written
to degrade sensibly on a machine that doesn't already have them, but the
development machine had both installed already — so neither branch has
actually executed. This is exactly the same shape of unverified-assumption
gap as `claude-cli`'s gateway-redirect caveat
(`docs/future-enhancements/claude-cli-gateway-hardening.md`): shipped with
reasonable logic, not yet confirmed against the real failure case it exists
to handle. In particular, `cpan -T`'s very first invocation on a machine
with no prior CPAN configuration usually prompts an interactive
"configure now?" wizard the first time it runs at all — untested whether
that collides badly with `run.sh`'s own prompts, or just adds an extra
one-time interactive step the user has to get through.

**Close this out by:** running `run.sh` on a Mac with neither Homebrew nor
that CPAN module already present (a fresh VM, or a Mac that's never had
either installed) and confirming both branches behave as intended —
Homebrew's install-then-continue path, and `cpan`'s first-run configuration
prompt (if any) not breaking the rest of the script.

## 2. Add a "fully remove whimsy" option, not just "disable"

Turning whimsy off (via the `.env` toggle or the `custom_actions` menu
entry) removes the `WHIMSY` block from `~/.bashrc` but deliberately leaves
the already-copied `~/bin` scripts and Homebrew formulas in place —
intentional, since they're inert once nothing calls them and re-enabling
later is then instant with no re-copy/re-install needed. Someone who wants
a genuinely clean uninstall (not just "quiet for now") has no single action
for that today; they'd have to manually `brew uninstall` the
`packages-whimsy.txt` formulas and delete the bundled `~/bin` files
themselves.

**Would need:** a second custom action ("Remove whimsy files and
packages") that reverses `run.sh`'s whimsy-deploy step — backs up (per this
environment's existing `_deploy_file` convention) then deletes the bundled
`~/bin` scripts, and optionally offers to `brew uninstall` the
`packages-whimsy.txt` formulas (guarded, since other things on the Mac
might independently depend on `cowsay`/`fortune`/etc.).

## 3. Periodic re-sync of the bundled calendar data against upstream

`bin/calendars/` was refreshed to match `freebsd/calendar-data` at the time
this environment was built (see lessons-learned issue #3), but it's a
point-in-time snapshot, not a live mirror — it will drift again as
upstream keeps getting corrections and new entries, the same way the
original Debian `bsdmainutils` copy silently drifted for years before
anyone checked.

**Would need:** nothing automated necessarily — even just a dated note (or
a `docs/pending-activities.md` entry) to re-run the same
`git clone --depth 1 https://github.com/freebsd/calendar-data` +
`diff -rq` comparison this environment's build used, every year or two, and
re-sync if it's drifted meaningfully. A GitHub Actions workflow that does
this on a schedule and opens a PR on drift would close the gap for good,
but is likely more machinery than a once-a-year manual check justifies for
what's ultimately a whimsy feature.
