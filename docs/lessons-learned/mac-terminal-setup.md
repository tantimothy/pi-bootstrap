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
