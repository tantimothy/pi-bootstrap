# NanoClaw-Mnemon Environment — Future Enhancements & Refactoring Opportunities

**Status:** ideas only — none of this is implemented. Captured after the
yt-dlp/python3 incident (see `docs/lessons-learned/nanoclaw-mnemon.md`'s
"yt-dlp / python3 Dependency Chain" section for the full account) surfaced
several gaps beyond the immediate bug fixes; these are the follow-ups worth
doing deliberately rather than reactively.

## Future Enhancements

### 1. CI build + smoke-test validation for this environment's Dockerfiles

Both wrong-yt-dlp-asset bugs (orchestrator `Dockerfile` and the
agent-sandbox patch text in `run.sh`) would have been caught by an
automated `docker build` plus a trivial runtime check (`docker run --rm
<image> yt-dlp --version`) on any PR touching either — a `docker build`
alone wouldn't have caught it, since the broken asset still downloads and
installs cleanly; only actually *running* it surfaces the missing
`python3`. Mirrors `docs/future-enhancements/claude-cli.md`'s identical
CI-build idea for that environment — worth building once, generalized
across every Docker-based environment in this repo, rather than per
environment.

### 2. Apply `lib/locale-lib.sh` sourcing to every other environment's `run.sh`

Confirmed missing from every environment's `run.sh` in this repo, not just
this one (see the lessons-learned entry) — only `deploy.sh` and the other
top-level entry scripts source it today. Anyone invoking an environment's
`run.sh` directly, bypassing `deploy.sh`'s menu, hits the same raw
hex-byte-escape garbling this environment did. The fix is the same
one-line `source ".../lib/locale-lib.sh" || true` added here, just needs
repeating in each environment's `run.sh` — not done repo-wide yet since it
wasn't reproduced against those other environments in this session.

### 3. Surface the `/workspace/agent` persistence rule to agents proactively, not just in the README

Two separate agents, independently, lost self-installed tools (yt-dlp's
rootless workaround; whisper.cpp's libs/model) by installing them outside
`/workspace/agent` — the only bind-mounted, persistent path inside an
agent's own container. Both times this was only discovered after the
data was already gone. A `CLAUDE.md`/system-prompt note baked into the
agent-sandbox image itself (rather than a README section a human reads,
not the agent) — e.g. "anything you install that you want to survive a
container respawn must live under `/workspace/agent`, not your home
directory or anywhere else" — would let an agent avoid this class of
mistake before hitting it, rather than after.

### 4. A post-`CLEAN` smoke test that actually exercises `yt-dlp`/`whisper-cli` inside the rebuilt agent-sandbox image

Right now, "the agent-sandbox image was rebuilt" is inferred from build
logs and `docker images` timestamps — nothing in `run.sh` itself confirms
the tools it just patched in actually work. A one-line `docker run --rm
<image> yt-dlp --version && whisper-cli --help` right after
`container/build.sh` completes would have caught issue #1 in the
lessons-learned doc immediately, at build time, instead of requiring a
live agent to hit the failure days later.

### 5. Live-verify the admin-session tmux wrapper and `CLAUDE_MODEL`

`scripts/claude-tmux.sh` (grouped-session `docker exec` wrapper for "Open a
Claude Session") and `CLAUDE_MODEL` passthrough via `docker run -e` were
written and syntax-checked (`bash -n`/`sh -n`) but not exercised against a
real deploy — no live confirmation that two simultaneous `docker exec -it
... nanoclaw-claude-tmux.sh` invocations actually land on independent tmux
windows sharing one `claude --continue` conversation, and no live
confirmation that `scripts/choose-model.sh`'s container recreation actually
carries the new `CLAUDE_MODEL` value through to the next session. Confirm
both on the first real deploy after this change. Same caveat applies to the
identical mechanism in the plain `nanoclaw` environment (see
`docs/future-enhancements/nanoclaw.md`).

**Update — first real deploy already surfaced three real bugs, two now
fixed, one still open:**

- **`deploy.sh`'s own config form was silently dropping `CLAUDE_MODEL`**
  on the next menu-driven redeploy after "Choose Claude Model" set it —
  see `docs/lessons-learned/general.md`'s "`deploy.sh`'s own config form
  silently drops any `.env` var it doesn't manage" for the full account.
  Fixed in `deploy.sh` itself (repo-wide, not specific to this
  environment) — still needs a live confirmation that a real "Choose
  Claude Model" → later menu-driven `FAST`/`CLEAN` sequence now actually
  preserves the value.
- **The admin session's own history/OAuth state was never actually
  persisted** — see `docs/lessons-learned/general.md`'s "A container's
  writable layer looking 'persistent' can just mean it was never
  recreated yet." Fixed by adding a `${CONTAINER_NAME}_claude_home` named
  volume (`run.sh`) and a regenerated-on-every-start `/root/CLAUDE.md`
  (`scripts/entrypoint.sh`) — needs a live confirmation that a
  `CLEAN`/recreate now actually survives with the volume in place, and
  that a brand-new session (no history) correctly reports basic
  environment facts from the generated `CLAUDE.md`.
- **Still open, not yet root-caused**: a live report that a freshly-picked
  `CLAUDE_MODEL` (e.g. `claude-sonnet-4-6`) didn't take effect — the
  session still self-reported as Sonnet 5. Leading hypothesis: the base
  tmux `claude` session was already running from before the model change
  (grouping onto an existing session doesn't relaunch `claude` with new
  flags — see `claude-tmux.sh`'s own comment), not a bug in the
  `CLAUDE_MODEL` plumbing itself, but this hasn't been confirmed against
  `docker exec ... env | grep CLAUDE_MODEL` / `docker exec ... tmux
  list-sessions` output yet. Also worth remembering generally: a model's
  own free-text answer to "which model are you" is not a reliable way to
  check this — `/status` inside the session, or the two `docker exec`
  checks above from the host, are.

## Refactoring Opportunities

See `docs/refactoring-opportunities.md`'s "yt-dlp's arch-detection
`case` block is duplicated across three files" entry — kept there rather
than duplicated here, since that file is this repo's single shared home
for refactoring opportunities across all environments.
