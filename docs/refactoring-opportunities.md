# Refactoring Opportunities

Known, real duplication or rough edges noticed while working on this repo,
deliberately **not** acted on yet — either because the duplication is still
small enough that extracting a shared helper would cost more than it
saves right now, or because it needs one more real use case before the
right abstraction is obvious. Listed here instead of silently ignored, so
the next person touching this code doesn't have to rediscover it, and so
"should I extract this" has an answer ready the next time a third instance
shows up. Remove an entry once it's actually acted on (or once you decide,
with reasoning, that it never will be — don't leave stale entries).

---

## `claude-cli`'s gateway scripts share real logic

`environments/claude-cli/scripts/point-to-gateway.sh` and
`scripts/revert-to-claude.sh` both independently: locate `ENV_DIR`/`.env`,
resolve `CONTAINER_NAME` (with the same `claude-cli` fallback), run
`docker compose up -d` to restart, and print the same "any live tmux
session ended, SSH back in and `--continue` resumes it" closing message.

**Why not extracted now:** two call sites, both short scripts, and the
shared logic is a handful of lines each — a `lib/claude-cli-gateway-lib.sh`
today would be more indirection than the duplication it removes.

**Revisit when:** a third script needs the same restart-and-report
pattern (e.g. if `docs/future-enhancements/claude-cli-gateway-hardening.md`'s
"new gateway wizard" idea gets built) — at that point extract a shared
`_restart_claude_cli()` / `_resolve_container_name()` pair into a small
environment-local lib, following the same pattern
`environments/claude-cli/new-instance.sh` already uses for `deploy_lib.sh`.

---

## Three independent "auto-discover, else prompt with a numbered list, else fall back to a raw listing" implementations

The same interaction shape shows up, written from scratch each time, in:

- `environments/nanoclaw-mnemon/scripts/reload-mnemon.sh` — auto-discovers
  NanoClaw conversation groups from `data/v2.db`'s `agent_groups` table.
- `environments/claude-cli/new-instance.sh`'s `_suggest_port()` — scans
  sibling instances' `.env` files for already-claimed `SSH_PORT`s.
- `environments/claude-cli/scripts/point-to-gateway.sh` — picks a gateway
  from whichever `.env.gateway.*` files exist.

Each does: try to find candidates programmatically; if exactly one, use it
silently; if more than one, print a numbered menu and `read -rp` a choice;
if discovery itself fails, fall back to a raw directory/file listing with
a usage message.

**Why not extracted now:** each environment's scripts are deliberately
self-contained in this repo (no shared cross-environment lib exists
today for anything beyond `lib/deploy-lib.sh`/`lib/desktop-lib.sh`-style
core plumbing that `deploy.sh` itself depends on) — introducing a
general-purpose `lib/picker-lib.sh` for three ~15-line call sites, each
with slightly different data sources (SQLite query vs. `.env` grep vs.
`ls` glob), would add a layer of indirection for not much real
duplication removed. Bash 3.2 compatibility (no associative arrays, see
each script's own comments) also means the shared version would need the
same parallel-array-with-`while read` shape every call site already uses,
so there's less to actually gain by centralizing it than in a language
with real structs/maps.

**Revisit when:** a fourth environment needs this same shape *and* the
data-source variance stays low (e.g. multiple SQLite-backed pickers) — at
that point a shared helper taking a pre-built name/id array is worth it;
until then, matching each script to its own data source directly is
simpler to read.

---

## `backup.sh`'s `is_deployed()` is a manually-maintained `case` statement

Every environment needs its own `case` arm in the root `backup.sh` (see
the main `README.md`'s "Registering with `backup.sh`" section) — there's
no way to discover "is this actually deployed" automatically the way
`info.yaml`/`desktop-entries.yaml` are auto-discovered per-directory.
Forgetting to add an environment here silently falls through to `*) true
;;` (always treated as deployed) rather than failing loudly.

**Why not fixed now:** genuinely out of scope for anything touched this
session — noted here only because it's a real, pre-existing rough edge
matching the same "manually-maintained per-environment registration"
shape as `config/environments.yaml` (which at least has a documented
fallback: an unlisted environment still shows up, just unsorted — see
`config/environments.yaml`'s own header comment). `is_deployed()` has no
equivalent safety net; a forgotten `case` arm is silently wrong rather
than silently disorganized.

**Revisit when:** someone's specifically working on `backup.sh` — a
reasonable fix would be deriving a default check from `docker-compose.yml`'s
own `container_name:`/service list when no explicit `case` arm exists,
falling back to `*) true ;;` only when that can't be determined either.
Not attempted here since it's unrelated to any of this session's actual
tasks.
