# NanoClaw-Mnemon — Mnemon Hook Registration Lessons Learned

**Status:** retrospective. The fix below is merged (PRs
[#130](https://github.com/tantimothy/pi-bootstrap/pull/130),
[#131](https://github.com/tantimothy/pi-bootstrap/pull/131),
[#132](https://github.com/tantimothy/pi-bootstrap/pull/132),
[#133](https://github.com/tantimothy/pi-bootstrap/pull/133)) and confirmed
working against a real, live deploy — this document is the record of what
was tried, what was wrong about each attempt, and why.

## Summary

`run.sh`'s `apply_mnemon_patch()` patches a `mnemon setup` invocation into
NanoClaw's own agent-sandbox `container/entrypoint.sh`, run on every agent
container start, so mnemon's Claude Code hooks register automatically —
no manual `/add-mnemon` skill run needed. The patched command went through
two wrong versions, both reasoned from mnemon's own README, before a
third — verified against real, live container behavior instead — actually
worked.

## Issue Found & Fixed

### Mnemon's Claude Code hooks never actually registered in a real group

**Symptom:** The patch applied cleanly on every `CLEAN` deploy, and the
agent container started without error. But a real conversation group's
own `~/.claude/settings.json`, checked after real use, only ever showed
NanoClaw's own two built-in hooks (`PreCompact`, `SessionStart`) — never
any of mnemon's. Confirmed directly via `docker ps -a --filter
"name=nanoclaw-agent"` that agent containers are ephemeral (spawned fresh
per message, `--rm` on exit) — so there was no live container to `docker
exec` into and inspect after the fact; the only way to see what actually
happened was to reproduce the exact command manually inside a fresh
container.

**Attempt 1 — wrong:** `mnemon setup --target claude-code --yes --global`
(this environment's original patched invocation, matching mnemon's own
documented flags for explicitly targeting Claude Code). Ran without
erroring on every container start, but produced the symptom above.

**Attempt 2 — also wrong:** Bare `mnemon setup --yes`, with `--target`/
`--global` removed entirely. Reasoned from mnemon's own README, which
shows no `--target`/`--global` flags for its Claude Code integration
section specifically — unlike every other integration target it
documents (Codex, Cursor, TRAE, Nanobot, etc.), which all explicitly show
`--target <name>`. Looked like the more-correct reading of the docs.

Confirmed wrong the same way attempt 1 was confirmed wrong — but this
time by actually running `mnemon setup --yes` **interactively inside a
real agent-sandbox container** (`docker run --rm -it --entrypoint bash
...`) rather than just reasoning from the README a second time. It
printed `Settings .claude/settings.json updated` and exited successfully
— genuinely did *something* — but `cat ~/.claude/settings.json`
immediately after came back `No such file or directory`. The command had
auto-detected Claude Code correctly and written hooks to a
**project-local** `.claude/settings.json`, relative to `entrypoint.sh`'s
own working directory (`/workspace/group` in this image) — not the
**global** `~/.claude/settings.json` (`/home/node/.claude/settings.json`)
that NanoClaw actually bind-mounts per group from
`data/v2-sessions/<id>/.claude-shared`, and that Claude Code actually
reads at runtime.

**Attempt 3 — the actual fix:** `mnemon setup --yes --global` (auto-detect
kept, `--target claude-code` still omitted, `--global` added back).
Confirmed the same way, live inside the same container: `~/.claude/settings.json`
correctly received mnemon's hooks this time. Confirmed a second time,
independently, after a full `CLEAN` redeploy against a real Mac install —
a real group's `~/.claude/settings.json` came back with mnemon's hooks
present alongside NanoClaw's own two.

## General Lessons

- **A documented example that "looks like" your use case can still be
  wrong for your specific working directory.** mnemon's own docs never
  claim `mnemon setup --yes` writes to a *global* path — that assumption
  came from pattern-matching "no flags shown" to "no flags needed," not
  from anything the docs actually stated. The real, decisive fact (which
  working directory a relative-path side effect resolves against) isn't
  something a flag-reference table can show at all; it's a property of
  the specific container the command runs inside.
- **When a patched command "succeeds" (no error, expected log output),
  that doesn't mean it did what you think.** Both wrong attempts exited
  cleanly and mnemon even printed a plausible-looking success message on
  attempt 2 — the failure was entirely in *where* the side effect landed,
  invisible to exit codes or stdout alone. Only checking the actual
  resulting file, inside the actual container, caught it.
- **Verify against the real, running container — not the flag list in a
  README — before shipping a fix, and say so explicitly once you have.**
  See `environments/nanoclaw-mnemon/README.md`'s "Verified directly
  against a real deploy" section for the pattern this repo uses to record
  that distinction (tested-and-confirmed vs. reasoned-from-docs) for every
  claim, not just this one.
- Once the root cause was fixed for *new* container spawns, groups whose
  `.claude-shared` directory had already been written by a broken version
  needed separate remediation — a rebuilt image alone doesn't retroactively
  fix already-existing host-side data. `scripts/reload-mnemon.sh` re-runs
  the corrected command directly against a specific group's real,
  persistent directory, with no chat round-trip (and therefore no need to
  wait for that group's next real message to spawn a fresh container)
  needed. Its own group-selection UX went through one more round of
  feedback-driven refinement after initially requiring the group's raw
  `ag-<timestamp>-<hash>` session ID by hand — it now auto-discovers real
  group names from NanoClaw's own `data/v2.db`, auto-picking if there's
  only one or prompting with a numbered list otherwise.

## Related PRs

- [#130](https://github.com/tantimothy/pi-bootstrap/pull/130) — attempt 2
  (bare `mnemon setup --yes`) — merged, later found to be a regression
- [#131](https://github.com/tantimothy/pi-bootstrap/pull/131) — attempt 3,
  the actual fix (`mnemon setup --yes --global`), plus the honest
  "two corrections" writeup in the README
- [#132](https://github.com/tantimothy/pi-bootstrap/pull/132) —
  `scripts/reload-mnemon.sh`, remediation for groups already affected by
  the earlier broken versions
- [#133](https://github.com/tantimothy/pi-bootstrap/pull/133) —
  `reload-mnemon.sh`'s group auto-discovery, replacing the manual-ID-required
  UX
