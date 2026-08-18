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
scripts' own mechanics were exercised directly on Linux — catalogue
parsing, availability filtering, the dialog and plain-text menus, the
login-mode time limit actually killing the process it bounds (an earlier
version killed only the wrapper subshell and left the splash running as an
orphan; fixed and re-confirmed), and `run.sh` deploying and fetching
everything into the right layout under a throwaway `$HOME`. Since then the
user has run it on their own Mac, which closed some of this out and turned
the rest from "reasoned from upstream source" into "seen failing, fixed,
awaiting a re-run" — see issues #6-#8 in
`docs/lessons-learned/mac-terminal-setup.md`. What remains:

- ~~**`brew install ...` of the new formulas**~~ — done: the deploy ran on
  the user's Mac and `aafire` (from `aalib`) launched, so the whimsy
  package list installs. `sl` and `tty-clock` haven't been individually
  eyeballed but come from the same `brew install` line.
- **The `bb` build** — the only step in this environment that compiles
  anything, and the one that has needed the most rounds. `bin/install-bb`
  builds `artyfarty/bb-osx` (a fork of a 1997 autoconf-2.13 tree) against
  aalib and libmikmod, and now carries four workarounds: the fork's
  committed `config.cache`, autotools regeneration from clone mtimes,
  clang 16's promotion of implicit-`int` to an error, and `regparm` being
  x86-32 only (issues #4-#7 in the lessons-learned file). On the Mac it
  has got as far as compiling bb's own sources; the `regparm` fix is the
  first thing the next run will test. Every fix so far is confirmed not to
  regress the Linux/gcc build, which still completes. The honest state is
  "no known remaining blocker", not "known to work" — each round has
  revealed exactly one more thing. The failure stays fully contained
  (`|| true`, a logged `.build-failed` marker, `bb` showing as
  `[not installed]`), so if a round ever turns up something genuinely
  unfixable, dropping `bb` back to a documented manual build costs
  nothing else.
- **Whether `aafire` renders in place on that Mac** — it scrolled, which
  is the signature of aalib falling back to its `stdout` driver (issue
  #8). `whimsy-splash` now requests the best driver aalib reports, but
  whether Homebrew's aalib has a real terminal driver compiled in at all
  is still unknown; `aafire -help` on the machine answers it. If it has
  none, the fix is outside this repo — a differently-built aalib.
- **hollywood inside this environment's own tmux** — `.bashrc.tmux`
  auto-attaches tmux before the whimsy block runs, so on a real login
  `$TMUX` is always set and hollywood takes its "already in tmux" branch:
  a new *window* in the user's own session rather than a session of its
  own. Verified to work that way under a synthetic tmux session on Linux;
  not seen against the real login sequence, where the window appearing and
  then vanishing mid-login is the part worth eyeballing.
- **How the seven curated widgets actually look** — four fetched from
  upstream (`cmatrix`, `figlet`, `htop`, `pv`) and three written here
  (`mac-logs`, `mac-hexdump`, `mac-netstat`). The three new ones are built
  on `log stream`, `hexdump -C` and `netstat -w 1`; the commands are
  right, but whether each is legible in a pane a few rows tall is a
  judgement only a real screen can make.
- **Upstream's own fragility, inherited** — hollywood opens its first pane
  with one randomly-chosen widget and exits immediately if that widget
  dies, which is exactly what a missing dependency does. Observed on Linux
  (where most widgets can't run) and the reason the widget directory is
  curated to things that work rather than mirrored wholesale. If it ever
  turns up on macOS, the widget whose tool is missing is the thing to find.

**Close this out by:** running `~/bin/whimsy-menu` on that Mac and
launching all twelve splashes from it — then
opening a few new terminal tabs to see the random login pick, including at
least one that lands on `hollywood` or `genact` and hits the
`WHIMSY_SPLASH_SECONDS` limit.
