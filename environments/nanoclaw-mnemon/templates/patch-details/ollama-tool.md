**What this patch is for.** It registers an MCP server exposing a locally
running Ollama to every per-group agent container — `ollama_list_models`,
`ollama_generate`, plus admin tools (pull/delete a model) gated behind
`OLLAMA_ADMIN_TOOLS`. This is the same thing NanoClaw's own
`/add-ollama-tool` skill does, applied automatically on every deploy
instead of by hand, and with one bug already fixed in it (see below). It is
applied on both the `mnemon` and `plain` profiles — it is a general agent
capability, not a mnemon feature.

**Files it changes, and where.**

| File | How | Anchor |
|---|---|---|
| `container/agent-runner/src/ollama-mcp-stdio.ts` | created if missing, never overwritten | — |
| `container/agent-runner/src/index.ts` | spliced | `args: ['run', mcpServerPath],` |
| `src/config.ts` | spliced, twice | the `readEnvFile([...])` key list, then the export block |
| `src/ollama-env.ts` | created if missing, never overwritten | — |
| `src/container-runner.ts` | spliced, twice | the import block, then `buildContainerArgs()` |

The two files this patch *creates* are only ever filled in when missing —
they are never overwritten. So if you hand-fix either one inside the
container, your fix survives every later deploy, including CLEAN. The three
files it *splices into* use marker-based idempotency and are re-applied
after each CLEAN reset.

**The shape a correct fix has to have.**

1. **`config.ts` is not optional, and this is the bug the upstream skill
   ships with.** The skill's own `ollama-env.ts` reads
   `process.env.OLLAMA_HOST` / `process.env.OLLAMA_ADMIN_TOOLS` directly.
   NanoClaw does not populate `process.env` from `.env` — it loads its
   config through its own `readEnvFile()`. So on a stock skill install
   those values are always undefined no matter what `.env` says. The fix is
   to add `OLLAMA_HOST`, `OLLAMA_ADMIN_TOOLS` and `OLLAMA_NO_PROXY_OVERRIDE`
   to `readEnvFile([...])` and export them exactly the way every other
   config value in that file is exported. If you are re-deriving this patch
   by re-running the skill, you will reintroduce this bug.
2. **`NO_PROXY` is deliberately re-asserted at container-spawn time.** Not
   redundant insurance — it specifically defends against *this repo's own*
   mnemon patch, which bakes an `ENV NO_PROXY` into the agent-sandbox
   image. `docker run -e` wins over a Dockerfile `ENV`, so re-asserting the
   correct value in `ollamaEnvArgs()` is what actually governs. The value
   must **not** contain `host.docker.internal`: on this platform that
   address is reachable only because `HTTPS_PROXY` routes it through the
   platform gateway, and excluding it from proxying breaks the connection
   outright. Override with `OLLAMA_NO_PROXY_OVERRIDE` in `.env` if the
   gateway address differs on your host.
3. **Nothing downstream overrides it.** `onecli.applyContainerConfig()`
   runs after `ollamaEnvArgs()` in `container-runner.ts`, so it would win on
   any key it also sets — it was checked directly against the SDK source
   and it only pushes `HTTPS_PROXY`/`HTTP_PROXY` (plus lowercase),
   `NODE_EXTRA_CA_CERTS`, `NODE_USE_ENV_PROXY`, `GIT_*` and
   `CLAUDE_CODE_OAUTH_TOKEN`. There is no `NO_PROXY` entry, so there is no
   collision. If that ever changes upstream, this is the first thing to
   re-check.

**How to check whether it is actually working.** From a live agent
container (this needs a real conversation group — on a genuinely fresh
install with no channel paired yet, there is no agent container to test in,
and that is a normal state, not a failure):

```
env | grep -i -E 'ollama|no_proxy'
curl -s "$OLLAMA_HOST/api/tags"        # does the endpoint answer at all
```

and from the agent itself, call `ollama_list_models`. If `curl` works but
the tool does not, the problem is the MCP registration in `index.ts`, not
connectivity. If neither works, look at `NO_PROXY` first.

Upstream skill reference:
https://github.com/nanocoai/nanoclaw/blob/main/.claude/skills/add-ollama-tool/SKILL.md
