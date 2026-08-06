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

**`ollama_available: false` while `curl` to the same URL succeeds — do not
guess at this one.** It has been misdiagnosed in both directions already
(once as cosmetic, once as `NO_PROXY` needing to contain
`host.docker.internal`, once as it needing to *not* contain it), and each
wrong answer looked entirely reasonable. curl succeeding is not evidence
that mnemon's request is taking the same route, because **curl and Go
disagree about which proxy variables they honor**:

- curl deliberately ignores the uppercase `HTTP_PROXY` for `http://` URLs
  (it would collide with the CGI `HTTP_*` header namespace); it honors only
  lowercase `http_proxy`. For `https://` it honors either case.
- Go's `net/http` proxy resolution honors both cases.

So on a container with `HTTP_PROXY` set but no lowercase `http_proxy`, curl
goes **direct** and mnemon goes **through the proxy** — same URL, same
environment, two different network paths, and only one of them working
tells you nothing about the other.

Settle it with one experiment before changing anything, run inside the
affected agent container:

```
env | grep -i proxy                                   # note the CASE of each var
curl -s -o /dev/null -w '%{http_code}\n' --noproxy '*' http://host.docker.internal:11434/api/tags
curl -s -o /dev/null -w '%{http_code}\n' --proxy "$HTTP_PROXY" http://host.docker.internal:11434/api/tags
```

- direct works, proxied fails → mnemon must bypass the proxy for this host,
  i.e. `NO_PROXY` **should** contain it, and the scheme-gating in item 2 is
  wrong for this platform.
- proxied works, direct fails → mnemon must use the proxy, the current
  gating is right, and the fault is elsewhere (check that
  `MNEMON_EMBED_ENDPOINT` is what mnemon actually reads, and that the proxy
  forwards to a non-`https` upstream at all).
- both work → the probe itself is the problem, not connectivity.

Record which of the three you got in `pi-bootstrap-patch-fixes.md`,
including the literal `env | grep -i proxy` output. That output is the
single piece of evidence every previous round was missing, and it is what
turns this from a fourth guess into a fix.
