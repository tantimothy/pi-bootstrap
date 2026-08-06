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

### 5. Live-verify the admin-session tmux wrapper and `CLAUDE_MODEL` — done, see "Update" below

`scripts/claude-tmux.sh` (grouped-session `docker exec` wrapper for "Open a
Claude Session") and `CLAUDE_MODEL` passthrough via `docker run -e` were
originally written and syntax-checked (`bash -n`/`sh -n`) but not
exercised against a real deploy. The first real deploy surfaced two real
bugs in this exact mechanism (see "Update" below) — both now fixed, and
the single-connection path (open a session, get a working `claude` on
the right model) is confirmed live. Still not live-confirmed: two
*simultaneous* `docker exec -it ... nanoclaw-claude-tmux.sh` connections
actually landing on independent tmux windows sharing one conversation,
as the grouped-session design intends. Same mechanism, same fixes, in
the plain `nanoclaw` environment too (see
`docs/future-enhancements/nanoclaw.md`).

**Update — resolved.** The first real deploy surfaced several real bugs
across multiple rounds; all are now fixed and confirmed live on a real
deploy:

- **`deploy.sh`'s own config form was silently dropping `CLAUDE_MODEL`**
  on the next menu-driven redeploy after "Choose Claude Model" set it —
  see `docs/lessons-learned/general.md`'s "`deploy.sh`'s own config form
  silently drops any `.env` var it doesn't manage" for the full account.
  Fixed in `deploy.sh` itself (repo-wide, not specific to this
  environment).
- **A fresh admin session had no self-awareness of its own environment**
  — see `docs/lessons-learned/general.md`'s "A container's writable layer
  looking 'persistent' can just mean it was never recreated yet." Fixed
  with a regenerated-on-every-start `/root/CLAUDE.md`
  (`scripts/entrypoint.sh`). A separate attempt at also persisting this
  session's conversation *history* across recreation (a
  `${CONTAINER_NAME}_claude_home` named volume) was tried and then
  reverted — never actually requested (losing history was explicitly
  said to be acceptable), and it ran into a genuine OrbStack Docker-
  implementation bug that made deployment fail outright rather than just
  losing history gracefully. See `docs/lessons-learned/nanoclaw-mnemon.md`'s
  own entry for the full three-round investigation, and
  `docs/lessons-learned/general.md`'s "Ultimately reverted, not shipped"
  addendum.
- **Root-caused and fixed: a freshly-picked `CLAUDE_MODEL` didn't take
  effect, and "Open a Claude Session" opened plain `bash` instead of
  `claude`.** Both traced to the same bug: the grouped-session tmux
  pattern's own "is this the first connection ever" check never actually
  fired the way it assumed (`tmux new-session -t claude -s ...` silently
  creates the group instead of failing when it doesn't exist yet), so
  `claude`/`--continue`/`--model` never ran at all on a truly fresh tmux
  server — a plain shell was left running instead, which is what the
  free-text "which model are you" self-report was actually talking to. A
  second bug (`claude --continue` exiting outright when there's nothing
  to resume, rather than degrading to a fresh conversation) surfaced
  immediately after the first fix and was fixed the same way. See
  `docs/lessons-learned/nanoclaw-mnemon.md`'s own two entries for the full
  investigation — both confirmed live: a real "Open a Claude Session"
  now launches `claude` with the currently-configured model on a fresh
  container, and stays open.
- **Changing a *Telegram/Discord group's* own model is a separate
  concern from any of the above** — `CLAUDE_MODEL`/"Choose Claude Model"
  only ever controls the admin session; NanoClaw's own per-group model is
  set via `ncl groups config update --id <group-id> --model <model>` +
  `ncl groups restart --id <group-id>` (run from inside the container,
  `cd`'d into `$NANOCLAW_INSTALL_PATH`, via `pnpm ncl ...` since it's not
  a global binary there). See `docs/lessons-learned/nanoclaw-mnemon.md`'s
  own entry for the full writeup — confirmed live, including that the
  group's own self-report of its model can be just as stale/unreliable as
  the admin session's, so check `ncl groups config get` directly rather
  than trusting it.

### 6. `apply_ollama_tool_patch()` — verified against a source snapshot, not yet a live end-to-end deploy

Every `grep -n` anchor `apply_ollama_tool_patch()` depends on (in
`container/agent-runner/src/index.ts`, `src/config.ts`,
`src/container-runner.ts`) was confirmed to match a real, working user's
already-patched NanoClaw checkout exactly, and the splice output it
generates was confirmed byte-identical to that checkout's own
already-applied equivalent sections. What has **not** yet been directly
exercised in this repo's own workflow: a fresh deploy actually running
`apply_ollama_tool_patch()` end-to-end against a truly stock (unpatched)
NanoClaw clone, a container rebuild picking up the patched
`container/agent-runner/src/*`, and a live `ollama_list_models` call
succeeding from inside a spawned agent container. Check
`$NANOCLAW_INSTALL_PATH/.pi-bootstrap-patches.md` inside a deployed
container after the next real deploy for this patch's actual
PASSED/SKIPPED/FAILED status — see
`docs/lessons-learned/nanoclaw-mnemon.md`'s own entry for the full design.

**Update:** there's now a defined path for the live `ollama_list_models`
check specifically (and the equivalent live `mnemon embed --status` check)
to actually happen, even though pi-bootstrap's own host-side tooling still
can't run it directly — `entrypoint.sh`'s `/root/CLAUDE.md` now gives the
admin `claude` session a standing instruction to run a smoke-test checklist
covering exactly this the first time it connects after a TEARDOWN/CLEAN
reset, writing results to `.pi-bootstrap-smoke-test.md`. That still hasn't
been exercised against a real deploy either — it's a mechanism for getting
this verified by the admin session live, not a substitute for someone
actually doing it once and confirming the mechanism itself works as
designed.

## Refactoring Opportunities

See `docs/refactoring-opportunities.md`'s "yt-dlp's arch-detection
`case` block is duplicated across three files" entry — kept there rather
than duplicated here, since that file is this repo's single shared home
for refactoring opportunities across all environments.
