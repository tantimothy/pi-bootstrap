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
