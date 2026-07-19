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
