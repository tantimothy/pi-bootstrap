# dragonos-sdr — Lessons Learned

## Session: image build failed outright on two apt packages that don't exist in Debian

**Status:** Fixed (code); the rebuilt image itself is not yet verified on real
hardware — see *Still unverified* below.

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

**Still unverified:** every claim above about *build* behaviour was checked
against upstream's actual `Makefile`/`CMakeLists.txt`/`sdr.c` at the pinned
refs, not against a completed build — no Docker daemon (and no ARM64 Pi) was
available in the session that made the change. The three compile layers, and
all four runtime fixes, still need one real `CLEAN` deploy on a Pi with a
dongle attached to close out.

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
