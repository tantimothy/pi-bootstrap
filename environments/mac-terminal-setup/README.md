# Mac Terminal Setup — Personal Mac Terminal Bootstrap

Deploys this Mac's terminal setup — a colored, git-aware bash prompt, tmux
auto-attach on login, fastfetch system info, and (optionally) a set of
whimsical login extras — to any Mac. It's the macOS/Homebrew counterpart to
`pi-barebones` (which does the same job for a fresh Raspberry Pi OS install):
installs packages from `packages.txt`/`packages-whimsy.txt`, drops
`.tmux.conf`/`.bash_profile` into your home directory, and injects
marker-delimited `.bashrc` blocks.

This is not a Docker environment — it runs directly on the host and has no
containers.

---

## ⚙️ Why This Needs a Custom `run.sh`

Same reasoning as `pi-barebones`: `deploy.sh`'s generic fallback only knows
how to build/run a Docker image or `docker compose up` a stack. This
environment has neither — everything it does is host-level dotfile/package
management:

- **`brew install`** of packages listed in `packages.txt` (always) and
  `packages-whimsy.txt` (only if whimsy extras are enabled) — direct host
  package management, not a container image build.
- **Idempotent `.bashrc` injection** — four independently-positioned
  marker-delimited blocks (prompt, tmux, fastfetch, whimsy), always
  reassembled in that order on every run.
- **Backing up and overwriting real dotfiles** in `$HOME`
  (`.bash_profile`, `.tmux.conf`, and — only for whimsy — a handful of
  scripts under `~/bin`). No Docker archetype has any notion of "edit the
  host user's shell rc files."

---

## What It Does

1. **Installs Homebrew** if missing (asks first).
2. **Asks once** whether to include whimsical login extras (fortune,
   cowsay, BOFH excuses, calendar, weather) — the answer is written to
   `.env` and remembered on future runs. Skip the prompt by pre-setting
   `WHIMSY_ENABLED=true`/`false` in `.env` yourself (see `.env.example`).
3. **Installs packages** — always `packages.txt` (`tmux`, `fastfetch`);
   additionally `packages-whimsy.txt` (`cbonsai`, `cmatrix`, `asciiquarium`,
   `cowsay`, `fortune`, `lolcat`, `genact`, `no-more-secrets`, `sl`,
   `tty-clock`, `aalib`, `dialog`, plus `figlet`/`pv`/`htop` for
   hollywood's panes) and the `Acme::Scurvy::Whoreson::BilgeRat` CPAN
   module if whimsy is enabled.
4. **Notes whether MacPorts is installed** — no automated installer exists
   for it (unlike Homebrew's one-liner), so this is informational only; the
   MacPorts `PATH` lines in `.bash_profile` are harmless no-ops without it.
5. **Deploys `.tmux.conf` and `.bash_profile`**, and — only if whimsy is
   enabled — the bundled `~/bin` scripts (including `whimsy-splash` and the
   `whimsy-menu` picker), calendar data, TalkingMoose phrase files, and
   hollywood (the last two fetched from GitHub here, once, rather than on
   every shell) — then builds `bb`, the one splash nothing packages for
   macOS.
6. **Injects four `.bashrc` blocks**, always reassembled in this order:
   `prompt` → `tmux` → `fastfetch` → `whimsy` (only if enabled). The whole
   injected region is guarded behind `[[ $- == *i* ]] || return`, so
   non-interactive shells (scripts, `ssh host command`, this repo's own
   tooling) are unaffected.

Every step that would overwrite an existing file backs it up first — see
**Backups** below.

---

## 🗄️ Backups

Before overwriting anything already at its destination, `run.sh` copies the
existing version into a fresh, timestamped directory:

```
~/.pi-bootstrap-backups/mac-terminal-setup-<YYYYMMDD-HHMMSS>/
```

This covers `~/.bash_profile`, `~/.bashrc` (snapshotted whole before any
block injection touches it), `~/.tmux.conf`, and — when whimsy assets are
deployed — everything under `~/bin` that gets replaced. Files that don't
already exist, or that are byte-identical to what's about to be deployed,
aren't backed up (nothing changed). `run.sh` prints the backup directory
path at the end if it wrote anything.

To restore: copy the file(s) you want back out of the relevant
`~/.pi-bootstrap-backups/mac-terminal-setup-*/` directory.

---

## 🎭 Whimsical Login Extras

Off by default. When enabled, a new interactive shell runs — strictly
*after* tmux and fastfetch — one randomly-picked splash (see the table
below), then `fortune`, a BOFH excuse, a couple of network-sourced
insults, today's entries from a bundled calendar-facts database, and the
weather via `wttr.in`. The splashes that print rather than take over the
screen pause on "Press any key to continue..." before the rest runs —
without it the whole unpaused sequence below would scroll straight past
the splash to the prompt before you could read it.

### The Splashes

| id | What it is | Ends when |
|----|------------|-----------|
| `bonsai` | [cbonsai](https://gitlab.com/jallbrit/cbonsai) grows a tree, branch by branch | any key |
| `matrix` | [cmatrix](https://github.com/abishekvashok/cmatrix) rain, screensaver mode | any key |
| `aquarium` | [asciiquarium](https://github.com/cmatsuoka/asciiquarium) | `q` |
| `cowsay` | A `fortune` from a randomly-picked cow, through `lolcat` | prints once |
| `moose` | A random Talking Moose phrase, via `cowsay -f moose` | prints once |
| `hollywood` | [hollywood](https://github.com/dustinkirkland/hollywood) — split panes of logs, hex dumps, gauges and traffic | Ctrl-C |
| `genact` | [genact](https://github.com/svenstaro/genact) — plausible-looking installs, builds and downloads | Ctrl-C |
| `nms` | A `fortune` "decrypted" the way [Sneakers (1992)](https://github.com/bartobri/no-more-secrets) did it | plays once |
| `aafire` | [AA-lib](https://aa-project.sourceforge.net/aalib/)'s `aafire` — flames burn up the terminal | any key |
| `bb` | [BB](https://aa-project.sourceforge.net/bb/), AA-lib's own audio-visual demo | Ctrl-C (or its own ending, minutes later) |
| `sl` | [sl](https://github.com/mtoyoda/sl) — a steam locomotive, in one of five random variants | runs once, ~5s |
| `ttyclock` | [tty-clock](https://github.com/xorg62/tty-clock) in screensaver mode, centred and coloured | any key |
| `naas` | [No as a Service](https://github.com/hotheadhacker/no-as-a-service) — a fetched, professionally-worded refusal, in large red letters | prints once |

The catalogue lives in `bin/whimsy-splash` — one file, used both by the
random login pick and by the menu below, so the two can't drift apart. A
splash whose tools aren't installed is skipped by the random pick rather
than flashing an empty screen with a "command not found".

**Two of them are menu-only.** `bb` and `cacademo` are offered by
`whimsy-menu` (marked `[menu]` there) and run when named, but the random
login pick never chooses them — they're worth watching deliberately rather
than being handed unprompted, `bb` because its demo runs for minutes and
`cacademo` because it's the one to show someone. The list of them lives in
`whimsy-splash` too, and the menu asks for it with `--menu-only`.

### If `aafire` or `bb` scrolls instead of animating in place

aalib picks its output driver at runtime — slang, then curses, then
`stdout` — and the `stdout` driver does no in-place redraw at all: it
prints each frame as plain lines, in a fixed 80x25 frame it can't resize.
That's why an aafire in a tall window crawls up the screen, and why
shrinking the terminal to about 30 rows appears to fix it.

**Homebrew's aalib has no other driver.** Its 1997 configure looks for
curses in hardcoded paths like `/usr/include/ncurses.h`, and macOS hasn't
had a `/usr/include` since 10.14 — headers moved into the SDK. Every test
fails, the driver is dropped, and the build still succeeds. Check yours:

```bash
aafire -help 2>&1 | grep -A1 'available drivers'
```

`run.sh` handles this by building a better one: **`bin/install-aalib`**
compiles the same 1.4rc5 release Homebrew packages (checksum-verified,
with Homebrew's own patch), adding `--with-ncurses=<prefix>` — an aalib
option that skips the path hunt and wires up the include and library paths
directly. Everything lands in `~/bin/aalib.d`, nothing system-wide, and
`whimsy-splash` prefers that `aafire` when it exists. It's skipped
entirely on a machine whose aalib already has a real driver.

`bb` renders through aalib too, but through the copy it was *linked*
against — so `install-bb` records which aalib that was and rebuilds when
it changes, and `run.sh` builds aalib first so one pass is enough.

Where no better aalib can be built, `whimsy-splash` falls back to passing
the terminal's real size, so the streaming driver at least fills the
window at any size instead of only at 25 rows. It still tears; that part
is inherent.

Retry the build by hand any time:

```bash
~/bin/install-aalib --force
```

`hollywood` and `genact` only ever end on Ctrl-C, and `bb`'s demo runs for
minutes — fine when you launched one deliberately, unhelpful when a new
terminal tab did. So on login, and only on login, those three get a time
limit: 30 seconds by default, `export WHIMSY_SPLASH_SECONDS=60` to change
it, `0` to remove it. `sl` is left alone; it ignores Ctrl-C by design and
leaves on its own after about five seconds.

### Launching One Yourself

```bash
~/bin/whimsy-menu             # pick from a TUI (dialog, same as deploy.sh)
~/bin/whimsy-splash hollywood # or go straight to one
~/bin/whimsy-splash --list    # what the ids are
~/bin/whimsy-splash --help
```

`deploy.sh` reaches the same picker through this environment's **"Launch a
whimsy splash..."** action. The menu lists every splash, marks the ones whose
tools are missing as `[not installed]`, and runs each with the screen to
itself — no time limit, since you asked for it.

### About hollywood on macOS

`hollywood` is the one splash with no Homebrew formula — upstream ships it
as a Debian package — so `run.sh` fetches it into `~/bin/hollywood.d/`
instead, the same way the Talking Moose phrases are fetched. It draws its
panes by running small "widget" scripts out of its own widget directory,
and only the ones that work on macOS are fetched: of upstream's twenty,
seven need `ccze` (unmaintained, no formula) and most of the rest need a
Linux-only tool or `/proc`, `/sys`, `/var/log/*.log`. A widget whose
dependency is missing exits immediately and takes its pane with it, so the
directory is curated rather than mirrored.

Covering what the skipped widgets would have shown, this repo ships three
of its own (`bin/hollywood-widgets/`, deployed alongside the fetched ones):

| Widget | Shows |
|--------|-------|
| `mac-logs` | `log stream` — this Mac's real unified system log |
| `mac-hexdump` | Hex dumps of random binaries out of `/usr/bin` |
| `mac-netstat` | `netstat -w 1` — live interface throughput |

Together with upstream's `cmatrix`, `figlet`, `htop` and `pv` widgets
that's seven panes' worth, which is about what hollywood asks for.

> **Not yet seen on a real Mac.** hollywood, `genact`, `nms`, `aafire`,
> `bb`, `sl` and `tty-clock` were added and their plumbing tested on Linux;
> no `brew install` of the new formulas and no hollywood pane has run on
> macOS itself. What's still worth confirming, and how, is in
> `docs/future-enhancements/mac-terminal-setup.md` #4.

### About libcaca on macOS

`libcaca` has no Homebrew formula, so `bin/install-libcaca` compiles
`cacafire` and `cacademo` into `~/bin/libcaca.d` — same shape as the aalib
and bb builds, and against Homebrew's ncurses for the same terminfo reason.
Two upstream quirks it works around:

- **Two of the tools in that release don't link.** `cacaview` and `img2txt`
  reference `_caca_alloc2d`, which the shared library doesn't export. A
  plain `make` fails on them and takes everything with it, so the build
  makes the library, installs it, then builds only the two demos wanted.
- **Everything optional is disabled** — x11, gl, imlib2, docs, and the
  Python/Ruby/Java/C#/C++ bindings. None of it matters to two terminal
  demos, and each is a dependency that can fail to resolve on a machine
  this has never run on.

```bash
~/bin/install-libcaca --force
```

### About bb on macOS

`bb` is the one splash with no package at all — not in homebrew-core, not
in MacPorts (both checked). `run.sh` therefore *compiles* it, via
`bin/install-bb`, from [artyfarty/bb-osx](https://github.com/artyfarty/bb-osx),
a fork of the 1997 AA-project tarball that exists specifically to build on
modern Macs. Everything lands under `~/bin/bb.d` with `--prefix`, so no
sudo and nothing in `/usr/local`.

That build needs four workarounds, all in `install-bb` and all written up
in `docs/lessons-learned/mac-terminal-setup.md`:

1. The fork ships a committed `config.cache` pinning aalib to
   `/usr/local` — wrong on Apple Silicon.
2. A clone's arbitrary mtimes make automake try to regenerate a 1997 tree.
3. Clang 16 rejects autoconf 2.13's own compiler test:
   `main(){return(0);}` is implicit-`int`, an error since Xcode 15.
4. bb declares functions `__attribute__((regparm(n)))`, an x86-32 calling
   convention that arm64 clang rejects outright. Patched out — it is a
   micro-optimisation, and the macro it lives in is the only place the
   attribute appears.

The first three are confirmed against a real Mac; the fourth is the error
that machine hit next, fixed but not yet re-run there.

It's called with `|| true` so it can never fail a deploy, records its
output in `~/bin/bb.d/build.log`, and marks `.build-failed` so it isn't
retried on every subsequent `run.sh`. When it fails, `bb` simply shows as
`[not installed]` in the menu and never comes up in the random rotation.
To retry after fixing something:

```bash
~/bin/install-bb --force
```

**Toggling it:**
- Re-run `./run.sh` and answer differently — but it only asks once, so:
- Use the **"Toggle whimsical login extras"** action in `./deploy.sh`'s
  menu for this environment, or
- Hand-edit `WHIMSY_ENABLED` in `environments/mac-terminal-setup/.env`
  and re-run `./run.sh`.

Turning it off removes the `WHIMSY` block from `~/.bashrc` (so nothing runs)
but deliberately leaves the already-copied `~/bin` scripts in place —
they're inert once nothing calls them, and re-enabling later is instant.

### Sources

Where each whimsy piece comes from:

- **Splash animations** — [cbonsai](https://gitlab.com/jallbrit/cbonsai),
  [cmatrix](https://github.com/abishekvashok/cmatrix),
  [asciiquarium](https://github.com/cmatsuoka/asciiquarium), the
  [cowsay](https://github.com/cowsay-org/cowsay) +
  [fortune-mod](https://github.com/shlomif/fortune-mod) +
  [lolcat](https://github.com/busyloop/lolcat) combo, and a random "PAUSE"
  activity phrase from Uli Kusterer's
  [TalkingMoose](https://github.com/uliwitness/talkingmoose), piped
  through `cowsay -f moose`. Like the calendar facts below, the phrase
  files are fetched once by `./run.sh` into `~/bin/moose-phrases/` rather
  than hit live on every new shell.
- **Hollywood hacker screen** — Dustin Kirkland's
  [hollywood](https://github.com/dustinkirkland/hollywood) (Apache-2.0),
  fetched by `./run.sh` into `~/bin/hollywood.d/` along with the four of
  its widgets that run on macOS.
- **Fake activity** — [genact](https://github.com/svenstaro/genact).
- **Burning terminal / BB demo** — Jan Hubicka's
  [AA-lib](https://aa-project.sourceforge.net/aalib/) (`aafire`) and
  [BB](https://aa-project.sourceforge.net/bb/), the latter built from
  [artyfarty/bb-osx](https://github.com/artyfarty/bb-osx)'s
  modern-macOS fork.
- **Steam locomotive** — Toyoda Masashi's [sl](https://github.com/mtoyoda/sl).
- **Digital clock** — [tty-clock](https://github.com/xorg62/tty-clock).
- **Lava lamp** — [lavat](https://github.com/AngelJumbo/lavat).
- **Nyan Cat** — [nyancat](https://github.com/klange/nyancat).
- **Colour demos** — [libcaca](https://github.com/cacalabs/libcaca)'s
  `cacafire` and `cacademo`, by the same authors as AA-lib and its
  successor in every way that matters here: colour, and drivers that work.
  No Homebrew formula, so `bin/install-libcaca` builds the two demos from
  the upstream release (checksum-verified). It builds only those two
  deliberately — `cacaview` and `img2txt` don't link in that release
  (`undefined reference to _caca_alloc2d`), and a plain `make` takes the
  whole build down with them.
- **Refusals** — [no-as-a-service](https://github.com/hotheadhacker/no-as-a-service),
  the API behind [noasaservice.lol](https://noasaservice.lol). The splash
  talks to the project's own endpoint rather than the website: the site is a
  single-page app and answers `/no` with its own HTML, which is not a
  rejection reason however convincingly it arrives with a 200. If it turns
  out to expose an API of its own, point `WHIMSY_NO_URL` at that — the
  response handling takes `{"reason": ...}` JSON or plain text from
  anywhere, and rejects anything that looks like a web page.

  This is the only splash that talks to the network *while it runs* — the
  calendar and Talking Moose data are both fetched once, at deploy time. It
  asks for one line per launch against a service that allows 120 requests a
  minute per IP, and prints its own refusal when it can't reach anything.
- **Sneakers decryption effect** — Brian Barto's
  [no-more-secrets](https://github.com/bartobri/no-more-secrets) (`nms`).
- **BOFH excuse** (`bin/bofhexcuse`) — Jeff Ballard's
  [BOFH-style Excuse Server](https://pages.cs.wisc.edu/~ballard/bofh/).
- **Programming Excuse** — [programmingexcuses.com](http://programmingexcuses.com).
- **Classic Tech/IRC Insult** — Simon Whiting's insult CGI at
  [sweh.spuddy.org](https://sweh.spuddy.org)
  ([insult.cgi](https://sweh.spuddy.org/Jokes/insult/insult.cgi) directly).
- **Shakespearean Epithet** (`bin/insulthost.pl`) — the `insultserver`
  backend of
  [Acme::Scurvy::Whoreson::BilgeRat](https://metacpan.org/pod/Acme::Scurvy::Whoreson::BilgeRat)
  on CPAN:
  [Acme::Scurvy::Whoreson::BilgeRat::Backend::insultserver](https://metacpan.org/pod/Acme::Scurvy::Whoreson::BilgeRat::Backend::insultserver).
- **Piratical Insult** (`bin/piratehost.pl`) — the same
  [Acme::Scurvy::Whoreson::BilgeRat](https://metacpan.org/pod/Acme::Scurvy::Whoreson::BilgeRat)
  module's `pirate` language, in the spirit of
  [Talk Like a Pirate Day](https://talklikeapiratecom.wpcomstaging.com).
- **Calendar facts** (`bin/calendars/`) — FreeBSD's
  [calendar-data](https://github.com/freebsd/calendar-data) files (see
  `bin/calendars/LICENSE`).
- **Weather** — [wttr.in](https://github.com/chubin/wttr.in).

---

## Customising the Package List

Edit `packages.txt` (always installed) or `packages-whimsy.txt` (whimsy
only). One Homebrew formula per line, comments with `#`. Run `./run.sh`
again after editing — `brew install` is idempotent so already-installed
formulas are skipped.

---

## Deployment

```bash
chmod +x run.sh
./run.sh
```

Then open a new terminal tab (or `source ~/.bash_profile`) to see the
changes take effect.

---

## 🎛️ Deployment Policies

Like `pi-barebones`, `run.sh` never branches on `$REBUILD_POLICY` — it
always runs the same idempotent setup. `deploy.sh`'s policy menu detects
this (a `run.sh` with zero `POLICY` references, paired with `info.yaml`
declaring no `data_dirs`/`named_volumes`) and only presents the policies
that actually do something:

| Policy | Action |
|--------|--------|
| `FAST` | Install missing packages and update dotfiles/`.bashrc` blocks — safe to re-run any time |
| `INFO` | No persistent data directories — shows useful commands |

Plus the two custom actions described above (launch a splash, toggle whimsy).

---

## 💡 Useful Commands

```bash
# Re-run setup after editing packages.txt / packages-whimsy.txt
./run.sh

# Attach to the tmux session
tmux attach

# View current .bashrc injected blocks
grep -A3 'MAC TERMINAL PROMPT START' ~/.bashrc
grep -A3 'MAC TERMINAL WHIMSY START' ~/.bashrc

# Current whimsy on/off setting
cat environments/mac-terminal-setup/.env

# Pick and launch a splash yourself
~/bin/whimsy-menu
~/bin/whimsy-splash --list

# Most recent backups from this environment
ls -t ~/.pi-bootstrap-backups/ | head
```
