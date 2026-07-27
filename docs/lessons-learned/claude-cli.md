# Claude CLI Environment — Debugging & Setup Lessons Learned

**Status:** retrospective on the environment's first real-world deploy. Every
fix below is merged (PR [#128](https://github.com/tantimothy/pi-bootstrap/pull/128),
[#129](https://github.com/tantimothy/pi-bootstrap/pull/129)) — this document
is the record of what broke and why, plus what's still genuinely open.

## Summary

`environments/claude-cli` looked complete on paper — Dockerfile, entrypoint,
docker-compose, README — but its first real deploy on an actual Pi surfaced
six distinct issues in sequence, none of which showed up until an actual
build/run/SSH cycle exercised them. None were exotic: each is a well-known
class of Docker/Linux footgun, just not one this environment had been
exercised against before. This is the connected story, in the order they
were hit.

## Issues Found & Fixed

### 1. `gh` CLI apt repo 404 — build failure

**Symptom:** `docker compose build` failed at the `gh` CLI install step —
`404 Not Found` fetching the Release file, `apt-get update` then refusing
to proceed.

**Root cause:** The Dockerfile's apt source line pointed at
`https://cli.github.com/packages/stable/apt`, which doesn't exist. GitHub's
actual repo is served directly at `https://cli.github.com/packages`, with
`stable main` as the `deb` line's distribution/component — not part of the
URL path at all. Where the extra `/stable/apt` segment came from isn't
clear; it doesn't match GitHub's own install instructions at any point.

**Fix:** Corrected the URL to match GitHub's documented install command
exactly. (`environments/claude-cli/Dockerfile`)

### 2. UID 1000 collision — container crash-loop

**Symptom:** Image built fine, but the container crash-looped forever —
`docker logs` showed `usermod: UID '1000' already exists` repeating,
because the restart policy (`restart: unless-stopped`) kept relaunching it
after each failure.

**Root cause:** `node:20-slim` — like every official Node Docker image —
already ships its own `node` user/group at UID/GID 1000. The Dockerfile's
`useradd --create-home --shell /bin/bash claude` had no explicit UID, so it
silently landed on 1001 instead (1000 being taken). At runtime,
`entrypoint.sh` defaults `PUID`/`PGID` to 1000 and tries
`usermod -u 1000 claude` / `groupmod -g 1000 claude` on every start to
match — colliding with the still-present `node` identity every single time.

**Fix:** Delete the base image's `node` user before creating `claude`, and
create `claude` with an explicit `--uid 1000` so it lands cleanly on
1000:1000 with nothing left to collide with.

### 3. `groupdel` failing on the very fix for #2 — build failure again

**Symptom:** The fix for issue #2 itself failed to build:
`groupdel: group 'node' does not exist` (exit code 6).

**Root cause:** Debian's `userdel -r` already auto-deletes a user's private
group once its last member is gone, under the (default) `USERGROUPS_ENAB=yes`
setting in `/etc/login.defs`. So by the time the Dockerfile's explicit
`groupdel node` ran, `userdel -r node` had already removed it — an
undocumented side effect that only shows up if you try to clean up the
group yourself afterward.

**Fix:** Wrap the follow-up `groupdel` in `(groupdel node || true)`, since
whether the group still exists at that point is genuinely ambiguous and
either outcome is fine.

### 4. `authorized_keys` directory-vs-file — SSH `Permission denied (publickey)`

**Symptom:** First SSH attempt after a successful, healthy deploy still
failed: `Permission denied (publickey)`, even with a real key.

**Root cause:** `SSH_AUTHORIZED_KEYS_PATH` (`~/.ssh/authorized_keys` on the
host by default) didn't exist yet before the very first deploy. Docker
Compose's bind mount auto-creates a missing **source** path — but as an
**empty directory**, not a file. `entrypoint.sh`'s `[ -f /run/host-authorized_keys ]`
check then silently failed (it's a directory, not a regular file), fell
through to its "no keys" branch, and wrote an empty `authorized_keys` inside
the container. Every key was rejected because there was nothing to match
against — not because of anything wrong with the key itself.

**Fix:** No code fix needed (this is host-side state, not something the
Dockerfile/compose file can prevent) — documented the diagnosis and repair
steps directly in the README's new Troubleshooting section: remove the
Docker-created directory, create a real file containing the actual public
key, `chmod 600` it.

### 5. Docker mount type mismatch after fixing #4 — restart failure

**Symptom:** Having just fixed #4 by turning the host path from a directory
into a file, restarting the container (`docker compose stop` then
`docker compose up -d`) failed outright:
`error mounting ... not a directory: Are you trying to mount a directory onto a file (or vice-versa)?`

**Root cause:** A running container's mount configuration is fixed at
**creation** time, not re-derived on every start. `stop`/`up` (or `restart`)
reuses the existing container and its already-baked-in mount spec, which
still expected a directory at that path from when it was first created.

**Fix:** No code fix — documented that this specific class of change (a
bind-mount source's type flipping between file and directory) requires
**recreating** the container (`docker compose down && docker compose up -d`),
not just restarting it. Safe to do since named volumes aren't touched by
`down`.

### 6. No documented way to reach a plain shell

**Symptom:** SSH auto-attaches straight into a tmux window running `claude`
itself — typing a shell command at that prompt sends it to `claude` as a
chat message instead of running it. The README's own Home Assistant section
assumed a plain shell ("run it in a shell, not as a message to Claude")
without ever explaining how to get one.

**Fix:** Documented three ways in the README: a second tmux window
(`Ctrl-b c`), a non-interactive `ssh host '<command>'` invocation (which
skips the tmux auto-attach profile script entirely), and `docker exec -it -u claude`
from the host directly.

### 7. tmux session — and conversation continuity — lost on container restart

**Symptom:** After any container restart (even the "gentle"
`STOP`→`FAST` pause/resume the README describes as "without losing data"),
reconnecting dropped into a **brand-new, empty** `claude` conversation
instead of the one in progress.

**Root cause:** tmux's session state is purely in-memory inside the
container's own process namespace — restarting the container kills tmux's
server process along with everything else, even though it's not a full
image rebuild. `-A` (attach-or-create) only skips re-running the launch
command when a live session already exists to attach to; after any restart
there isn't one, so a fresh `claude` (no flags) ran every time, discarding
continuity even though the actual conversation history was safe all along
in the `claude_cli_home` named volume (`~/.claude`).

**Fix:** Changed `bashrc-tmux-attach.sh`'s launch command from bare `claude`
to `claude --continue`, so a freshly created tmux session resumes the most
recent conversation automatically instead of starting blank. `claude --resume`
remains available from a plain shell (see #6) for picking an older
conversation specifically.

## General Lessons

- **Official `node:*` Docker images all ship a `node` user/group at UID/GID
  1000.** Any Dockerfile building `FROM node:*` that creates its own
  non-root user needs to account for this explicitly — either reuse the
  existing `node` account or remove it first — or risk exactly the silent
  UID-bump-then-collide failure hit here.
- **Docker Compose bind mounts silently vivify a missing source path as a
  directory, never a file.** Any bind mount whose source is expected to be
  a single file that might not exist yet on a first deploy (an
  `authorized_keys` file, a token file, a single config file) is at risk of
  this exact failure mode — worth a pre-flight check or explicit callout in
  any environment with a similar pattern.
- **A container's mount specification is fixed at creation, not
  recomputed on every start.** Any host-side change to a bind-mount
  source's fundamental type (file↔directory) needs `down && up`
  (recreation), not `stop`/`start`/`restart`.
- **tmux (or any in-container process state) is not itself a persistence
  mechanism across container restarts.** Only what's explicitly written to
  a named volume survives — conversation history and "the live tmux
  session" are two entirely different layers here, and it's easy to assume
  the wrong one is what's carrying continuity.
- **GitHub App / repo access scope changes can lag behind what a live
  session's local git credentials see.** During this work, a push started
  403ing after the user (unintentionally) narrowed GitHub App repo access
  while trying to scope one specific chat session to one repo; even after
  restoring it, `git fetch` recovered before `git push` did, and it took a
  few retries before the push-side credentials caught up.
- **A merged PR's branch can't be pushed onto again.** Mid-session, PR #128
  merged while more commits kept landing on the same branch — those had to
  be rebased onto the new `master` and opened as a fresh PR (#129) rather
  than stacked on top of already-merged history.

## Current Pending Activities / Open Items

- [ ] **Verify `claude --continue`'s behavior on a genuinely fresh (zero
      conversation history) `claude_cli_home` volume.** The fix for issue
      #7 assumes it degrades gracefully to a normal new session rather than
      erroring out, based on how resumable-session CLI flags generally
      behave — this has not been confirmed against this exact container.
      If it turns out to error instead, first-ever login (before any
      conversation has ever happened) would break, and a proper fix would
      need to distinguish "no history to continue" from "user exited on
      purpose" rather than a blind `claude --continue || claude` fallback.
- [ ] **No CI/automated build validation exists for this environment's
      Dockerfile.** All three build-breaking issues (#1, #2, #3) were each
      found manually, one at a time, on real deploy attempts rather than
      caught before merge. See `docs/future-enhancements/claude-cli.md`.
- [x] Audited `nanoclaw` and `nanoclaw-mnemon` (the repo's other two
      `node:20-slim`-based environments) for the same UID-1000-collision
      risk — neither creates its own non-root user or sets `PUID`/`PGID`,
      so neither is currently affected. Worth re-checking if either one
      adds a non-root user later.

## Gateway Redirect — an Unverified Assumption Shipped Honestly Instead of Silently

**Status:** open — this isn't a found-and-fixed bug like the issues above,
it's a different kind of lesson: an assumption that went into a shipped
feature (PR [#136](https://github.com/tantimothy/pi-bootstrap/pull/136))
with an explicit, dated caveat instead of either (a) blocking the feature
on verifying it first, or (b) shipping it silently as if confirmed. See
`docs/future-enhancements/claude-cli-gateway-hardening.md` for the full
tracking of what closing it out looks like.

**What happened:** `scripts/point-to-gateway.sh` redirects Claude Code's
`ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN` at a self-hosted gateway (this
repo's own `llm-gateways` environment — LiteLLM or Portkey). `llm-gateways`'
own README documents calling those gateways via their **OpenAI-compatible**
`/v1/chat/completions`-shaped endpoint. Claude Code's `ANTHROPIC_BASE_URL`
expects a server speaking the **Anthropic Messages API** shape instead — a
different request/response format. Both gateways document *some*
Anthropic-compatible route of their own, but nobody has confirmed the
specific base URLs `.env.gateway.litellm`/`.env.gateway.portkey` assume
actually serve that shape for the versions this repo currently pins.

**The lesson:** "OpenAI-compatible" and "Anthropic-Messages-API-compatible"
are different shapes, easy to conflate because both get described in the
wild as "just point your client's base URL at it" — but that phrase means
something different depending on which client you're pointing. Before
wiring `ANTHROPIC_BASE_URL` at any self-hosted gateway, confirm which
shape it's actually serving at that specific route (some gateways expose
both, on different paths), rather than assuming an "OpenAI-compatible"
label implies Claude-Code-compatible. Separately: when a feature genuinely
can't be verified before shipping (no live gateway available in this
session), the honest move — used consistently across this repo, e.g. this
same file's own issues #1–#7 above being confirmed against a real deploy
rather than assumed — is to say plainly *where* the uncertainty is (in
the shipped code's own comments, not just a side document) rather than
implying something's tested when it isn't.

## `~/.claude.json` (MCP Registrations) Silently Not Persisted

**Status:** fix implemented (`entrypoint.sh` now symlinks `~/.claude.json`
into the existing `claude_cli_home` volume, PR
[#151](https://github.com/tantimothy/pi-bootstrap/pull/151)) — not yet
merged.

**What happened:** a user asked directly whether `/home/claude/.claude.json`
would survive a rebuild. Checking `docker-compose.yml`'s actual volume
list answered it immediately: `claude_cli_home` mounts `~/.claude` (the
**directory**) — `~/.claude.json` is a separate **file** one level up, a
sibling of that directory rather than something nested inside it, so it
was never covered by that mount (or any other). Confirmed via a repo-wide
grep that nothing anywhere had ever accounted for this file at all. The
user then confirmed `~/.claude.json` is exactly where `claude mcp add`
(see "Connecting to Home Assistant" above) writes its registrations —
meaning every MCP server anyone registered was silently lost on the next
`CLEAN` rebuild, with the README at the time actively claiming the
opposite ("This registration lives under `~/.claude`... tied to the
container").

**The fix:** `entrypoint.sh` now symlinks `~/.claude.json` to
`~/.claude/.claude.json` (inside the already-persistent volume) on every
start, migrating any real pre-existing file into the volume first rather
than discarding it, so an existing deploy with real MCP servers already
registered doesn't lose them switching to the symlinked layout.

**The lesson:** a named volume mounted at a directory covers *only* paths
nested inside that directory — a sibling file one level up, even one with
a very similar name (`~/.claude.json` vs. `~/.claude/`), is a completely
different, uncovered path. This is exactly the kind of gap that's easy to
miss by pattern-matching "this app's config lives under `~/.claude`,
that's mounted, so we're covered" rather than checking each actual file
Claude Code writes individually — the same shape of mistake as this
file's own `${VAR}`-expansion-adjacent findings in
`docs/lessons-learned/general.md` (a documented contract, or a plausible
assumption, standing in for verifying the actual code/file layout).
Caught here only because a user asked a direct, specific question rather
than the environment being audited for it proactively.

## `~/.claude.json` Persistence Fix, Round 2 — the Symlink Didn't Survive Real Use

**Status:** fixed, not yet re-confirmed against a live rebuild (the
original symlink fix above also looked correct on paper and in isolated
filesystem tests — this one's actual proof will be a real `claude mcp
add` followed by a real `CLEAN` rebuild).

### Summary

A real user reported losing their registered MCP server on a routine
`CLEAN` rebuild of `claude-cli` — exactly the symptom the fix above
(PR #151) was supposed to prevent. Root cause: PR #151's symlink
(`~/.claude.json` → `.claude/.claude.json`, inside the persistent
`claude_cli_home` volume) is correct right up until Claude Code itself
writes to `~/.claude.json` for the first time (e.g. `claude mcp add`).
Claude Code writes this file via an atomic temp-file-then-`rename()` —
and POSIX `rename()` onto a path that's currently a symlink **replaces
the symlink itself**, it does not follow it through to the target. So
the very first MCP registration silently clobbered the symlink with a
real, ordinary file sitting on the container's own ephemeral layer —
invisibly, since nothing looked different from the inside (`~/.claude.json`
still worked fine as a plain file for every read/write after that). No
further `entrypoint.sh` run happened in between to notice and re-fix it
(`entrypoint.sh` only runs at container start, not continuously), so by
the time the next `CLEAN` rebuild tore the old container down, that
file — the *only* copy with the real registration in it — was destroyed
along with it. The persistent volume never actually received the data;
the symlink only ever protected the brief window before Claude Code's
own first write replaced it.

**Fix:** `~/.claude.json` now has its own named volume
(`${CONTAINER_NAME:-claude-cli}_claude_json`), mounted directly at that
exact path in `docker-compose.yml` — a real mount point, not a symlink.
`rename()` onto a mount point lands on the volume-backed storage
regardless of how the file underneath gets rewritten, so this doesn't
share the symlink's failure mode. For Docker to mount a *file*-level
volume there (rather than defaulting to a directory, which is what
happens when nothing already exists at an empty volume's target path),
the `Dockerfile` now `touch`es a placeholder file at that path at build
time — Docker copies that in when the volume is first attached, and from
then on treats the mount as file-level. `entrypoint.sh` also carries a
one-time migration: if the *old* symlink target
(`~/.claude/.claude.json`, inside the still-untouched `claude_cli_home`
volume) still has real content and the new volume-backed
`~/.claude.json` is still empty, it's copied over once — for anyone
whose registration hadn't yet been silently clobbered by the bug above
at the moment they upgrade. Anyone who'd *already* hit the bug (like the
reporting user) has to re-register once more; that data was already gone
before this fix could reach it.

### General Lessons

- **A symlink into a persistent volume only protects a file for as long
  as nothing ever replaces the symlink itself.** Programs that write
  "atomically" via temp-file-then-`rename()` — a common, genuinely good
  practice for avoiding corruption on crash/power-loss — silently defeat
  a symlink-based persistence trick the very first time they write,
  because `rename()` never follows a trailing symlink at its destination;
  it overwrites the link itself. This is invisible from both sides: the
  app just sees a normal file it can read/write, and the symlink looked
  completely correct at the moment it was set up and tested. The only
  robust fix for "make an app's config file survive a container rebuild"
  is a mount point *at that exact path* — not a link to one elsewhere.
- **An isolated filesystem test of a persistence mechanism (as the
  original PR #151 did — fresh-start, migration, idempotent-rerun cases)
  proves the mechanism handles *entrypoint.sh's own* file operations
  correctly. It says nothing about what happens when the actual
  application being wrapped writes to that same path its own way.** The
  gap here was entirely in behavior neither entrypoint.sh nor its tests
  ever exercised — Claude Code's own write pattern — which only a real
  `claude mcp add` followed by a real rebuild would have caught.

## The `~/.claude.json` Placeholder Broke the Build Itself, Not Just Runtime Persistence

**Status:** fixed.

### Summary

A real `CLEAN` rebuild failed outright — `docker build` itself, not a
runtime symptom — at the exact `RUN touch /home/claude/.claude.json &&
chown ...` / installer step from the fix above (Round 2). The installer
(`curl -fsSL https://claude.ai/install.sh | bash`) runs as the non-root
`claude` user right after that placeholder is created, and its own setup
step invokes `claude`, which reads and parses `~/.claude.json` — finding
the zero-byte placeholder already sitting there from the `touch`, and
failing to parse it as JSON.

### Issue Found & Fixed

**Symptom:** `docker build --progress=plain` showed the actual installer
output BuildKit's default terse summary hides: "Claude configuration file
at /home/claude/.claude.json is corrupted: JSON Parse error: Unexpected
EOF" — followed by the same message a second time, then a hard exit,
failing the whole `RUN` step (and the build).

**Root cause:** the Round 2 fix above added `RUN touch
/home/claude/.claude.json && chown claude:claude ...` specifically so a
later `docker-compose.yml` volume mount at that exact path would attach
as a file, not a directory — reasonable for the *mount-type-detection*
problem it was solving. But it created that placeholder *before* the
`USER claude` / `RUN curl ... install.sh | bash` step, and the installer
itself runs `claude` as part of its own setup, which reads and parses any
pre-existing `~/.claude.json` — a zero-byte file isn't valid JSON, so
that read failed and aborted the entire build, not just a later runtime
concern. This is the same underlying gap as the sibling `nanoclaw`/
`nanoclaw-mnemon` environments' own placeholder (an empty file being
treated as "exists but has no valid content"), just surfaced as a hard
build failure here instead of a Docker volume-mount quirk there, because
here something *else* (the installer) reads the file before Docker's own
volume-mount copy-up ever gets a chance to matter.

**Fix:** changed the placeholder from `touch` (empty) to `echo '{}' >`
(a valid, empty JSON object) — still a real file at that exact path for
the volume-mount-type reasoning to work, but now something any JSON
parser (the installer's, or `claude` itself at any later point) accepts
without error.

### General Lessons

- **A "just needs to exist as a file" placeholder isn't actually
  content-agnostic once something downstream parses that file's
  contents, not just its existence/type.** The original placeholder's own
  job (make Docker's volume-mount type-detection see a file) had no
  opinion on content — `touch` was sufficient for that alone. But the
  same file path being independently meaningful to a *second* consumer
  (the installer's own `claude` invocation, which reads real JSON there)
  means "any file" and "any file this app can actually parse" are
  different requirements, and only the narrower one (mount-type
  detection) was ever checked.
- **`docker build --progress=plain` is worth reaching for immediately
  when a `RUN` step fails with only "did not complete successfully: exit
  code: 1"** — BuildKit's default output had already collapsed the
  actual, decisive error message (the installer's own stderr) into
  nothing, and the real diagnosis was sitting right there once asked for
  in plain mode, no guessing required.

## `~/.claude.json` Persistence, Round 3 — Named Volumes Don't Work Reliably on Every Docker Implementation

**Status:** fixed and confirmed live — a real MCP server registration
(Home Assistant) survived a genuine `CLEAN` rebuild, verified directly
against both the host file and the container's own view of it before the
CLEAN, then reconfirmed present after. Fixed via a structural change
(bind mount + a new shared "pre-deploy" hook) rather than another
mount-syntax tweak.

### Summary

The Round 2 fix above (a named `claude_cli_json` volume mounted directly
onto `/home/claude/.claude.json`) built successfully after the placeholder
fix immediately above this entry, but then failed at `docker compose up`
with `Error response from daemon: source .../merged/home/claude/
.claude.json is not directory` — the exact same failure class already
root-caused and fixed (by reverting the feature) in the sibling
`nanoclaw`/`nanoclaw-mnemon` environments: see
`docs/lessons-learned/nanoclaw-mnemon.md`'s own entry for the full
investigation. That investigation already established the real cause —
the user's Docker Engine is OrbStack's own reimplementation, which doesn't
reliably auto-detect file-vs-directory type for a fresh named volume
attached to a single-file destination (orbstack/orbstack#1274, #1485) —
so this entry only covers what's specific to fixing it *here*, where
(unlike the sibling environments) the feature is genuinely wanted and
already in real use (MCP server registrations, e.g. Home Assistant).

### Issue Found & Fixed

**The obstacle bind mounts introduce:** a bind mount's source doesn't
need Docker to guess its type — it just needs to already exist, correctly.
But Docker Compose is purely declarative: there's no way to specify "run
this before `up`" in `docker-compose.yml` itself, and Compose's own
fallback for a missing bind-mount source is to auto-create a *directory*
— the exact wrong-type problem this was meant to avoid, just moved from
Docker's volume driver to Compose's own bind-mount handling.

**Fix:** added a new, generic, optional hook to `lib/deploy-lib.sh`'s
shared compose dispatch (used by every `docker-compose.yml`-based
environment in this repo, not just this one): an executable
`pre-deploy.sh` in an environment's own directory now runs once before
`docker compose build`/`up`, on FAST/CLEAN only — the same lifecycle
point the existing "pre-create `data_dirs`" step already runs at. This
environment's own `pre-deploy.sh` creates `data/claude-json/claude.json`
with valid JSON content (`{}`) if it doesn't already exist. `docker-
compose.yml`'s `claude_cli_json` volume mount was replaced with a bind
mount to that exact host file; the top-level `claude_cli_json:` volume
entry, and its `named_volumes` entry in `info.yaml`, were removed, and a
`data_dirs` entry added instead (so it's still backed up / WIPE'd).
`data/claude-json/` is gitignored (it holds real, live MCP registration
data after first use) and excluded from `new-instance.sh`'s directory
copy (a new instance always starts with none of its own).

Verified against a real `docker compose config` resolution that the bind
mount resolves to the correct absolute host path; the actual container
startup with a live registration wasn't re-verified end-to-end in this
sandbox (no live Docker daemon here).

### General Lessons

- **A structural fix (bind mount, no type-detection needed at all) is the
  right response to a bug whose mechanism is a third-party Docker
  implementation's own volume driver, not something in this repo's
  control.** Trying another combination of mount syntax/flags for the
  *same* named-volume mechanism (as the `nanoclaw`/`nanoclaw-mnemon`
  investigation already tried and had fail identically) wasn't worth
  repeating here once the sibling investigation had already established
  the real cause.
- **Solving "the declarative file can't guarantee this" sometimes means
  extending the *shared* dispatcher, not hacking around it per-
  environment.** A one-off script wrapping `docker compose up` just for
  this one environment would have worked too, but would have meant either
  reimplementing `deploy_environment()`'s whole FAST/CLEAN/STOP/TEARDOWN/
  INFO/WIPE policy handling from scratch (a `run.sh` completely replaces
  the generic compose dispatch, it doesn't extend it) or forking the
  policy logic. Adding one small, generic, optional hook to the existing
  shared dispatcher — mirroring the already-precedented `data_dirs`
  pre-creation step right next to it — solves this environment's need
  and is immediately reusable by any future environment that hits the
  same class of problem.
- **A feature actually being requested and used changes the right
  response to the same underlying bug.** The sibling `nanoclaw`/
  `nanoclaw-mnemon` environments hit the identical OrbStack bug for an
  *unrequested* feature and the right call there was to drop it entirely.
  Here, the same bug hit a feature the user is actually using (MCP
  registrations) — dropping it would have been a real, noticeable
  regression, so the right call was to invest in the structural fix
  instead. Don't apply the same resolution to two situations just because
  the technical failure looks identical; check what's actually being
  asked for and used before choosing revert vs. fix-forward.

## `CONTAINER_NAME='name'` (Quoted) Broke Docker Compose Volume Creation — a Repo-Wide Gap, Not Just `new-instance.sh`

**Status:** fixed, not yet independently re-confirmed live (the MCP
persistence fix above WAS re-confirmed via a real CLEAN, but this
specific bug — hit via "Choose Claude Model" on a `new-instance.sh`-
created instance — wasn't separately retested afterward).

### Summary

"Choose Claude Model" on a second instance (`claude-cli-home-assistant`,
created via `new-instance.sh`) failed with `Error response from daemon:
create 'claude-cli-home-assistant'_claude_json: "'claude-cli-home-
assistant'_claude_json" includes invalid characters for a local volume
name`. The quotes are literally part of the error — not a display
artifact.

### Issue Found & Fixed

**Root cause:** `new-instance.sh` writes `.env` values as `KEY='value'`
(single-quoted), matching `deploy.sh`'s own generic bulk config form
convention — quoting exists there for a real reason (protecting `$`-
bearing secrets like bcrypt hashes from bash variable expansion on
`source`). But `CONTAINER_NAME` also feeds directly into `docker-
compose.yml`'s own `${CONTAINER_NAME:-default}` interpolation for
container/volume names, and at least one Docker Compose version doesn't
strip those quotes the way bash `source`-ing does — the literal quote
characters end up baked into the volume name Compose tries to create,
which Docker then rejects outright.

Confirmed directly with a local `docker compose config` reproduction
(matching `claude-cli`'s actual compose structure) that this specific
installed version (v5.1.1) handles quoted `.env` values correctly via
direct `.env`-file parsing — so the bug is either version-dependent, or
specific to how `choose-model.sh` invokes compose (it extracts
`CONTAINER_NAME` via `grep`+`cut`, which does NOT strip quotes the way
bash `source` does, only for its own echo message — but never exports
that value, so the actual `docker compose up -d` call still falls back
to Compose's own native `.env` parsing regardless). The live error is the
decisive evidence either way: whatever the exact mechanism, the quotes
demonstrably end up in the created volume's name on the user's real host.

**Fix:** stopped quoting `CONTAINER_NAME` specifically, in both writers —
`new-instance.sh` and `deploy.sh`'s own generic bulk form compiler — since
a valid Docker container/volume name can never contain `$`, spaces, or
anything else the quoting was ever protecting against in the first
place. Every other var stays quoted (still needed for values that might
have spaces or `$`-bearing secrets). `deploy.sh`'s own read-back logic
(strips a leading/trailing `'` if present, for the dialog form's display)
already tolerated an unquoted value fine, so this doesn't break
round-tripping an existing value back into the form.

### General Lessons

- **`deploy.sh`'s own generic bulk config form quoting every value the
  same way meant this bug was never actually specific to
  `new-instance.sh`** — any docker-compose-based environment's
  `CONTAINER_NAME`, if ever edited through that generic form (not just
  the narrower multi-instance script), would hit the identical failure.
  Fixing only the one call site that happened to surface the bug would
  have left the same landmine everywhere else `CONTAINER_NAME` is a
  managed `.env.example` key.
- **A tool correctly handling most `.env` quoting cases (confirmed
  directly, locally) doesn't mean every code path that touches that value
  goes through the same handling.** `choose-model.sh`'s own `grep`+`cut`
  extraction of `CONTAINER_NAME`, used only for a display message, was
  easy to overlook as "just cosmetic" — but proved the actual smoking gun
  for where an already-quoted `.env` line's literal quote characters were
  visibly present, confirming the value's quoting was the right thing to
  fix regardless of exactly which invocation path hit the daemon-side
  error.

## Related PRs

- [#128](https://github.com/tantimothy/pi-bootstrap/pull/128) — `gh` CLI
  apt URL fix, UID 1000 collision fix (issues #1–#2 above)
- [#129](https://github.com/tantimothy/pi-bootstrap/pull/129) — `groupdel`
  tolerance, plain-shell docs, SSH deploy.sh menu action, `--continue`
  auto-resume fix (issues #3, #6, #7 above; issues #4–#5 were host-side
  troubleshooting documented in the README rather than code changes)
- [#136](https://github.com/tantimothy/pi-bootstrap/pull/136) — gateway
  redirect feature (`point-to-gateway.sh`/`revert-to-claude.sh`,
  `.env.gateway.*`), shipped with the open API-shape assumption above
- [#151](https://github.com/tantimothy/pi-bootstrap/pull/151) — `~/.claude.json` persistence fix above (the symlink version, later found incomplete)
- (round 2 fix) — the `~/.claude.json` persistence fix, round 2, above
- (placeholder fix) — the `~/.claude.json` placeholder build-failure fix above
- [#175](https://github.com/tantimothy/pi-bootstrap/pull/175) — `~/.claude.json` persistence fix, round 3 (bind mount + shared pre-deploy hook), and the `CONTAINER_NAME` quoting fix, both above
