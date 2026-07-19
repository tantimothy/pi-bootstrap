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

## Refactoring Opportunities

See `docs/refactoring-opportunities.md`'s "yt-dlp's arch-detection
`case` block is duplicated across three files" entry — kept there rather
than duplicated here, since that file is this repo's single shared home
for refactoring opportunities across all environments.
