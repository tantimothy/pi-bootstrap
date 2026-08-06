**What this patch is for.** Stock NanoClaw has no persistent memory — an
agent starts every conversation with nothing carried over. This patch
installs [mnemon](https://github.com/mnemon-dev/mnemon) into the
agent-sandbox image and registers its Claude Code hooks, so each group's
agent accumulates a graph (and, optionally, vector) memory across
conversations. It follows NanoClaw's own `add-mnemon` skill
(`.claude/skills/add-mnemon/SKILL.md`), not an invented mechanism.

**Files it changes, and where.**

| File | Anchor it splices at | What it adds |
|---|---|---|
| `container/Dockerfile` | the line `# ---- Bun runtime` | `ARG MNEMON_VERSION`, a `RUN` that downloads the arch-matched mnemon release tarball into `/usr/local/bin/mnemon`, `ENV MNEMON_DATA_DIR=/home/node/.claude/mnemon`, and the optional embedding ENVs below |
| `container/entrypoint.sh` | the first line that is exactly `set -e` | one line: `mnemon setup --yes --global >/dev/stderr 2>&1` |

Both edits sit inside `# >>> pi-bootstrap:mnemon vN >>>` / `# <<< pi-bootstrap:mnemon <<<`
markers in the Dockerfile. If you hand-edit inside those markers, your edit
survives until the next CLEAN (which hard-resets the file to upstream and
re-applies this patch) — a FAST deploy will leave it alone as long as the
version number still matches.

**The shape a correct fix has to have** — the three things that have each
been gotten wrong at least once here, so check these first:

1. **`mnemon setup` needs `--global`.** Bare `mnemon setup --yes` runs
   fine, exits 0, and auto-detects Claude Code correctly — but it writes
   its hooks to a *project-local* `.claude/settings.json` relative to
   entrypoint.sh's working directory (`/workspace/group`). NanoClaw
   bind-mounts and Claude Code reads the *global* `/home/node/.claude/`.
   So the command succeeds and the hooks still never load. `--global`
   is what targets `~/.claude/settings.json`. Do not "fix" this by adding
   `--target claude-code` — auto-detection was never the failing part.
2. **`NO_PROXY` must not contain `host.docker.internal`.** On the platform
   this environment is usually deployed to, `host.docker.internal:11434`
   is *not* a direct socket — it is reachable only because `HTTPS_PROXY`
   routes it through the platform's own gateway. Putting
   `host.docker.internal` in `NO_PROXY` bypasses that routing and the
   connection fails outright. This patch therefore emits `ENV NO_PROXY` /
   `ENV no_proxy` **only** when `MNEMON_EMBED_ENDPOINT` is an `https://`
   URL (where a proxy genuinely would interfere), and never for the
   `http://` default this environment ships. An earlier version emitted it
   unconditionally "as a harmless no-op" — that was the direct cause of
   `ollama_available: false`. Unlike the Ollama MCP patch, mnemon has no
   per-container-spawn re-assertion to correct a bad value later; this
   baked image-level ENV is the only value mnemon's Go HTTP client ever
   sees.
3. **It is an image-level ENV, so it only changes when the image is
   rebuilt.** Editing `container/Dockerfile` alone changes nothing that is
   running. The image has to be rebuilt (`container/build.sh`) *and* the
   agent containers spawned from the old image have to be replaced.

**How to check whether it is actually working**, from inside a live agent
container (not from the orchestrator, and not by asking the agent):

```
mnemon --version                       # binary present at all
mnemon embed --status                  # embedding backend reachability
cat /home/node/.claude/settings.json   # hooks registered GLOBALLY, not in /workspace/group
env | grep -i -E 'mnemon|no_proxy'     # what the image actually baked in
```

If `mnemon embed --status` reports the endpoint unreachable while `curl`
to the same URL from the same container works, suspect item 2 above and
look at `NO_PROXY`/`no_proxy` first — the two clients disagree precisely
because Go's proxy handling and curl's are configured by the same env vars
but consulted differently.
