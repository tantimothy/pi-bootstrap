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
everything into the right layout under a throwaway `$HOME`. None of it has
run on macOS, which is the only OS this environment supports, so what's
below is reasoned-from-upstream-source rather than seen working:

- **`brew install genact no-more-secrets sl tty-clock aalib dialog figlet
  pv htop`** — every one of those formula names was confirmed to exist in
  `homebrew-core` (and `hollywood` and `bb` confirmed *not* to, which is
  why `run.sh` fetches one and compiles the other), but no `brew install`
  has actually been run.
- **The `bb` build** — the only step in this environment that compiles
  anything. `bin/install-bb` builds `artyfarty/bb-osx` (a fork of a 1997
  autoconf-2.13 tree) against aalib and libmikmod. This one is *partly*
  verified: it was run end to end on Linux with gcc, where it now produces
  a working binary — but only after fixing two real blockers that would
  have hit macOS just as hard, and one Linux-only link error (all three in
  `docs/lessons-learned/mac-terminal-setup.md`, session 2). What's left
  unverified is the compiler itself: clang is stricter than gcc about the
  implicit function declarations this vintage of C used freely, and the
  fork's claim to build on "modern Macs" dates from whenever it was last
  touched. The failure is fully contained (`|| true`, a logged
  `.build-failed` marker, and `bb` showing as `[not installed]`), so the
  question isn't whether a failure breaks anything — it's whether it
  succeeds. If it doesn't, the options are patching the fork, adding
  `-Wno-implicit-function-declaration`, or dropping `bb` back to a
  documented manual build.
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

**Close this out by:** enabling whimsy on a real Mac, running
`~/bin/whimsy-menu`, and launching all twelve splashes from it — then
opening a few new terminal tabs to see the random login pick, including at
least one that lands on `hollywood` or `genact` and hits the
`WHIMSY_SPLASH_SECONDS` limit.
