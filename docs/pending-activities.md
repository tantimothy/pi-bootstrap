# Pending Activities

A snapshot of open follow-ups as of **2026-08-15** — though only the
`okf-graph-wiki` entry was added in that pass; every older entry below
carries its 2026-08-09 state and was not re-verified, so treat anything
else here as at least that stale. GitHub itself (PR/issue
state) is always the authoritative source for anything below that
references a PR — this file is a convenience index, not a system of
record, and goes stale the moment something merges or gets tested. Prune
an entry the moment it's resolved rather than marking it done in place;
an out-of-date "pending" list is worse than none.

---

## Needs a live test to close out

Both from `docs/future-enhancements/claude-cli-gateway-hardening.md` —
full context there, summarized here for visibility:

- **`claude-cli` gateway redirect API-shape compatibility** — confirm
  LiteLLM/Portkey (as deployed by this repo's `llm-gateways` environment)
  actually serve an Anthropic-Messages-API-compatible endpoint at the
  base URLs `environments/claude-cli/.env.gateway.litellm`/
  `.env.gateway.portkey` currently assume. Currently shipped with an
  explicit "not independently verified" caveat in both files and
  `environments/claude-cli/README.md`.
- **`claude-cli` gateway redirect + `/remote-control` interaction** —
  confirm whether an already-linked `/remote-control` session survives a
  live `point-to-gateway.sh` redirect without needing to re-link.

`claude-cli` multi-instance support (`new-instance.sh`, `deploy.sh`'s A-Z
menu tags — PRs #135/#139, both merged) — nothing below has been run
against a real Docker host yet, only simulated/verified in isolation:

- **End-to-end instance creation** — run the "New Claude CLI Instance..."
  `custom_actions` entry (or `new-instance.sh` directly) and confirm a
  second instance actually builds, deploys, and is independently
  SSH-reachable on its own port, with its own `claude_home`/
  `ssh_host_keys` volumes.
- **The action's own visibility** — confirm "New Claude CLI Instance..."
  actually appears in `deploy.sh`'s real policy menu for `claude-cli`
  (alongside FAST/STOP/CLEAN/etc.), not just in the `custom_actions`
  YAML/parsing logic that was checked directly.
## nanoclaw-mnemon: yt-dlp/python3 fix shipped and confirmed, follow-ups still open

Full account in `docs/lessons-learned/nanoclaw-mnemon.md`'s "yt-dlp /
python3 Dependency Chain" section. The bug itself is fixed and confirmed
end-to-end (PRs [#124](https://github.com/tantimothy/pi-bootstrap/pull/124),
[#126](https://github.com/tantimothy/pi-bootstrap/pull/126),
[#127](https://github.com/tantimothy/pi-bootstrap/pull/127), all merged —
a live agent successfully ran `yt-dlp` and transcribed a real video after
the fix). Not yet done:

- **`lib/locale-lib.sh` sourcing in every other environment's `run.sh`** —
  confirmed missing repo-wide (see
  `docs/future-enhancements/nanoclaw-mnemon.md` #2), fixed only in
  `environments/nanoclaw-mnemon/run.sh` so far. Each other environment's
  `run.sh` needs the same one-line `source` added, then a real direct
  invocation (bypassing `deploy.sh`'s menu) to confirm the fix actually
  applies there too — not verified by inspection alone yet.
- **CI build + smoke-test validation** (`docs/future-enhancements/nanoclaw-mnemon.md`
  #1 and #4) — not built. Would have caught the original wrong-asset bug
  at PR time instead of requiring a live agent to hit it.
- **Whether the reinstalled whisper.cpp libs/model actually landed under
  `/workspace/agent` this time** — the agent that lost them to its own
  home directory (lessons-learned issue #5) confirmed reinstalling and
  successfully transcribing a ~37-minute audio file, but not explicitly
  where the libs/model were reinstalled to. If still outside
  `/workspace/agent`, the next routine container respawn (which happens
  on its own, unprompted) will wipe them again.

## nanoclaw-mnemon: approval-delivery patch not yet verified against a live deploy

Full account in `docs/lessons-learned/nanoclaw-mnemon.md`'s "Approval-Card
Silent Delivery Failure" section. The underlying bug and fix were confirmed against a real,
live NanoClaw install (see that section for the investigation) — what's
**not** yet confirmed is that `scripts/patch-approval-delivery.cjs`'s own
text-splice actually applies cleanly against a fresh `git clone` of
`nanocoai/nanoclaw`. It was written directly from the incident report's
own diff (exact anchor text, indentation included) and passes `node -c`
plus a byte-for-byte match against `patch-host-gateway.cjs`'s established
pattern, but this repo doesn't vendor NanoClaw's source, so there's no
local copy to run the patch against and confirm the anchor still matches
upstream today. Not yet done:

- **Run a real `CLEAN` deploy of `nanoclaw-mnemon`** against a fresh clone
  and confirm the patch's own
  console output says "Patched src/modules/approvals/primitive.ts..."
  rather than the "expected body ... has changed upstream — skipping"
  warning path.
- **`pnpm exec tsc --noEmit` / `pnpm run build` after the patch applies**
  — confirm the patched file still compiles cleanly (the incident report's
  own diff was verified this way against the operator's local checkout,
  but that verification doesn't carry over automatically to this repo's
  copy of the patch text).
- **An actual end-to-end repro**: null out the delivery adapter somehow
  (or wait for the original race condition) and confirm a fresh approval
  request now logs the new error + notifies the agent instead of silently
  vanishing.

## mac-terminal-setup: core feature merged and tested, two auto-install paths unverified

Full account in `docs/lessons-learned/mac-terminal-setup.md`. The
environment itself, the whimsy-toggle confirmation fix, and the README
sources documentation are all merged to `master` and confirmed working by
the user on their own Mac. Not yet done:

- **Homebrew and `cpan` auto-install paths in `run.sh`** — both were
  written to handle a Mac missing Homebrew /
  `Acme::Scurvy::Whoreson::BilgeRat`, but the development machine already
  had both, so neither branch has actually executed. See
  `docs/future-enhancements/mac-terminal-setup.md` #1.
- **Calendar data re-sync cadence** — `bin/calendars/` was refreshed
  against `freebsd/calendar-data` once, as a point-in-time snapshot; no
  process exists yet to catch it drifting again over time. See
  `docs/future-enhancements/mac-terminal-setup.md` #3.
- **The seven splashes added to whimsy (`hollywood`, `genact`, `nms`,
  `aafire`, `bb`, `sl`, `tty-clock`) and the `whimsy-menu` picker** —
  largely closed out: `bb` builds and runs on the user's Apple Silicon
  Mac, and `aafire` renders in place there including inside tmux, after
  six fixes found across as many rounds (issues #4-#9 in
  `docs/lessons-learned/mac-terminal-setup.md`). The tmux case is
  settled too: the build log named Homebrew's ncurses and the tmux config
  was untouched, so `bin/install-aalib` now installs that formula rather
  than falling back to the SDK's older copy, whose terminfo lacks the
  `tmux-256color` entry aalib needs. Still open: hollywood's panes haven't
  been seen on a real screen, and ten of the thirteen splashes haven't been
  confirmed individually. See `docs/future-enhancements/mac-terminal-setup.md` #4.

## nanoclaw-mnemon: per-group derived agent images — one restore path still unverified

Full account in `docs/lessons-learned/nanoclaw-mnemon.md` ("the real cause
of both symptoms was a per-group DERIVED image nothing ever rebuilt"), the
mechanism in `environments/nanoclaw-mnemon/README.md`'s "Per-group agent
images" section, and the design options in
`docs/future-enhancements/nanoclaw-mnemon.md` #7 (now implemented).

- **Still unverified live:** a derived image that is *deleted or never built
  on this host* is detected via the tag list `run.sh` records at
  `data/pi-bootstrap-group-images.txt` (inside the backup, so it survives a
  restore) and rebuilt automatically. This matters most for **restore onto a
  new host**: the database comes back with each group's stored `imageTag`, but
  Docker images are never in a backup, so the image has never existed there.
  Previously that failed silently — spawn retried every 60s, exit 125, empty
  stderr, no WARN. Verified against a mocked Docker only; the normal
  CLEAN path below never exercises it, so it needs an actual restore onto a
  host that has no `nanoclaw-agent-v2-*:<group-id>` image.

Confirmed live on 2026-08-07 and no longer pending: `refresh_group_images()`
rebuilding every derived image on CLEAN (the deploy reported the group's image
REBUILT on the current base, timestamped after it, with `whisper-cli` reporting
no `libwhisper.so.1`/`libggml*.so` dynamic deps); mnemon's Ollama reachability
(`ollama_available: true` once `MNEMON_EMBED_ENDPOINT` pointed at the host's
LAN IP instead of `host.docker.internal` — and that host holds a static
address, so there is no lease to expire); and mnemon's own data surviving the
rebuild (345 insights / 4,020 edges, read from a live agent container).

## kali-pentest / metasploit / legion / dragonos-sdr: menu and build-split work, live-confirmed piecemeal

Full account in `docs/lessons-learned/kali-pentest.md`. Real, live
`docker build`/`deploy.sh` runs on target hardware confirmed: the
per-category and per-tool (Forensics) layer splits, Legion being the
~1900s Forensics bottleneck (not Autopsy), the `--treeview` rendering bug
(a real `( )` marker shown on category-header rows), and the Cancel/ESC
full-detach bug (both the original silent-detach symptom and the
over-corrected "cancel never exits" symptom). Not yet confirmed live:

- **`legion` and `metasploit` as freshly split-off
  environments** — both were scaffolded from `kali-pentest`'s own
  `run.sh` pattern and pass `bash -n`/YAML validation, but neither has
  had a live `CLEAN` deploy + attach cycle run against them yet.
- **The flattened `dialog --menu` relabeling** (bare header-word tags, no
  confirmation popup on header selection, `1-9` then `A, B, C, ...` leaf
  tags, `--default-item` cursor memory) — shipped after the rendering bug
  and the two-round Cancel/ESC fix were each individually confirmed live,
  but this specific combination hasn't itself been re-tested end-to-end
  since.
- **`REBUILD` now appearing in `deploy.sh`'s menu** for `kali-pentest`/
  `metasploit` (and automatically for every `docker-compose.yml`/
  `Dockerfile`-archetype environment) — confirmed correct by grepping
  every `run.sh` in the repo for which ones would show it, not by
  actually clicking it in a live `deploy.sh` session.
- **`pihole-wireguard`'s new `nettools` service** (iftop/nethogs/EtherApe)
  — the compose service, desktop entries, and `custom_actions` entries
  were added and pass local validation, but the image has never actually
  been built or attached to on real hardware.
- **`deploy.sh`'s Docker Manager image-age column** — the format-string
  change (`{{.CreatedSince}}`) is a one-line addition to an existing,
  already-working code path, but hasn't been visually confirmed against a
  real `dialog` render.

## nanoclaw-mnemon: OKF graph wiki proposed by a group agent, nothing decided

Full analysis in `docs/future-enhancements/okf-graph-wiki.md` (PR
[#266](https://github.com/tantimothy/pi-bootstrap/pull/266)). Nothing is
built and nothing is committed to — an agent running inside a deployed
group proposed building part of the spec for its own wiki, and the doc
records what order to do it in, which level should own it, and three
corrections to that proposal. Open items, in the order they need
answering:

Both original blocking questions came back answered on 2026-08-15 and are
recorded in the doc: **Bun is present** (`1.3.12`, in NanoClaw's own base
image, all groups — so this is group-level work, no Dockerfile patch),
and the wiki holds **632 pages**, not the ~50 originally assumed, which
promoted `build-index.ts` from "wait" to "early". What's still open:

A second round of answers on 2026-08-15 closed the rest of the scoping.
The `type:` vocabulary is not the conflict it looked like — the corpus
already splits into 153 document-typed pages and 138 untyped
person-pages, so document types stay and OKF entity types apply only to
the latter. Those 138 also carry `married:` fields, which are relations
written as ad-hoc scalars, so the graph exists already and the schema
step is formalization rather than invention. The `/home/node/.claude`
mount is confirmed per-group, so the shared-hook risk doesn't apply.
Ollama is reachable again. What's left:

- **The wiki is not in git** (`fatal: not a git repository`). This
  outranks every script: §5.1's strongest objection to mnemon is that
  its store isn't git-diffable, and 632 pages of unversioned markdown
  aren't either. Do it *before* the frontmatter backfill, so 341 pages
  of mechanical change land as a reviewable diff. `git init` in `wiki/`
  only, and local-only unless a remote is deliberately chosen — this
  corpus holds family and personal-history pages, and `backup.sh`
  already covers the offsite need via `groups/`.
- **Are `married:` values page links or plain names?** Decides whether
  converting them to `relations` is a rewrite or also has to create
  entity pages for spouses who don't have one.
- **Nothing here has been corrected at the source yet.** The Ollama
  correction in particular (the proposal treats it as an in-container
  package install; `ensure_ollama_ready()` already handles it on the
  host) only exists in this repo's docs so far — the group agent that
  proposed it hasn't been told.

## Ollama: outage closed on the host, one tool fix still open

The 2026-08-15 outage is fully resolved on the host side — Ollama
restarted and confirmed reachable from inside a group container, the
watchdog scheduled through the `ollama` environment's own action, the
schedule re-run after `.env` was confirmed so the plist carries the
right bind address, and the boot question answered (that host
auto-logs-in, so the LaunchAgent covers a reboot). Full account, and the
note that auto-login is now a load-bearing prerequisite, in
`docs/lessons-learned/general.md`.

- **`--status` reports the live bind address, not the scheduled one.**
  The last thing left here, and it's a change to `ollama-watchdog.sh`
  rather than anything on the host — scoped in
  `docs/future-enhancements/ollama-watchdog-status-reporting.md`.

## Known, deliberately-deferred code quality items

Tracked in full in `docs/refactoring-opportunities.md`, not duplicated
here — includes shared logic between `point-to-gateway.sh`/
`revert-to-claude.sh`, three independent "auto-discover, else prompt,
else fall back" implementations, `backup.sh`'s manually-maintained
`is_deployed()` case statement, `new-instance.sh`'s `sed`-based
`config/environments.yaml` registration and its SSH-port suggestion not
checking real port availability, `nanoclaw-mnemon`'s yt-dlp arch-detection
logic duplicated across three files, `mac-terminal-setup`'s
backup-before-overwrite helpers having no shared home with any other
`run.sh`-based environment, and the total absence of automated tests for
`lib/*.sh`'s `${VAR}`-expansion contract.
