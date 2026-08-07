# General Lessons Learned

Cross-cutting things discovered the hard way while working on this repo —
kept separate from any single environment's own file in this directory
because they generalize beyond it (git workflow, `lib/*.sh` internals,
documentation practice), not because they're a lower tier of finding. Add
to this file when something costs real debugging time and would save it
for the next person (or agent) who hits the same shape of problem; don't
add routine bug fixes here, those belong in the relevant environment's own
README/commit history, or that environment's own file in this directory
(e.g. `claude-cli.md`, `nanoclaw-mnemon.md`) if it's a real debugging
session specific to one environment.

---

## A long-lived feature branch can silently diverge from `master` between your *own* PR merges

**What happened:** this repo's workflow restarts a working branch from
`master` only after *that branch's own* PR merges. Multiple times this
session, a *different* branch (a sibling PR, working on `claude-cli`'s
multi-instance support, or `mac-terminal-setup`, or a `desktop-lib.sh`
`.webloc` fix) merged into `master` while this branch was mid-task. Since
nothing about "my own PR merged" was true yet, the branch never picked
those commits up on its own — `git log`/`git diff` against `origin/master`
showed real, unrelated content the branch was missing, discovered only by
explicitly fetching and diffing before pushing, not by assuming the
branch was current.

**The lesson:** before pushing a batch of work — not just after your own
PR merges — `git fetch origin master && git diff --stat HEAD
origin/master` to check what else has landed. A clean `git merge
origin/master` is cheap and safe when there are no real conflicts (as it
was every time this session); catching the divergence *before* opening a
PR is much cheaper than discovering it from a confused diff after the
fact.

---

## Grep for content, but also just `ls` the directory — an established convention can be missed by a single search pattern

**What happened:** asked whether "future enhancements" documentation
existed anywhere in this repo, a content grep for the literal phrase
across `*.md` files came back empty — but `docs/future-enhancements/`
already existed as an established directory convention (two substantial
design docs in it), just never containing that exact phrase in running
text. The initial "no, nothing like that exists" answer was wrong.

**The lesson:** a targeted content grep answers "does this exact phrase
appear," not "does this concept have a home." For "is there already a
place for X," check the directory structure itself (`ls docs/`, `find . -iname
'*<topic>*'`) before concluding a convention doesn't exist — cheaper than
being wrong, and this repo in particular tends to already have a
convention for most documentation needs.

---

## `docker compose up -d` picks up a changed `.env` value without a rebuild

**Useful, not a mistake:** Compose recreates a container when its
*resolved* config (including `${VAR}`-interpolated environment values from
`.env`) differs from what's currently running — confirmed directly while
building `scripts/point-to-gateway.sh`/`scripts/revert-to-claude.sh` for
`claude-cli`. Writing a new value into `.env` and running `docker compose
up -d` (exactly what `deploy.sh`'s `FAST` policy already does) is enough
to apply an environment-variable-only change; no `CLEAN`/rebuild needed.
Worth remembering before reaching for a heavier redeploy path for a
config-only change.

---

## A `${VAR}`-expansion helper applied to "some" fields is easy to mistake for "all" fields

**What happened:** `lib/desktop-lib.sh`'s `_load_desktop_entries_yaml` only
ran `_yaml_expand` on `entries[].target` — `menu.id`, `entries[].id`, and
`info.id` were read as plain literals, even though the function's own doc
comment claimed "any string value may contain `${VAR}` markers." That gap
is exactly what caused `claude-cli`'s desktop-entry IDs to collide across
instances: two copies of the environment both wrote the same `.desktop`
filenames, silently overwriting each other's shortcuts. The same category
of bug turned up independently in `lib/info-lib.sh`'s `_load_info_yaml`
moments later: `named_volumes[].name` wasn't expanded either, even though
every sibling field in that same function (`data_dirs`, `install_dirs`,
`wipe_parent_dirs`) was — meaning `INFO`/`WIPE`/`backup.sh` for a second
`claude-cli` instance would have silently operated on the *first*
instance's `claude_home`/`ssh_host_keys` volumes instead of its own.

**The lesson:** a loader function's own doc comment describing its
contract ("any string value supports `${VAR}`") is aspirational, not
verified — it describes intent, not necessarily every field's actual
implementation. When adding a new templated field to a schema like this,
re-read the loader's *code* field by field rather than trusting its
comment; and when fixing one field's missing expansion, check every
sibling field pulled by the same function for the identical gap — this
exact omission happened twice, independently, in two different loaders
within one session.

---

## A YAML field with no matching code in the "obvious" file might still be read somewhere else entirely

**What happened:** `info.yaml`'s `custom_actions` field was declared
unused/dead after grepping `lib/info-lib.sh` (the file that owns
`info.yaml`'s documented schema) and finding no reference to it. That was
wrong — `deploy.sh` itself reads `custom_actions` directly, independent of
`lib/info-lib.sh`, and surfaces each entry as a real, interactive item in
its own policy menu (tagged `ACTION_<index>`, alongside FAST/STOP/CLEAN/
etc.). The mistake led to building a new feature (`claude-cli`'s "create a
new instance" action) as an XDG desktop entry instead — a real, working,
but strictly worse fit for this repo's SSH-first, headless-friendly usage
— and then having to redo that work once the field's actual behavior came
to light.

**The lesson:** one YAML file can have more than one independent consumer
(`info.yaml` is read by both `lib/info-lib.sh` *and* `deploy.sh` here).
Before calling any field dead, grep the *whole* repo for its name, not
just the file that conventionally "should" own it — the same failure mode
as this doc's "grep for content, but also just `ls` the directory" entry
above, just one layer deeper (missing a consumer, not missing a
directory).

---

## A local commit isn't safely landed until its push is confirmed — external git activity can wipe it first

**What happened:** while fixing `mac-terminal-setup`'s custom-action
command, a commit was created on a freshly checked-out branch, but by the
time the next command ran, both the commit and its working-tree change had
vanished — the branch was back to matching `origin/master` exactly, edit
and all. `git reflog` showed an extra `reset: moving to origin/master`
sitting right after the branch's creation and the lost commit, with no
corresponding action taken by any command actually run in this session —
consistent with something else (the user's own terminal, or the IDE's
Source Control panel doing a sync/discard) touching the same working copy
on the same machine at the same time.

**The lesson:** a repo checked out on the same machine a human is actively
using (via their own terminal, or an IDE's git integration) isn't
exclusively under this session's control — a commit made here can be
silently reset away by something else before it's pushed, with no error
of its own to signal it happened. Don't treat `git commit` succeeding as
"the work is safe" when working alongside a live human session on the same
checkout; commit and push together (in the same breath, not as separate
steps with other work in between), and after any git operation that's
supposed to have landed something, a quick `git log --oneline -3` /
`git status` check confirms it actually did rather than assuming the
previous command's success carried through.

---

## Copied dotfiles can carry personal-identity content that doesn't belong in a reproducible environment

**What happened:** while turning a raw copy of a user's live Mac dotfiles
(`environments/mac-terminal-setup/`) into a reproducible `run.sh`, a
`.gitconfig` containing the user's real email had been dropped into the
source directory alongside the intended files — not something asked for,
just present because it came from the same live `~/`. The user caught it
and had it removed themselves ("accidentally added to directory, has my
email in it"). Separately, a `.screenrc` in the same directory turned out
to be dead config the user no longer used (they'd switched to tmux) and
was dropped from the deploy for that reason instead.

**The lesson:** when a task involves "make this raw folder of copied
dotfiles/config into a real thing," don't assume everything sitting in
that folder belongs in the output just because it's there — audit each
file for personal-identity content (`.gitconfig`, SSH config, credentials,
anything with an email/name/token baked in) and for whether it's actually
still in active use, rather than deploying the directory's contents
wholesale.

---

## Pushing more commits to an already-merged PR's branch does not get them into `master`

**What happened:** two follow-up commits (a `deploy.sh` keyboard-shortcut
fix, and moving `claude-cli`'s new-instance action into `custom_actions`)
were pushed to `claude/multiple-claude-cli-configs-9pw0ws` *after* that
branch's own PR had already merged, with `head.sha` frozen at an earlier
commit. Both commits sat on `origin` indefinitely, invisible to `master`
and to anyone pulling it — not because of a bug, just because a merged PR
is done, and pushing more to its branch doesn't reopen or re-merge it.
Diagnosed only by explicitly running `git merge-base --is-ancestor
<commit> origin/master` for each suspect commit, after the user reported
not seeing either change on their own machine.

**The lesson:** after any PR merges, check whether its branch is still a
valid place to keep committing — it isn't. The fix (already this repo's
own stated workflow, easy to forget mid-task) is to restart the branch
from the new `master` tip, rebase any not-yet-merged commits onto it, and
open a *new* PR — never keep pushing to a branch whose PR already shows
`merged: true`. Related to, but sharper than, this doc's "long-lived
feature branch can silently diverge" entry above: that one is about a
branch falling *behind* `master`; this one is about continuing to *commit*
to a branch that's already fully landed and closed.

---

## `check-updates.sh` flagged `nanoclaw`/`nanoclaw-mnemon`/`claude-cli` as having an update on nearly every scan

**What happened:** `check-updates.sh`'s `check_locally_built()` — built
for images with no upstream registry tag to `docker pull`-compare against
(darkstat, ntopng, dragonos-sdr, kali-pentest) — checks two things: has
the Dockerfile's own base image moved, and does `apt list --upgradable`
show anything. The base-image check was already correctly scoped to a
curated list (`_dockerfile_for_image()`), but the apt-upgradable check
wasn't gated on that list at all — it ran for *any* container with
`apt-get` present, mapped or not. `nanoclaw`/`nanoclaw-mnemon`'s
orchestrator images and `claude-cli`'s image (all `node:20-slim`-based,
also unpullable — locally built, no registry tag) have `apt-get` for a
handful of supporting packages (nanoclaw: git, curl, ca-certificates,
procps, iproute2, jq, ffmpeg; claude-cli: openssh-server, tmux, git,
curl, ca-certificates, procps, less, vim, gh), so all three fell into
that same unscoped check. Debian trickles a security patch into at least
one of curl/ca-certificates/git/openssh-server/gh often enough that this
flagged "UPDATE AVAILABLE" on very nearly every single scan — technically
true each time, but not a useful signal, since rebuilding any of these
images takes real time (nanoclaw's compiles whisper.cpp from source) over
what amounts to routine base-OS package churn nobody was asking to track.

**The lesson:** a two-part check with only one part actually scoped to
its documented, curated list is a silent scope-creep bug waiting for the
first unmapped-but-incidentally-matching image to trip it — here, "has
apt-get installed" turned out to be a much broader net than "is one of
the four images this feature was written for," and it caught a third,
unrelated environment (claude-cli) the same way once someone thought to
check. The fix (`_apt_upgrade_relevant()`, gating the apt-upgradable
check per-image rather than applying it to every apt-having container)
also needed a value judgment, not just a scoping fix: for
nanoclaw/nanoclaw-mnemon/claude-cli the apt packages are incidental
infrastructure, not the point of the image (unlike darkstat, where the
apt package *is* the whole image) — so the right call was excluding all
three from that specific check while still registering them in
`_dockerfile_for_image()` for the base-image-drift check, which stayed a
meaningful, low-noise signal for them. Don't assume a check's blast
radius matches its doc comment's stated scope; verify each individual
gate actually enforces that scope, not just the one that happens to be
checked first — and once a scoping bug like this is found in one place,
check every other environment sharing the same underlying shape (here:
locally-built, `node:20-slim`-based, apt-get present) rather than
assuming it was unique to the one that got reported.

---

## `check-updates.sh`'s base-image check still flagged `nanoclaw`/`nanoclaw-mnemon` right after a fresh rebuild

**What happened:** after the apt-upgradable fix above shipped,
`nanoclaw-mnemon` still showed "UPDATE AVAILABLE" on every scan — even
immediately following a real `CLEAN` rebuild, which should have left
nothing at all to flag. The remaining check
(`check_locally_built()`'s base-image-drift comparison) extracted the
Dockerfile's base image via `grep -m1 '^FROM' "$dockerfile"` — the
*first* `FROM` line. `nanoclaw`/`nanoclaw-mnemon`'s Dockerfiles are
multi-stage: `FROM docker:27-cli AS docker-cli` first (just to grab the
`docker` CLI binary via `COPY --from=docker-cli`), `FROM node:20-slim`
second — the actual base the final image is built on. `grep -m1` picked
`docker:27-cli` every time, whose layers are never part of the final
image's `RootFS.Layers` prefix at all (`COPY --from=` copies specific
files out of that stage, not its layers) — so the layer-prefix comparison
failed unconditionally, on every single scan, regardless of whether
`node:20-slim` had actually moved. Not a flaky check; a check that could
never once have passed for either environment.

**The lesson:** a fix verified against the *reported* symptom (apt
package noise, confirmed gone) doesn't mean the underlying feature is now
correct — the same function had a second, independent bug the whole
time, invisible until the first one stopped masking it. `grep -m1` for "a
Dockerfile's base image" is a single-stage assumption baked into the
pattern itself; it's silently wrong the moment any Dockerfile it's
pointed at goes multi-stage, and every other Dockerfile this repo tracks
here being single-stage (where first and last `FROM` are the same line)
meant nothing exposed the gap until an environment with an actual
multi-stage build got added to the tracked list. Fixed by taking the last
`FROM` line instead (`grep '^FROM' | tail -1`) — correct for both shapes,
not just multi-stage ones. When a user reports "still happening after I
just fixed the cause," don't assume the same root cause under-fired;
check whether there's a second, independent path to the same symptom.

---

## `check-updates.sh`'s `*nanoclaw*` pattern also caught NanoClaw's own dynamically-spawned agent containers

**What happened:** even after both fixes above, a container still showed
"UPDATE AVAILABLE — base image node:20-slim has moved" on every scan.
It wasn't `nanoclaw-mnemon` (which now correctly reported "up to date")
— it was `nanoclaw-agent-v2-91b144eb:ag-1783945827013-hhyk7w`, one of
NanoClaw's own per-conversation-group agent-sandbox containers (see that
environment's own notes: "NanoClaw manages its own Docker containers per
conversation group"). `_dockerfile_for_image()`'s `*nanoclaw*` pattern —
added to correctly match the fixed orchestrator image tags
(`nanoclaw-orchestrator:latest`, `nanoclaw-mnemon-orchestrator:latest`)
— also matched this agent container's own, unrelated, dynamically
generated image tag, and pointed it at this repo's orchestrator
Dockerfile: a file that has nothing to do with how the agent container
was actually built (that's NanoClaw's own `container/Dockerfile`, inside
the git-cloned, per-deployment install path, patched by
`apply_mnemon_patch`/`apply_media_tools_patch` — not a static path this
repo can ever correctly predict from just an image name). The two
Dockerfiles happening to share the same `node:20-slim` base is what made
this look plausible instead of obviously wrong — the check was comparing
the right base-image *string* against the wrong image's actual layers,
which is exactly as broken as comparing against the wrong string
entirely, just harder to spot.

**The lesson:** a substring pattern (`*nanoclaw*`) chosen to match a
*specific, fixed* set of tags (`IMAGE_TAG` in a couple of `run.sh`
files) can silently also match anything else that happens to share that
substring — including, in this case, an entire other category of
container (dynamically-named, NanoClaw's own, not this repo's to
Dockerfile-track at all) that nobody was thinking about when the pattern
was written. Two fixes to the same function's actual comparison logic
didn't surface this, because the bug wasn't in the comparison — it was
in deciding which containers the comparison should even run against.
Fixed by matching the exact tag prefixes (`nanoclaw-mnemon-orchestrator:*`,
`nanoclaw-orchestrator:*`) instead of a bare substring. When a match
pattern is meant to identify "this repo's own container X," prefer
matching what this repo's own code actually names it, not a substring
that's merely *usually* unique to it.

---

## `deploy.sh`'s own config form silently drops any `.env` var it doesn't manage — including ones set by a dedicated script

**What happened:** `nanoclaw-mnemon`'s new `CLAUDE_MODEL` (set via its own
"Choose Claude Model" picker) kept vanishing after an unrelated, routine
redeploy through `deploy.sh`'s menu — reported directly by a user testing
a live deploy, not caught by any of this repo's own review before
merging. Root cause: `deploy.sh`'s "ADVANCED BULK FORM COMPILER" — the
dialog form that runs on every menu-driven `FAST`/`CLEAN` — parses
`.env.example` line by line, and *every* line starting with `#` is
treated purely as documentation, including this repo's own established
convention of writing a commented-out optional variable as
`#SOME_VAR=default` (19 such lines existed across this repo's
environments already, e.g. `#GH_TOKEN=`, `#ANTHROPIC_BASE_URL=`, before
`CLAUDE_MODEL` added a 20th). Those never become form fields (`KEYS`),
and the form then does `> .env` (full truncate) followed by writing back
*only* the fields it collected — so any variable that was ever set in
`.env` but isn't an uncommented `.env.example` line gets silently dropped
on the very next form submission, regardless of whether the user touched
it, whether a dedicated script (`choose-model.sh`, claude-cli's
`point-to-gateway.sh`) had deliberately written it, or whether it changed
at all. This wasn't specific to `CLAUDE_MODEL` or even new — it's been
true of every commented-out `.env.example` variable in this repo since
the form itself was written, just never previously reported because
nothing had made a user's own redeploy-through-the-menu habit collide
with a value set outside that same form until now.

**The lesson:** a config form that reconstructs a file from scratch
(`> .env` then rewrite) needs to account for *every* way that file can
legitimately be written, not just its own input path — "this form is the
only thing that touches `.env`" was an unstated assumption that had
already been false for as long as any environment's `.env.example` had a
commented-out optional variable, since deploy.sh's own TUI form isn't the
only place `.env` gets edited (custom_actions scripts routinely do their
own targeted `sed` edits — see `choose-model.sh`,
`point-to-gateway.sh`/`revert-to-claude.sh`). Fixed by snapshotting any
`.env` key the form doesn't recognize as one of its own `KEYS` *before*
truncating, then re-appending those lines verbatim after the form's own
fields are written — preserves anything set outside the form without
changing what the form itself shows or asks for. Worth remembering for
any future "rebuild this file from a known set of fields" pattern: decide
explicitly whether unrecognized existing content should be dropped or
preserved, rather than letting a truncate-and-rewrite make that decision
by default.

---

## A container's writable layer looking "persistent" can just mean it was never recreated yet

**What happened:** `nanoclaw-mnemon`'s admin `claude` session (launched via
"Open a Claude Session," `docker exec`'d into `/root` with no volume of
its own) appeared to retain conversation history and environmental
context across a long period of use — reported directly by a user as
"it knew about its own environment, as it has previously." That was never
actually persisted anywhere: Claude Code writes conversation history under
`~/.claude/`, and for this container `~` is `/root`, which had no bind
mount or named volume at all — `run.sh`'s own `docker run` call only ever
mounted `$NANOCLAW_INSTALL_PATH`, the Docker socket, `/tmp`, and
`/etc/localtime`. The history had simply never been tested against an
actual container recreation before — once one happened (a `CLEAN`, or
"Choose Claude Model"'s own `docker stop`+`rm`+relaunch, added in the same
session that introduced the bug), the container's entire previous
writable layer was gone, and with it every trace of that history, with no
warning anywhere that this was even a risk. `claude-cli`, built earlier in
this repo's history, got this right from the start (a dedicated
`claude_cli_home` named volume) — the gap was specific to `nanoclaw-mnemon`
and plain `nanoclaw` container mode's own admin sessions never getting the
same treatment, not a general oversight in how this repo handles container
state.

**The lesson:** "this container's own state has survived every restart so
far" is not evidence that it's actually persisted — it's only evidence
that the container hasn't been *recreated* yet (a plain `docker
restart`/`stop`+`start` keeps the same writable layer; `rm`+a fresh `run`
does not). Before treating any path inside a container as safe to
accumulate real state in, check whether it's actually backed by a bind
mount or named volume — if it isn't, anything written there is one
`docker rm` away from being gone, and a feature that routinely recreates
the container (like a "change this setting" picker that has to, because
`docker run -e` only applies at creation) will eventually expose that gap
in production even if nothing looked wrong for a long time beforehand.
Fixed by adding a `${CONTAINER_NAME}_claude_home` named volume mounted at
`/root/.claude` in both `nanoclaw-mnemon`'s and plain `nanoclaw`'s
(container mode) `run.sh`, mirroring `claude-cli`'s own pattern — this
doesn't recover history already lost to a prior recreation, only prevents
the next one from doing the same thing. A regenerated-on-every-start
`/root/CLAUDE.md` (Claude Code's own standard project-context file, read
automatically from a session's launch directory) was added alongside it,
giving even a genuinely fresh session basic self-awareness of its own
environment independent of whether it has any history to draw on — worth
doing regardless of the volume fix, since a model's own self-report about
"do you know what container you're in" is otherwise entirely dependent on
memory that a first-ever session, by definition, doesn't have yet.

**Caught before merging, not after**: the first version of this fix only
covered `~/.claude/` (the directory), missing `~/.claude.json` — a
separate *file*, a sibling of `~/.claude/` rather than something inside
it, which Claude Code writes via an atomic temp-file-then-rename. A
directory-only volume does nothing to protect a file living outside that
directory. This is the exact same gap `claude-cli` had already hit and
fixed once before (its own `claude_cli_json` volume, distinct from
`claude_cli_home`) — worth remembering as its own pattern, not just a
one-off: "persist `~/.claude`" and "persist `~/.claude.json`" are two
separate fixes, both needed, and finding one doesn't mean the other has
been checked. A live `ls -al` of the actual container's `/root` (run by
the user reporting the original bug) is what surfaced this — checking
what's actually present beats reasoning from the fix already shipped for
a similar-looking case.

**Ultimately reverted, not shipped**: the `claude_home`/`claude_json`
volume pair was never actually requested — the reported bug was that a
*fresh* admin session had no self-awareness of its own environment (fixed
by the `CLAUDE.md` regeneration alone, no volume needed), and the user
had explicitly said losing conversation history on recreation was
acceptable. Adding persistent history on top was scope creep on this
session's part, and it's what led to a multi-round Docker volume-mount
failure investigation (see `docs/lessons-learned/nanoclaw-mnemon.md`'s
own entry) that ultimately traced to a genuine bug in OrbStack's Docker
reimplementation — not something fixable from this repo's side at all.
Once that became clear, the right call was to drop the unrequested
feature entirely rather than keep working around a third party's bug for
something nobody asked for. **Lesson**: "this would also be nice to fix
while I'm in here" is worth flagging to the user as a question, not
shipping unasked — especially for a persistence mechanism, where the
failure mode if it doesn't pan out is "breaks deployment entirely," a
strictly worse outcome than the (accepted) status quo it was meant to
improve on.

## `_yaml_expand()` hung on any value containing `&` (2026-08-06)

**Status:** fixed. Repo-wide — `lib/yaml-lib.sh`'s `_yaml_expand()` is the
shared `${VAR}`/`${VAR:-default}` substitution behind `info.yaml`,
`desktop-entries.yaml`, and every template rendered through them.

**Symptom:** a deploy hangs — no error, no output, no timeout — whenever a
substituted value contains an `&`.

**Root cause:** the substitution was
`result="${result//$expr/$val}"`. In bash 5.2+, an unquoted `&` in a
pattern-substitution *replacement* expands to whatever the pattern just
matched. So substituting a value containing `&` re-injected the literal
`${VAR}` marker back into the result; the enclosing `while [[ "$result" =~
... ]]` loop matched that marker again, substituted again, and never
terminated.

Hit for real by a template containing the shell snippet `2>&1`. It would
equally have hit any ordinary YAML value with an `&` in it — a URL with two
query parameters (`?a=1&b=2`), a label like "Fetch & transcribe" — none of
which look remotely like a shell-quoting hazard when you write them.

**Fix:** substitute by prefix/suffix splitting with a quoted pattern
instead:

```bash
prefix="${result%%"$expr"*}"
suffix="${result#*"$expr"}"
result="${prefix}${val}${suffix}"
```

Quoting `"$expr"` makes it literal (only the trailing/leading `*` stays a
wildcard), and the value is concatenated directly, so no character in it is
special. Each iteration resolves the first remaining marker; repeated
markers are picked up by later iterations, so the end result is unchanged.

Escaping the `&` (`\&`) was the other option, and was rejected: it works on
bash 5.2+ but relies on replacement backslash handling that differs on the
bash 3.2 macOS still ships, which this repo has to keep working.

### General Lessons

- **Bash pattern substitution has a replacement mini-language, and it grew
  a new member recently.** `${var//pat/repl}` is not a literal string
  splice: `&` in `repl` means "the matched text" as of bash 5.2, and
  backslash escapes it. Any code that builds `repl` from data — rather than
  from a literal in the script — has to account for that, and the safest
  answer is not to use pattern substitution for literal insertion at all.
- **A bug that only manifests as a hang is worse than one that manifests as
  a wrong answer,** because there is no output to inspect and nothing
  obviously failed. This one was found only because a new template happened
  to contain `2>&1`; it had been latent for as long as the function existed
  and could have been triggered by an ordinary URL in any environment's
  `info.yaml`.
- **A shared helper's edge cases are every caller's edge cases.** This is
  three lines in `lib/`, exercised by every environment in the repo. Worth
  a regression test at the value level (`&`, `*`, `[`, backslash, multi-line
  defaults) rather than trusting that whatever the current YAML files happen
  to contain is representative.

## `ollama-watchdog.sh` forced Ollama to bind loopback, via a variable-name collision (2026-08-07)

**Status:** fixed. Found while diagnosing why an operator's manual rebinding of
Ollama kept reverting.

`OLLAMA_HOST` means two different things depending on who reads it:

- to a **client** (this repo's watchdog, `environments/ollama/run.sh`, `curl`),
  it is the API base URL to talk to — `http://localhost:11434`;
- to **`ollama serve`**, it is the address to **bind**.

`ollama-watchdog.sh` used it in the first sense, and both its `--install` paths
exported that value into the scheduled job's environment (the launchd plist's
`EnvironmentVariables`, the cron line's inline assignment). Its
`restart_ollama()` then ran a bare `nohup ollama serve`, which **inherited it**
— so every watchdog-initiated restart bound Ollama to `http://localhost:11434`,
i.e. loopback.

Consequences, neither of which produced any error:

- Ollama became unreachable from every container on the host, since traffic via
  `host.docker.internal` arrives as external and a loopback listener refuses
  it. Host-side health checks kept passing, because they probe `localhost`.
- An operator who rebound Ollama by hand had it silently reverted on the
  watchdog's next tick — which is exactly how this was found: after a manual
  restart, `lsof` showed *two* `ollama` processes, one on `*:11434` (the
  operator's) and one on `127.0.0.1:11434` (the watchdog's), with the
  container still refused because it connects over IPv4 and the only IPv4
  listener was loopback.

**Fix:** `restart_ollama()` never passes its own probe URL to a server it
starts. It uses a new, separate `OLLAMA_SERVE_HOST` when the operator sets one,
and otherwise strips `OLLAMA_HOST` from the child environment entirely
(`env -u`) so Ollama falls back to its own default rather than to ours.
`OLLAMA_SERVE_HOST` is persisted into both the plist and the cron line so a
scheduled restart keeps the operator's binding. It defaults to unset — binding
`0.0.0.0` exposes Ollama to the local network, which is the operator's
decision to make.

### General Lessons

- **A variable named the same as a third-party tool's own variable is a
  hazard, not a convenience.** Reusing `OLLAMA_HOST` for "the URL I probe" read
  naturally everywhere it was used, and became a bug the moment the script
  spawned the very tool that reads it differently. If you must share the name,
  never let it cross into the child process.
- **Exported environment is an implicit argument to everything you spawn.**
  The plist and cron line were written to configure *the watchdog*; nothing
  signalled that they were also configuring a server it would later start.
  Scrub, or explicitly set, the environment of any long-lived process you
  launch.
- **A self-healing mechanism that reverts a correct manual fix is worse than
  no automation.** The watchdog exists to keep Ollama up, and it did — in a
  configuration that made it useless to the containers that needed it, while
  reporting success every cycle.
