# dragonos-sdr — Lessons Learned

## Session: image build failed outright on two apt packages that don't exist in Debian

**Status:** Fixed and confirmed — the image builds on a real Pi and the
launcher menu comes up. The individual menu entries still have not been run
against a dongle; see *Still unverified* below.

**Summary:** `REBUILD_POLICY=FAST` on a fresh host got as far as
`[COMPILE] Target image layer missing. Launching standard dependency-cached
ARM build...` and then died in the first `RUN` layer. Two of the ~30 package
names in the Dockerfile's `apt-get install` — `readsb` and `acarsdec` — are
not in the Debian bookworm archive at all. Fixing that then exposed three
runtime bugs in the menu entries for those same tools, none of which had ever
been reachable, since the image had never built.

**Symptom:**

```
E: Unable to locate package readsb
E: Unable to locate package acarsdec
ERROR: process "/bin/sh -c apt-get update && apt-get install -y ..." did not
complete successfully: exit code: 100
❌ ERROR: Deployment task failed for [dragonos-sdr].
```

**Root cause:** Both tools are widely used on Raspberry Pi ADS-B/ACARS
receivers, but neither is packaged by Debian — everyone installs them from
source (or from a third-party ADS-B repo). `dump1090-mutability`, sitting two
lines above `readsb` in the same list, *is* in bookworm, which is likely how
the assumption slipped in.

**Fix:** Dropped both names from the `apt-get install` list and added three
pinned from-source build layers to the Dockerfile — `wiedehopf/readsb`
(`v3.16.16`, `make RTLSDR=yes`), `szpajder/libacars` (`v2.2.1`), and
`TLeconte/acarsdec` (pinned to the final upstream commit
`339f63eb91a890cfe5b199ad70814cfe86702d1e`, because its newest *tag* predates
the CMake build system it now uses). Each ref is a build `ARG`, so it can be
overridden with `--build-arg` without editing the Dockerfile; each source tree
is deleted in the same layer it is built in. The five extra `-dev` packages
those builds need (`libusb-1.0-0-dev`, `libncurses-dev`, `zlib1g-dev`,
`libzstd-dev`, `libxml2-dev`) joined the apt list.

**Three follow-on bugs found while wiring the menu up to the real binaries:**

- **`readsb` with no `--device-type` never opens the dongle.** Menu entry C ran
  `readsb --net --interactive`. readsb deliberately ships *no* default SDR —
  `sdr.c` has the "default to the first available handler" line commented out
  with `// rather don't have a default SDR ....`, leaving `Modes.sdr_type` at
  `SDR_NONE`. That is not an error: readsb starts, prints its banner, shows an
  empty aircraft table, and waits forever. Now passes `--device-type rtlsdr`.
- **readsb has no web server.** The menu label and README both advertised a
  "web map (port 8080)" for it. That is dump1090's HTTP server; readsb only
  writes JSON for an external map (tar1090) to serve. Relabelled to what it
  actually offers: the interactive table plus Beast/SBS/raw network output.
- **The ACARS frequency list was out of range.** Menu entry G scanned
  `129.125 130.025 130.450 131.550`. acarsdec covers every frequency given from
  one tuned RTL-SDR, so they must all fit inside a single sample-rate-wide
  window — 1.95 MHz at its default 2 MS/s (`rtl.c`'s `chooseFc()` tests the
  span against the sample rate minus a 50 kHz guard). That list spans
  2.425 MHz, so acarsdec would have exited immediately with `Frequencies too
  far apart`. Replaced with the four common North American channels
  (`130.025 130.450 131.125 131.550`, 1.525 MHz).

Also made menu entry B resolve `dump1090-mutability` before `dump1090`:
Debian's packaging (`debian/rules`) installs the binary under the fork's full
name so the forks can coexist, and nothing guarantees a plain `dump1090`
alias exists.

**Confirmed since:** a real deploy on the Pi built the image through all three
new compile layers and brought the launcher up, so readsb, libacars and
acarsdec do compile on ARM64 against bookworm's toolchain at the pinned refs.

**Still unverified:** the four runtime fixes. Every claim about them was
checked against upstream's actual `Makefile`, `CMakeLists.txt`, `sdr.c`,
`help.h` and `rtl.c` at the pinned refs, but no menu entry has yet been run
with a dongle attached.

### General Lessons

- **A missing apt package is a build-stopper, not a degraded install.** `apt-get
  install` reports *every* unresolvable name at once and then exits 100, so one
  wrong name in a 30-package list costs the entire image — including all 20-odd
  packages that were fine. When adding a tool to a Dockerfile, confirm it is in
  *that base image's* archive rather than assuming that "everyone on a Pi runs
  it" means "Debian ships it". The ADS-B/SDR ecosystem is full of tools that
  are only ever installed from source.
- **An environment that has never built has never had its runtime code run
  either.** Three separate menu bugs — a missing required flag, a feature that
  does not exist, and an out-of-range parameter list — sat behind a build
  failure. When fixing a build so something runs for the first time, read the
  code that is about to run for the first time too; getting `docker build` to
  exit 0 is not the deliverable.
- **Pin what you clone.** Following the same rule
  `docs/lessons-learned/nanoclaw-mnemon.md` records for patched third-party
  source: an unpinned `git clone` in a Dockerfile means two builds of the same
  commit of this repo can quietly produce different images, with no lockfile
  anywhere to notice. Where upstream's tags are unusable (acarsdec's newest tag
  predates its current build system), pin the commit and say in a comment why
  it isn't a tag.

## Session: one dongle's worth of assumptions in a two-dongle setup

**Status:** Fixed (code); the picker's own logic is unit-tested against a
stubbed `rtl_test`, but has not been run against real hardware.

**Summary:** Every RTL-SDR tool in the launcher was invoked with no device
argument at all, which means each one silently opened "device 0". That is fine
with a single dongle attached and quietly wrong with two, because USB
enumeration order is not stable across a reboot or a replug — and the two
dongles commonly paired here are not interchangeable. A FlightAware Pro Stick
Plus has a 1090 MHz SAW filter ahead of its tuner, so if it lands on index 0
the ACARS (G), APRS (F), rtl_433 (D) and pager (E) entries are pointed at
hardware that physically cannot hear those bands, with no error — just a
decoder that never decodes anything.

**Fix:** The dongle is now chosen once per menu session and passed explicitly
to all ten entries that open a radio (4-7, B-G). Selection is lazy — it happens
on the first entry that actually needs a radio, not at startup, since the info,
lsusb and shell entries need none and GQRX/GNU Radio do their own. With one
dongle attached it is selected silently; with several, a `dialog` picker
appears; menu tag **H** re-opens that picker on demand. The choice lives in
shell variables only, so swapping dongles needs a new session, never a rebuild.

**Three things that made this less trivial than it looks:**

- **Enumerating dongles without opening one.** `rtl_test` with no `-d` opens
  device 0 and starts sampling it, which fails outright whenever another tool
  already holds the dongle — no good for a picker that may run while something
  is streaming. librtlsdr's `verbose_device_search()` prints the complete
  device list *before* it tries to match its argument and returns -1 (so
  `rtl_test` exits before `rtlsdr_open()`) when nothing matches, so passing a
  string that cannot match any index, serial or name gets the listing with
  nothing opened. Confirmed in `convenience.c` and `rtl_test.c`, not assumed.
- **Every tool spells device selection differently.** `rtl_*`, readsb and
  acarsdec all take an index *or* a serial; `rtl_433` needs a serial prefixed
  with a colon (`-d :ADSB`) to distinguish it from an index;
  `dump1090-mutability` only understands `--device-index` and has no serial
  option at all; and readsb's `--device` must appear *after* `--device-type
  rtlsdr`, because it parses SDR-specific options against whichever type was
  named before them. Each of these was read out of the tool's own source or
  help table rather than guessed.
- **Serials are not reliably unique.** Addressing by serial is preferable —
  it survives an unplug/replug where an index does not — but both an RTL-SDR
  Blog V3 and a FlightAware Pro Stick ship as `00000001`, so with two
  unprogrammed dongles attached a serial match resolves to whichever
  enumerated first, which is exactly the ambiguity the picker exists to remove.
  The picker detects a duplicated or blank serial among the attached devices
  and falls back to the index for that session. (`rtl_eeprom -d 0 -s ADSB`,
  once per dongle on the host, fixes it permanently.)

**Testing:** the picker's logic was exercised against a stub `rtl_test`
reproducing librtlsdr's exact output format, plus a stub `dialog`, covering:
zero devices, one device (silent auto-select), several devices, a cancelled
picker, a cancelled *re-*pick (previous selection must survive), a forced
re-pick with only one dongle, duplicate serials falling back to the index, and
a dongle unplugged mid-session. All pass. What that does **not** cover is the
real thing: whether each tool actually accepts the argument built for it.

### General Lessons

- **"It works with one" is not the same as "it works."** Every tool here
  defaulted to device 0 and every one of them appeared correct, because there
  was only ever one dongle plugged in while the menu was written. The failure
  mode a second dongle introduces is not an error message — it is a decoder
  pointed at hardware that cannot hear the band, producing silence that looks
  exactly like a quiet frequency or a bad antenna.
- **Read each tool's own option table before assuming a common convention.**
  Four tools in one menu, four different spellings of "use this dongle", one of
  which (readsb's `--device`) is order-dependent relative to another flag. A
  plausible-looking uniform `-d "$dev"` across all of them would have been
  wrong in three places, and wrong silently in at least one.
- **A stub is enough to test the parts that are yours.** The picker's
  enumeration, counting, serial extraction, duplicate-serial fallback and
  cancel paths are all just shell, and a fake `rtl_test` reproducing
  librtlsdr's exact output format exercises every one of them without
  hardware. That does not verify the tools accept what is built for them —
  but it does mean the half of the change that is this repo's own logic is not
  riding on a live deploy to find a typo.

## Session: first real run of the menu — six wrong invocations in a row

**Status:** Fixed. Found by running the menu entries one at a time against a
real RTL-SDR (an RTL2838UHIDIR with an R820T tuner) on the Pi. `lsusb` (J) and
the device enumeration behind the picker worked first time; almost nothing else
did.

**Summary:** With the image finally building, every menu entry got its first
execution ever — and six of them were wrong. Not subtly: wrong flag names,
flags the local build does not implement, a value silently parsed as something
2000x off, and an argument that does not exist. Each had looked plausible, and
each had survived review precisely because nothing had ever run it.

| Tag | Symptom | Root cause |
|-----|---------|------------|
| 2, 3 | Error "flashes by too fast to be read", menu reappears | GQRX/GNU Radio Companion were the only entries with no pause before returning; the loop's own `clear` wiped the reason off the screen |
| 4 | `No E4000 tuner found, aborting.` | `rtl_test -t` is *specifically* the Elonics E4000 tuner benchmark. On an R820T it aborts by design. The dongle was fine the whole time |
| A | (unreached — no HackRF on hand) | `hackrf_transfer` parses `-f`/`-s` with `strtod()`, which stops at the first non-digit rather than erroring: the entry's own `433.92M` prompt would have tuned it to **433 Hz**, and `2M` would have set a 2 sample/sec rate, silently |
| B | `--net-http-port not supported in this build` + `Unknown or not enough arguments for option '--net-beast-output-port'` | Debian compiles `dump1090-mutability` without `ENABLE_WEBSERVER`, and the Beast output flag is `--net-bo-port`. `--net-beast-output-port` does not exist in any build |
| E | `invalid mode "ALL"` then usage, exit | multimon-ng has no `ALL` demodulator. Demodulators are added one `-a` at a time from the list it prints |
| I | `No devices found!` with a working dongle attached | SoapySDR is only an abstraction layer; `soapysdr-tools` ships no hardware modules, and none were installed |

**Fixes:** tags 2 and 3 keep their output and dump the X11 state that decides
whether a containerised X client can reach the host's server; tag 4 became a
submenu offering the two tests that *do* apply to these tuners (default
sample-loss check, and `-p` PPM measurement); tag A prompts in MHz and converts
to Hz itself; tag B drops both bad flags, since plain `--net` already opens
every port on its default number; tag E names its six demodulators explicitly;
and the image now installs SoapySDR's RTL-SDR and HackRF modules.

`run.sh` also now mounts the host's X11 authority file to `/root/.Xauthority`
and sets `XAUTHORITY` — mounting the display socket is only half of what an X
client needs, since the server also demands the session's MIT-MAGIC-COOKIE.
Mounted **only when the file exists**, because Docker materialises a missing
bind-mount source as a *directory*, and a directory where every X client
expects a cookie file is worse than no mount at all — the same trap
`claude-cli`'s `pre-deploy.sh` exists to avoid. Whether that was the actual
cause of the GUI failure is still unconfirmed: the error was never legible.

**On the SoapySDR module names:** they are tried, not pinned — versioned names
(`soapysdr0.8-module-rtlsdr`) first, unversioned aliases second, then a
build-time warning. Debian ABI-versions these packages and the exact bookworm
name could not be verified from the session that made the change
(`packages.debian.org`, `sources.debian.org` and `deb.debian.org` are all
unreachable behind its egress proxy). Hardcoding an unverified package name is
exactly what broke this image's build in the first place; a fallback chain that
ends in a warning cannot.

### General Lessons

- **A plausible flag is not a verified flag.** Six invocations, all of which
  read correctly to anyone who knows the tools by reputation, and all of which
  the respective upstream source contradicts in one line. Every fix in this
  round came from reading `rtl_test.c`, `dump1090.c`, `unixinput.c`,
  `hackrf_transfer.c` or `convenience.c` at the version actually installed —
  which takes about a minute each and would have caught all six before the
  first deploy.
- **Same-family tools do not share a parser.** `rtl_fm`, `rtl_power` and
  `rtl_tcp` accept `100.1M` because `convenience.c`'s `atofs()` understands
  k/M/G suffixes. `hackrf_transfer`, three menu entries away, uses `strtod()`
  and reads the same string as 433 Hz *without complaining*. Assuming one
  tool's conveniences carry to its neighbours is how a silent 2000x error gets
  written down and reviewed twice.
- **A distribution's build flags are part of the tool's interface.** Upstream
  `dump1090-mutability` has an HTTP server; Debian's build of it does not, and
  ships the map's HTML for lighttpd to serve instead. Reading upstream's
  documentation is not the same as reading what `apt install` actually gave
  you.
- **The entry that pauses tells you what happened; the one that doesn't hides
  it.** Two entries out of twenty lacked the `read -p` every other one had, and
  that inconsistency alone turned a one-line X11 error into an unreproducible
  "it flashes by". Consistency in error handling is not cosmetic.
