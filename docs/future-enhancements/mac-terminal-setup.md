- **Whether the rebuilt aalib actually renders in place on that Mac** —
  the machine reported `available drivers:stdout stderr`, confirming
  Homebrew's aalib has no terminal driver at all (issue #9), so
  `bin/install-aalib` now builds one with `--with-ncurses`. That build and
  its two workarounds are verified on Linux against ncurses 6 — the harder
  case, since macOS's own SDK ncurses is the older non-opaque 5.7 — but
  the macOS run hasn't happened. What to watch: whether the SDK path from
  `xcrun --show-sdk-path` is picked up when Homebrew's ncurses isn't
  installed, and whether `bb` visibly improves after `install-bb` rebuilds
  it against the new aalib.
# Mac Terminal Setup — Future Enhancements

**Status:** follow-ups, not shipped work — each item below is either an
idea nothing implements yet (#2, #3) or something that ships today but has
never been exercised on a real Mac (#1, #4). See
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

## 4. Confirm the seven new splashes actually behave on a real Mac

`hollywood`, `genact`, `nms`, `aafire`, `bb`, `sl` and `tty-clock` were
added to the splash catalogue
(`environments/mac-terminal-setup/bin/whimsy-splash`) along with
`bin/whimsy-menu`, the TUI for launching any of them on demand. The
scripts' own mechanics were exercised on Linux; everything platform-shaped
about them was then found the hard way on the user's own Mac, one round at
a time — four blockers in the `bb` build, and two in aalib's rendering, all
written up as issues #4-#9 in
`docs/lessons-learned/mac-terminal-setup.md`.

**Mostly closed.** The user confirms `bb` builds and runs, and that
`aafire` renders correctly — including inside tmux, which was the last
thing failing. What that leaves:

- ~~**`brew install ...` of the new formulas**~~ — done.
- ~~**The `bb` build**~~ — done: builds and runs on Apple Silicon, after
  four workarounds (the fork's committed `config.cache`, autotools
  regeneration from clone mtimes, clang 16's implicit-`int` error, and
  `regparm` being x86-32 only).
- ~~**Whether `aafire` renders in place**~~ — done, via
  `bin/install-aalib`. Homebrew's aalib has no terminal driver at all
  (issue #9), so this environment now builds one that does.
- **Which fix made it work inside tmux** — the open one, and it matters
  for the *next* machine rather than this one. aalib's curses driver needs
  a terminfo entry for `$TERM`; without one it silently falls back to the
  streaming driver, which is what "fine outside tmux, scrolls inside it"
  looks like. Two fixes were on the table — `brew install ncurses` plus an
  `install-aalib --force` (Homebrew's ncurses carries a current terminfo
  database), or pointing tmux's `default-terminal` at something macOS can
  describe. Whichever it was isn't recorded, so a fresh Mac may well hit
  the same wall. **If it was the ncurses one**, `install-aalib` should
  install that formula itself rather than quietly falling back to the
  SDK's older copy; today it only *prefers* Homebrew's ncurses when it
  happens to be there.
- **The other nine splashes, individually** — `sl` and `tty-clock` come
  from the same `brew install` line that worked, and nothing has been
  reported wrong with the older five, but only `bb` and `aafire` have been
  explicitly confirmed on that machine.
- **hollywood inside this environment's own tmux** — `.bashrc.tmux`
  auto-attaches tmux before the whimsy block runs, so on a real login
  `$TMUX` is always set and hollywood takes its "already in tmux" branch:
  a new *window* in the user's own session rather than a session of its
  own. Verified that way under a synthetic tmux session on Linux; the part
  worth eyeballing on a real login is the window appearing and then
  vanishing mid-sequence.
- **How the seven curated hollywood widgets actually look** — four fetched
  from upstream (`cmatrix`, `figlet`, `htop`, `pv`) and three written here
  (`mac-logs`, `mac-hexdump`, `mac-netstat`), the latter built on `log
  stream`, `hexdump -C` and `netstat -w 1`. The commands are right;
  whether each is legible in a pane a few rows tall is a judgement only a
  real screen can make.
- **Upstream hollywood's own fragility, inherited** — it opens its first
  pane with one randomly-chosen widget and exits immediately if that
  widget dies, which is exactly what a missing dependency does. Observed
  on Linux (where most widgets can't run) and the reason the widget
  directory is curated rather than mirrored. If it turns up on macOS, the
  widget whose tool is missing is the thing to find.

**Close this out by:** launching the remaining splashes from
`~/bin/whimsy-menu` on that Mac, and opening a few new terminal tabs to
see the random login pick — including at least one that lands on
`hollywood` or `genact` and hits the `WHIMSY_SPLASH_SECONDS` limit.
