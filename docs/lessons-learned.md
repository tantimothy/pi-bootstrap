# Lessons Learned

Cross-cutting things discovered the hard way while working on this repo —
kept separate from any single environment's README because they generalize
beyond it. Add to this file when something costs real debugging time and
would save it for the next person (or agent) who hits the same shape of
problem; don't add routine bug fixes here, those belong in the relevant
environment's own README/commit history.

---

## Don't trust a third-party tool's own docs over its live behavior inside your actual container

**What happened:** `nanoclaw-mnemon` patches `mnemon setup` into NanoClaw's
agent-sandbox `entrypoint.sh`. Two rounds of fixes, both reasoned from
mnemon's own README, were both wrong:

1. `mnemon setup --target claude-code --yes --global` — ran without
   erroring on every container start, but never actually registered hooks
   in a real group's `~/.claude/settings.json`.
2. Bare `mnemon setup --yes` (removing `--target`/`--global`, reasoned from
   mnemon's README showing no flags for its Claude Code integration
   specifically, unlike every other target it documents) — also wrong.
   Confirmed only by running it interactively inside a real agent-sandbox
   container: it auto-detects Claude Code correctly and *does* write
   hooks, but to a **project-local** `.claude/settings.json` relative to
   `entrypoint.sh`'s own working directory, not the **global**
   `~/.claude/settings.json` NanoClaw actually bind-mounts and Claude Code
   actually reads.
3. `mnemon setup --yes --global` — the actual fix, confirmed by testing,
   not by re-reading the docs a third time.

**The lesson:** when patching a third-party tool's invocation into a
container, a documented example that "looks like" your use case (same
target, same flags) can still be wrong for your specific working
directory/HOME/mount layout. Docs describe the common case; your
container's filesystem shape is what actually decides where a
relative-path side effect lands. Verify against the real, running
container — not the flag list in a README — before shipping a fix, and
say so explicitly in the commit/doc once you have (see
`environments/nanoclaw-mnemon/README.md`'s "Verified directly against a
real deploy" section for the pattern this repo uses to record that).

---

## "OpenAI-compatible" and "Anthropic-Messages-API-compatible" are different shapes — check which one you actually have

**What happened:** `llm-gateways` (LiteLLM, Portkey) exposes an
OpenAI-compatible `/v1/chat/completions`-style endpoint. Claude Code's own
`ANTHROPIC_BASE_URL` expects a server that speaks the **Anthropic Messages
API** shape instead — a different request/response format. The two are
easy to conflate because both are commonly described as "just point your
client's base URL at it," but that phrase means something different
depending on which client you're pointing.

**The lesson:** before wiring `ANTHROPIC_BASE_URL` at any self-hosted
gateway, confirm which API shape it's actually serving at that specific
route (some gateways expose both, on different paths) — don't assume
"OpenAI-compatible" implies "Claude-Code-compatible." See
`environments/claude-cli/.env.gateway.litellm`/`.env.gateway.portkey` and
`docs/future-enhancements/claude-cli-gateway-hardening.md` for the current,
still-open state of verifying this for real.

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
