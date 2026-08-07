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

If the status above reports **SKIPPED**, the upstream file or anchor this
patch depends on has moved. Apply it by hand from
<https://github.com/mnemon-dev/mnemon/blob/master/README.md#nanoclaw>.

**The pre-marker era (a STALE status).** Blocks written before this script
tracked patch versions carry no markers, and an unmarked block has no reliable
end boundary — so it cannot be replaced in place and is deliberately left
alone rather than mangled. Only a CLEAN clears it: CLEAN hard-resets
`container/Dockerfile` to upstream, after which this patch re-applies at the
current version. Until then the install keeps running whatever that old block
said, which is not necessarily what this document describes. This is a real
state, not a theoretical one — the content-blind "already applied?" check of
that era is why a fixed patch could report success for weeks while the image
kept building from stale text.

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
2. **`NO_PROXY` is scheme-gated, and it is not the thing you are looking
   for.** This patch emits `ENV NO_PROXY` / `ENV no_proxy` only when
   `MNEMON_EMBED_ENDPOINT` is an `https://` URL — where a proxy genuinely
   would interfere — and never for the `http://` default this environment
   ships. That gating is correct and should stay.

   What it is *not*: the cause of `ollama_available: false`. An earlier
   version of this document claimed it was, and that claim survived four
   rounds of changes in both directions. The real cause was Ollama bound
   to loopback (see the bind-address section below), which no proxy
   setting on either side could have fixed. If you are here because of
   `ollama_available: false`, check the bind address first and come back
   to this item only if that turns out to be fine.

   Worth knowing regardless: unlike the Ollama MCP patch, mnemon has no
   per-container-spawn re-assertion to correct a bad value later — this
   baked image-level ENV is the only value mnemon's Go HTTP client ever
   sees, so a wrong value here has no second chance to be overridden.
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

**`ollama_available: false` — this is almost never a mnemon problem.** It has
been misdiagnosed four times in both directions, and the cause each time was the
host Ollama daemon being bound to loopback, where no container can reach it.

Do not reach for `lsof` here: you are inside a container and cannot see the
host's listeners. The deploy records them for you — see the **Host Ollama
daemon** section at the end of this file, and use the container-side test given
there before concluding anything.

**If the bind address is fine and it still fails**, then and only then look
at routing — and do not guess, because this has already been misdiagnosed in
both directions (once as cosmetic, once as `NO_PROXY` needing to contain
`host.docker.internal`, once as it needing to *not* contain it). A container
can reach the same URL by two different paths, so `curl` succeeding proves
nothing about mnemon's request on its own: `curl` may be routing through a
host-side HTTP proxy that can see loopback, while mnemon's Go client goes
direct. That single fact accounted for the entire "curl works, Go doesn't"
signature that anchored four wrong rounds.

Run this in the affected agent container and record all three outputs:

```
env | grep -i proxy                                   # note the CASE of each var
curl -s -o /dev/null -w '%{http_code}\n' --noproxy '*' http://host.docker.internal:11434/api/tags
curl -s -o /dev/null -w '%{http_code}\n' --proxy "$HTTP_PROXY" http://host.docker.internal:11434/api/tags
```

- **direct refused, proxied 200** → the endpoint is not reachable without a
  proxy. On a default Ollama install that means the loopback bind above, not
  a proxy misconfiguration.
- **direct 200, proxied fails** → mnemon must bypass the proxy for this host,
  and the scheme-gating in item 2 would be wrong for this platform.
- **both work** → the probe itself is the problem, not connectivity.

Write which of the three you got into `pi-bootstrap-patch-fixes.md`, together
with the literal `env | grep -i proxy` output and the recorded listen address
from the **Host Ollama daemon** section. Those two together are what every
previous round was missing — and note the listen address comes from that
section, not from running `lsof` yourself, which you cannot do from in here.
