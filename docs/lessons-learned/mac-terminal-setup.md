# Mac Terminal Setup Environment — Build Lessons Learned

**Status:** all fixes below are merged directly to `master` (local merges by
the user, not GitHub PRs — see Related Commits) and confirmed working on
the user's own Mac ("merged and tested"). This document is the record of
what the live dotfiles this environment was built from actually did wrong,
found while porting them into a reproducible `run.sh`, plus what's still
genuinely open.

## Summary

`environments/mac-terminal-setup` was built by copying five dotfiles
(`.bash_profile`, `.bashrc`, `.gitconfig`, `.screenrc`, `.tmux.conf`) out of
the user's live home directory and turning them into an idempotent,
backed-up `run.sh` — the macOS/Homebrew counterpart to `pi-barebones`.
Investigating the *live* `.bashrc` during that work (by shelling out, which
sources it) surfaced three real, independent bugs in content that had been
running on a real machine for years without anyone noticing, because none
of them show up in a normal interactive terminal session — only when
something touches the shell non-interactively, or actually diffs the
bundled data against its upstream source.

## Issues Found & Fixed

### 1. No interactive-shell guard — every non-interactive bash invocation ran the whole whimsy cascade

**Symptom:** repeatedly, over the course of one build session, plain
read-only shell commands (`find`, `ls`, `git status`) hung indefinitely
with `Press any key to continue...stty: stdin isn't a terminal` printed
and no way to proceed short of killing the process. Separately, every such
invocation printed `fmt: width must be positive` and
`~/.bashrc: line 154: [: : integer expression expected` to stderr, and
silently left the shell's working directory wherever the block's own `cd`
calls last put it.

**Root cause:** the live `.bashrc` had no `[[ $- == *i* ]] || return`
(or equivalent) guard anywhere — every single bash process this repo's own
tooling spawned to run a command sourced the file end to end, including a
randomly-selected splash animation, a `read`-based "press any key" pause
gated only on `stty` succeeding (which itself fails, but doesn't stop the
following `dd ibs=1 count=1` from still blocking on a real read), and a
`tput cols` call that returns empty outside a real terminal — which is what
fed the empty string into `[ "$screen_width" -lt 65 ]` and `fmt -w
$remaining_width`, producing the errors above.

**Fix:** the ported version wraps the entire injected `.bashrc` region in
`[[ $- == *i* ]] || return` as the first line of the `prompt` block (see
`.bashrc.prompt`), and separately hardens the calendar-formatting logic to
default `screen_width` to `80` when `tput cols` returns nothing, and gates
the "press any key" pause behind `[ -t 0 ]` so it no longer blocks when
stdin isn't a real terminal.

### 2. Broken relative path to the insult-generator scripts

**Symptom:** the live `.bashrc`'s "Shakespearean Epithet" and "Piratical
Insult" lines printed `Can't open perl script "bin/insulthost.pl": No such
file or directory` on every single observed run — the feature had been
silently broken, indefinitely, on the live machine.

**Root cause:** `perl bin/insulthost.pl` (and the piratical equivalent)
used a path relative to the shell's current working directory, which is
essentially never `~/bin` at the point `.bashrc` runs — only ever correct
by coincidence.

**Fix:** the ported version calls `perl ~/bin/insulthost.pl` /
`~/bin/piratehost.pl` (absolute paths), and bundles both scripts (plus
their `Acme::Scurvy::Whoreson::BilgeRat` CPAN dependency and
`bin/bofhserver/excuses.txt`) into the environment directory so `run.sh`
can deploy them anywhere, not just read them from this one machine's
pre-existing `~/bin`.

### 3. Bundled calendar data was years stale relative to its own upstream

**Symptom:** none, until asked to check — the live `.bashrc`'s "Today's
Calendars" feature read from
`~/bin/bsdmainutils-master-usr.bin-calendar-calendars/`, a directory that
had been sitting there since 2023 with no indication it was out of date.

**Root cause:** that directory was a one-time clone of a Debian
`bsdmainutils` packaging of FreeBSD's calendar data, never updated since.
Diffing it against the actual current upstream
([freebsd/calendar-data](https://github.com/freebsd/calendar-data)) found:
two entire calendar files missing (`calendar.austria`, `calendar.danish`,
the latter with its own new `da_DK.UTF-8` locale dir), a stale
`#include <calendar.austria>` line silently absent from `calendar.all`,
~80 lines of genuine content drift in `calendar.history`, and a full set of
locale directories still named after their old legacy encodings
(`ru_RU.KOI8-R`, `de_DE.ISO8859-1`, etc.) that upstream had since
consolidated to plain UTF-8 equivalents — themselves containing real
content updates beyond just the encoding change.

**Fix:** replaced the bundled `bin/calendars/` wholesale with a fresh clone
of upstream `freebsd/calendar-data` (verified zero-diff against it
afterward), dropping the one non-upstream file (`cal.mini`, a Debian
addition that the whimsy script's `for file in calendar.*` glob never
actually read anyway).

## General Lessons

- **A live, years-old shell rc file is not a reliable source of truth for
  "what does this feature actually do"** — treat it as something to
  verify against reality (does the referenced path exist, does the output
  match what the code implies), not just copy forward. All three issues
  above were invisible to the person who'd been using this `.bashrc` daily;
  none were exotic bugs, just ones that only show up in contexts (a
  non-interactive shell, a diff against upstream) that normal day-to-day
  interactive use never exercises.
- See `docs/lessons-learned/general.md` for two more lessons from this same
  build that generalize beyond this one environment: auditing copied
  dotfiles for personal-identity content before bundling them, and
  verifying a commit actually survived a push rather than assuming it did.

## Current Pending Activities / Open Items

- [ ] **Homebrew and `cpan` auto-install paths in `run.sh` are unverified.**
  Both were written to handle a fresh Mac missing Homebrew /
  `Acme::Scurvy::Whoreson::BilgeRat`, but the development machine already
  had both, so neither code path has actually executed. See
  `docs/future-enhancements/mac-terminal-setup.md`.

## Session 2 (2026-08-18): building BB from source for the splash menu

**Status:** all six fixed and confirmed working on the user's Mac — `bb`
builds and runs, and `aafire` renders in place, including inside tmux.
Issues #4 and #5 were found on Linux with gcc while implementing; #6-#9
came from running it on the Mac, one round at a time, each fix getting one
step further and revealing the next thing. One loose end is tracked in
`docs/future-enhancements/mac-terminal-setup.md` #4: which of two possible
fixes made the tmux case work isn't recorded, and a fresh Mac may hit that
wall again.
Issue #9 is the one that finally explains the aafire/bb rendering, and it
was only reachable because the machine was asked what drivers it had
rather than being reasoned about.

Context: `bb` (AA-lib's demo) was added to the whimsy splash catalogue
alongside `aafire`, `sl` and `tty-clock`. The other three are Homebrew
formulas; `bb` is packaged nowhere for macOS — not homebrew-core, not
MacPorts — so `bin/install-bb` compiles it from
[artyfarty/bb-osx](https://github.com/artyfarty/bb-osx), a fork that exists
to build the 1997 tree on modern Macs. Neither problem below is that
fork's headline "does it compile" question; both are the kind of thing
that makes a build fail before the compiler is ever reached.

### 4. The fork ships its maintainer's `config.cache`, pinning aalib to `/usr/local`

**Symptom:** `configure` failed with
`*** AALIB >= 1.4.0 not installed - please install first ***`, having
"found" aalib-config at `/usr/local/bin/aalib-config` — a path that did
not exist on the machine, on a machine where nothing had ever put one
there.

**Root cause:** `config.cache` is committed to the fork's git history
(`git show HEAD:config.cache` confirms it), carrying
`ac_cv_path_AALIB_CONFIG=/usr/local/bin/aalib-config` and
`LIBMIKMOD_CONFIG=no` from whatever machine last ran `configure` there.
autoconf 2.13 loads that file *before* probing anything, so every clone
inherits someone else's answers. On an Apple Silicon Mac the same trap is
waiting with different coordinates: Homebrew lives at `/opt/homebrew`, so
a correctly `brew install`ed aalib would still be "found" at the cached
`/usr/local` path and the build would fail exactly this way.

**Fix:** `bin/install-bb` deletes `config.cache` after the clone and
passes `--cache-file=/dev/null`, so every probe is answered by the machine
doing the building.

### 5. A git clone's arbitrary mtimes make automake try to regenerate a 1997 tree

**Symptom:** `make` immediately ran `aclocal`, then `automake`, then died:
`configure.in:7: error: required file './compile' not found`, from a
modern automake refusing the tree's two-argument `AM_INIT_AUTOMAKE`.

**Root cause:** git records no mtimes, so a fresh clone writes every file
with essentially arbitrary ordering relative to every other. The fork
ships all its generated autotools files (`aclocal.m4`, `configure`,
`Makefile.in`), but whenever `aclocal.m4` happens to land older than
`configure.in`, make's regeneration rules fire and hand a 1997 tree to a
2026 automake. On a typical Mac this fails even earlier and more
confusingly: nobody has autotools installed, so it's `aclocal: command not
found`.

**Fix:** `touch` the generated files in dependency order after the clone
(source first, each derived file after its input), so nothing looks stale,
plus `make ACLOCAL=: AUTOCONF=: AUTOMAKE=: AUTOHEADER=:` as a second line
of defence — nothing in this tree ever needs regenerating.

**Also, separately:** the link then failed on `sqrt` (`DSO missing from
command line`). bb never asks for libm, which was fine in 1997 and is
still fine on macOS, where libSystem carries the math functions; glibc
splits libm out. `LIBS=-lm` fixes it and is harmless on macOS, where `-lm`
is an empty stub kept for exactly this. Not listed as a numbered issue
because it's a platform difference rather than a defect, but it's the
third thing that had to be right before a binary appeared.

### 6. Clang 16 rejects autoconf 2.13's own "does this compiler work" test

**Symptom:** on a real Mac (Apple Silicon, Homebrew at `/opt/homebrew`),
`~/bin/install-bb --force` failed with `configure` reporting:

```
checking for gcc... gcc
checking whether the C compiler (gcc  ) works... no
configure: error: installation or configuration problem: C compiler cannot create executables.
```

**Root cause:** not a configuration problem at all — the compiler is fine.
autoconf 2.13's first check compiles this, verbatim, out of `configure`:

```c
main(){return(0);}
```

That's pre-ANSI C: `main` has no return type, so it defaults to `int`.
Clang 16 (shipped with Xcode 15) promoted `-Wimplicit-int` — along with
`-Wimplicit-function-declaration`, `-Wint-conversion` and
`-Wincompatible-function-pointer-types` — from warning to hard error. So
the check fails, and autoconf reports the only conclusion it has language
for: your compiler can't build programs. Every one of those four patterns
is ordinary 1997 C, and bb is ordinary 1997 C, so the same wall waits
further in even once configure is past. The fork's "builds on modern
Macs" claim was true when clang still defaulted the other way.

**Fix:** `bin/install-bb` passes
`-Wno-implicit-int -Wno-implicit-function-declaration -Wno-int-conversion
-Wno-incompatible-function-pointer-types` as `CFLAGS` to `configure` —
not to `make`, because the tree's `Makefile.am` is `CFLAGS=@CFLAGS@ ...`,
so whatever configure resolves is what the real compile uses. One place
covers both. The resolved `CFLAGS` is echoed into `build.log` so the next
failure of this shape is one `grep` away.

### 7. `regparm` is x86-32 only, and bb's macro guard predates any other architecture

**Symptom:** with the clang flags from issue #6 in place, `configure`
succeeded and `make` failed on the very first file, on an Apple Silicon
Mac:

```
./formulas.h:53:63: error: 'regparm' is not valid on this platform
./config.h:42:38: note: expanded from macro 'REGISTERS'
   42 | #define REGISTERS(n) __attribute__ ((regparm(n)))
```

**Root cause:** bb declares its hot function pointers `REGISTERS(3)`, and
`config.h` defines that as `__attribute__((regparm(n)))` behind
`#ifdef __GNUC__` — with no architecture condition at all, because in 1997
GCC *meant* x86. `regparm` is an x86-32 calling convention: x86-64 clang
ignores it with a warning (which is why the fork's Intel-era build was
fine), and arm64 clang rejects it outright.

**Fix:** `bin/install-bb` patches that one line to define `REGISTERS(n)`
as nothing. It's a micro-optimisation for passing arguments in registers
on 32-bit x86; the macro is the only place the attribute appears and every
declaration goes through it, so nothing ends up half-converted. The anchor
is checked before the `sed`, and a mismatch says so loudly rather than
silently no-op'ing — the failure it prevents is otherwise a mystifying
arm64 compile error two steps later.

Notably this was the *only* unguarded x86-ism in the tree: `minilzo.c`'s
inline asm and `ctrl87.c`'s x87 control-word code are both already
`#ifdef __i386__` and compile out by themselves.

**Second-order bug found while fixing it:** `install-bb` deletes one
tracked file (`config.cache`) and now patches another (`config.h`), which
makes `git pull --ff-only` refuse the moment upstream touches either —
turning a routine `--force` retry into a fetch failure. It now runs
`git checkout -- .` before pulling. Both edits are ours and are reapplied
immediately afterwards, so there is nothing to preserve.

### 8. aafire scrolling instead of burning is aalib falling back to its `stdout` driver

**Symptom:** `aafire` on the Mac scrolled the flames up the screen
continuously instead of animating in one place — reported as "vertical
sync isn't working", and initially suspected to be a tmux problem.

**Root cause:** aalib chooses an output driver at runtime, trying slang,
then curses, then `stdout`. The `stdout` driver does no in-place redraw
whatsoever: it prints each frame as plain lines, so the terminal scrolls.
Measured directly, the two modes are unmistakable — over three seconds of
`aafire` in the same terminal:

| driver | cursor-positioning escapes | newlines |
|--------|---------------------------:|---------:|
| a real driver (slang) | 455,808 | 32,669 |
| `stdout` | 0 | 1,160,978 |

So scrolling is not a sync or a tmux rendering issue; it is the signature
of a machine where aalib found no real terminal driver. Which drivers
exist is a build-time property, and Homebrew's aalib formula builds
`--without-x` and depends on neither s-lang nor ncurses. A driver can also
be compiled in but fail to initialise under tmux, where `TERM` may name a
terminfo entry the linked curses doesn't carry — which is the one way tmux
genuinely can be implicated.

**Fix:** `whimsy-splash` asks aalib for the best driver it actually has
(`aafire -help` lists them), passing `-driver slang`/`-driver curses` when
present and nothing when neither is. Requesting one is free: aalib falls
back on its own if it can't honour the request.

**Follow-up, from the same Mac:** the driver request changed nothing there
and `bb` scrolled the same way once it built — but with the detail that it
"displays nice" at a terminal height of about 30 rows. That detail is the
rest of the diagnosis. `aainfo -driver stdout` reports a fixed **80x25**
frame: the streaming driver cannot ask the terminal how big it is, so it
never adapts. In a taller window each 25-row frame stacks under the last
instead of replacing it and the animation crawls upward; at ~25-30 rows a
frame happens to fill the window and it looks stationary. Resizing the
terminal wasn't a workaround for a rendering bug — it was the user
manually matching the window to a hardcoded frame.

So `whimsy-splash` now does that matching itself: with no real driver
available it passes `-width`/`-height` taken from the actual terminal, and
each frame then replaces exactly one screenful at any window size.
Measured: a 45-row window renders 80-column frames by default and
100-column frames with the size passed. It is still the streaming driver
and still tears — the honest fix remains an aalib built against ncurses or
s-lang — but it plays where it's put.

The terminal size is read with `stty size < /dev/tty`, not `tput`: this
runs inside a command substitution, so `tput`'s own stdout is a pipe and
it answers from terminfo's static 80x24 rather than from the window.

### 9. Homebrew's aalib has no terminal driver at all, because a 1997 configure looks for headers where macOS no longer keeps them

**Symptom:** the machine's own answer, once asked directly:

```
$ aafire -help 2>&1 | grep -A1 'available drivers'
                  available drivers:stdout stderr
```

No curses, no slang — only the streaming driver. So issue #8's mitigation
(request the best driver) had nothing to request, and #8's follow-up
(match the frame to the window) was as far as it could go.

**Root cause:** aalib's configure hunts for curses by testing hardcoded
paths — `/usr/include/ncurses.h`, `/usr/include/ncurses/ncurses.h`, and so
on. macOS hasn't had a `/usr/include` since 10.14; its headers live inside
the SDK, reachable only via `xcrun --show-sdk-path`. Every test fails, the
driver is silently dropped, and the build succeeds — producing a working
library that can't redraw a screen. Homebrew's formula declares no ncurses
dependency and passes no override, so its bottle has this baked in on
every Mac.

**Fix:** `bin/install-aalib` builds aalib from the same 1.4rc5 tarball
Homebrew uses (checksum-verified), with Homebrew's own patch applied, plus
`--with-ncurses=<prefix>` — an option aalib has always had, which skips
the path hunt entirely and wires up `-I`/`-L` itself. The prefix is
Homebrew's ncurses when installed, else the SDK's. Result, measured on the
same terminal that had been streaming: `available drivers:linux slang
curses stdout stderr`, and 265,735 cursor-positioning escapes against 30
newlines — genuine in-place rendering at an arbitrary window size.

Two things had to be worked around inside that build:

- **`aacurses.c` reads `stdscr->_maxx` / `->_maxy` directly.** ncurses 6
  made `WINDOW` opaque, so it no longer compiles: *invalid use of
  incomplete typedef 'WINDOW'*. `-DNCURSES_OPAQUE=0` does not help — the
  generated `curses.h` defines that itself and its definition wins. The
  fix is `getmaxyx()`, the accessor ncurses provides for exactly this,
  which predates the code being patched and so works against macOS's own
  ncurses 5.7 as well.
- **The same clang-16 strictness as issue #6**, for the same reason: it is
  the same vintage of C.

**And then bb needed rebuilding.** bb renders through whatever aalib it
was *linked* against, so a bb built earlier kept its driver-less one no
matter how many drivers the new aalib had. `install-bb` now records which
aalib it built against and rebuilds when that changes, and `run.sh` builds
aalib first so a single pass is enough.

### 10. A dialog menu two rows too short silently drops its last entry

**Symptom:** reported as `tty-clock` having been left out of the splash
menu and the random rotation — twice, because it looked that way. It had
been in the catalogue since it was added, and both the menu and the random
pick read that same catalogue.

**Root cause:** `whimsy-menu` sizes its dialog box as
`list_height + <chrome>`, capped to the terminal. The chrome allowance was
7 rows, estimated. It is 9 — borders, title, prompt, the blank rows around
the list, and the button row. Two rows short, and dialog doesn't complain
or refuse to draw; it silently scrolls the list, showing 12 of 13 entries.
The one it drops is the last, which is whatever splash was added most
recently. Measured directly at 80x24: box 20 renders 12 rows, box 22
renders 13.

The two-line prompt was the other half. It cost two rows of list on every
terminal, and shortening it to one line fits the whole catalogue even at
the old box height (measured: box 20 + one-line prompt = 13/13).

**Fix:** chrome allowance corrected to a measured 9, and the prompt cut to
one line. Verified by capturing the rendered pane at 24 and 30 rows and
listing the entries actually drawn — all thirteen, `ttyclock` included.

**Worth noting about the earlier fix:** moving `random` to the top of the
list, done when this sizing was first written, was a response to the same
bug seen from the other end — an entry falling off the bottom. It made
`random` safe and left the bug in place for whatever entry inherited last
position. A symptom moved is not a bug fixed.

### General lesson

**A third-party fork's committed build artifacts are inputs to your build,
not neutral files.** Issues #4 and #5 came from the same root: state that
belongs to one machine (`config.cache`) or one moment (mtimes) being
carried in git and silently believed by the build system. The tell in both
cases was a failure that pointed at the *local* machine — "aalib not
installed" when it was, "compile not found" when nothing should have been
compiling autotools input — while the actual cause was committed history.
Worth remembering the next time this repo builds anything from a fork:
check what the fork commits, not just what it changed.

**"Builds on modern X" has a date on it — and an architecture.** Issues #6
and #7 are the same claim going stale twice over, once against a newer
compiler and once against a different CPU: the fork really did build on the
Macs of its day, and nothing about it changed — the toolchain moved. A
fork maintained to solve exactly your problem is still a snapshot of when
someone last cared, so the interesting question isn't whether it claims to
work but what has changed underneath it since. Here it was one clang
release turning four warnings into errors, and then the Apple Silicon
transition making an x86-only attribute fatal.

**Ask the machine, don't infer it.** Issue #8's diagnosis was reasoned out
correctly from measurements taken elsewhere, and the fix it produced was
the right fix for what was known — but three rounds went by before anyone
ran `aafire -help` on the actual Mac, and that one line was what turned
"aalib probably has no real driver" into "aalib has no real driver, here
is why, and here is the flag that fixes it". A one-command question
answered in seconds what careful inference could only narrow down.

**"It was never added" and "it's there but you can't see it" look
identical from the outside.** Issue #10 was reported as a missing feature,
twice, and the code plainly contained it — the temptation was to answer
"it's already there" and move on, which would have been true and useless.
The reporter is describing what they see; when that contradicts what the
code says, something between the two is eating it.

**A symptom that looks like a rendering bug can be a capability that was
never compiled in.** Issue #8 presented as "vertical sync isn't working"
and looked like a terminal or tmux problem; it was aalib quietly
substituting a driver that cannot redraw at all. When something animated
looks wrong rather than broken, ask what the program fell back *to* — and
prefer measuring the output stream over squinting at it, since one
`grep -c` of the escape sequences settled in seconds what watching flames
could not.

## Related Commits

All of the following were merged directly to `master` by the user (local
`git merge`/fast-forward, not a GitHub PR — no PR number exists for any of
this environment's history):

- `8818c24` — `Merge branch 'claude/mac-terminal-setup'`: the initial
  environment (issues #2 and #3 above; issue #1's guard was already part
  of this same commit)
- `7e0e207` — `mac-terminal-setup: confirm before applying the whimsy
  toggle`
- `14d8f4e` — `mac-terminal-setup: document sources for each whimsy piece`
