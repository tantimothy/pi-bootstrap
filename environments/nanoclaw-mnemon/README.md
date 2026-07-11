# NanoClaw + Mnemon — Persistent Memory AI Assistant

The same self-hosted [NanoClaw](https://github.com/nanocoai/nanoclaw) AI assistant as the plain `nanoclaw` environment, with [mnemon](https://github.com/mnemon-dev/mnemon) — a real, independent, third-party persistent-memory tool — patched into NanoClaw's own per-conversation-group agent sandbox for cross-session graph memory.

**Fully independent of the plain `nanoclaw` environment**: its own install path, its own container name, its own port. Both can be deployed on the same machine without colliding. The plain `nanoclaw` environment is intentionally left untouched by this one — see "Coexistence" below.

**Credit**: this environment follows the architecture described in a public gist by GitHub user [VivianBalakrishnan](https://gist.github.com/VivianBalakrishnan/a7d4eec3833baee4971a0ee54b08f322), whose actual pipeline (re-verified against the gist's own text, not a paraphrase) is **raw sources → mnemon → wiki**, in that order: mnemon extracts discrete facts from raw sources and retrieves them via local embeddings (Ollama + `nomic-embed-text`) at query time, and the wiki is a synthesis of mnemon's facts into human-readable pages — Obsidian is just how the author reads that wiki, plus a personal iCloud/`rsync` sync bridge on top. This environment implements the NanoClaw+mnemon portion — the exact steps documented in NanoClaw's own [`.claude/skills/add-mnemon/SKILL.md`](https://github.com/nanocoai/nanoclaw/blob/main/.claude/skills/add-mnemon/SKILL.md) and [mnemon's own README](https://github.com/mnemon-dev/mnemon/blob/master/README.md#nanoclaw). **Correction from an earlier version of this README**: that embeddings piece is not custom work by the gist's author — it's a built-in, optional feature of the stock `mnemon` binary itself (`MNEMON_EMBED_ENDPOINT`/`MNEMON_EMBED_MODEL`, defaulting to `nomic-embed-text`), just not yet turned on by this environment's `apply_mnemon_patch()` (see `GIST-PARITY.md` for exactly what's missing — one env var). It also optionally scaffolds NanoClaw's own [`/add-karpathy-llm-wiki`](https://github.com/nanocoai/nanoclaw/blob/main/.claude/skills/add-karpathy-llm-wiki/SKILL.md) skill for the wiki layer — see "Optional: Karpathy LLM Wiki" below. **See [`GIST-PARITY.md`](./GIST-PARITY.md) for the full gap analysis** — what's built and verified here, what's still missing, and exactly what each remaining piece needs. **See [`MANUAL-STEPS.md`](./MANUAL-STEPS.md)** if you'd rather not use this environment's automation — it's the exact same result (starting from a plain `nanoclaw` deploy), spelled out by hand.

---

## How It Works

Identical to the plain `nanoclaw` environment's architecture — a host-level orchestrator (containerized here) spawns an isolated Docker container per conversation group. The only difference: each group's agent container also runs `mnemon`, a single Go binary providing persistent, cross-session graph memory (temporal/entity/causal/semantic graphs), supervised by the agent's own Claude Code session rather than embedding its own LLM.

```
Messaging apps → orchestrator (router) → agent container (Claude Agent SDK + mnemon) → orchestrator (delivery) → messaging apps
```

Mnemon's `remember`/`link`/`recall` primitives are invoked automatically via Claude Code hooks (`SessionStart`, `UserPromptSubmit`, `Stop`) that `mnemon setup` registers inside each agent container — the agent doesn't need to be told to use it.

---

## 🔒 Deployment Modes

**Container mode only.** Unlike the plain `nanoclaw` environment, there's no host/systemd/launchd mode here — this environment exists specifically for the Mac-first, filesystem-sandboxed use case, so there's no second mode to keep in sync with the mnemon patch. See the plain `nanoclaw` environment's README for the full host-vs-container tradeoff (iMessage support, filesystem access scope) if you want that instead.

---

## ⚙️ Why This Needs a Custom `run.sh`

Same reasons as the plain `nanoclaw` environment (`deploy.sh`'s generic fallback has no concept of Docker-outside-of-Docker, interactive setup wizards, or dynamically-spawned per-group containers — see that environment's README for the full breakdown), plus one more specific to this environment:

- **Idempotent source patching** — `run.sh` patches `mnemon` into NanoClaw's own `container/Dockerfile` and `container/entrypoint.sh` on every deploy, checking first whether it's already applied (matching the upstream skill's own idempotency contract exactly). No generic archetype has any notion of "patch a freshly-cloned third-party repo's own build files before building them."

---

## 🧠 Mnemon Integration

`run.sh`'s `apply_mnemon_patch()` function does exactly what NanoClaw's own `/add-mnemon` Claude Code skill documents, applied automatically instead of interactively:

1. Inserts a block into `container/Dockerfile` (immediately above the `# ---- Bun runtime` section) that downloads the pinned `mnemon` release binary and installs it into the agent-sandbox image.
2. Adds `mnemon setup --target claude-code --yes --global` to `container/entrypoint.sh`, run on every agent container start.

Both steps are applied **before** NanoClaw's own setup wizard builds the agent image for the first time, so the very first build already includes mnemon — no separate rebuild step needed, unlike applying this skill to an already-running install.

**Version pinning**: `MNEMON_VERSION` in `.env` (default `0.1.1`) controls exactly which mnemon release gets installed. A `CLEAN` redeploy re-clones NanoClaw from scratch and reapplies the patch with whatever `MNEMON_VERSION` is currently set — bump it deliberately, it won't drift on its own.

**Memory storage**: mnemon writes to `/home/node/.claude/mnemon/` inside each agent container, which maps onto that conversation group's own `.claude/` directory under `$NANOCLAW_INSTALL_PATH/groups/<group>/` — memory is per-group by default (mnemon also supports an optional shared/global read-only store; this environment doesn't configure that, it's mnemon's own default per-agent behavior).

**Provider compatibility**: mnemon's Claude Code hooks only fire for groups running the default Claude provider. If you've configured a group with `"provider": "opencode"` or similar in its `container.json`, mnemon's hooks won't run for that group — check with `grep -H '"provider"' groups/*/container.json` inside the install path.

---

## Security Notes

Worth being precise about what this environment does and doesn't change, relative to the plain `nanoclaw` environment's own security model (see its README's "Deployment Modes" section, and the point that Docker socket access is inherently root-equivalent on the host — that discussion applies identically here):

- **This does not expand the orchestrator's own trust boundary.** Mnemon runs inside the per-conversation-group agent containers, which — verified directly against NanoClaw's own `src/container-runner.ts` — never hold the Docker socket, never run `--privileged`, and have tightly group-scoped bind mounts to begin with. Adding mnemon inside that same sandbox doesn't give it any access the agent container didn't already have.
- **It does add a new third-party dependency.** `mnemon-dev/mnemon` is a real, independent, Apache-2.0-licensed project (377 stars at last check) — a separate trust relationship from `nanocoai/nanoclaw` itself, running as a single Go binary with filesystem access scoped to whatever the agent container already has (its own group's mounts).
- **The patch mechanism itself is text-editing NanoClaw's own build files** (`container/Dockerfile`, `container/entrypoint.sh`) inside your local clone — verify the patch output yourself after first deploy if you want to confirm exactly what changed, or diff against upstream's own `/add-mnemon` skill output.

---

## Coexistence with the Plain `nanoclaw` Environment

Both environments can run on the same machine. Two things were specifically handled for this:

- **Separate install paths, container names, and ports** (`nanoclaw-mnemon` vs `nanoclaw`, `$HOME/nanoclaw-mnemon` vs `$HOME/nanoclaw`, port `3081` vs `3080`) — set via this environment's own `.env.example` defaults.
- **Agent-container sweeps are scoped by bind-mount path, not by name pattern.** NanoClaw names every conversation group's agent container/image `nanoclaw-agent-v2-*` regardless of which install spawned it — a plain name-prefix filter (which is what the plain `nanoclaw` environment's `run.sh` uses, since it never needed to worry about a second coexisting install) would sweep up the *other* environment's agent containers too during `TEARDOWN`/`CLEAN`. This environment's `run.sh` instead inspects each candidate container's actual bind mounts via `docker inspect` and only touches ones that trace back to `$NANOCLAW_INSTALL_PATH` — verified against synthetic mount data covering exactly this cross-environment collision case before being considered correct.

---

## 📖 Optional: Karpathy LLM Wiki

The gist's Obsidian-facing piece splits into two parts, only one of which is custom:

- **Generating the wiki content is a first-party NanoClaw skill**, [`/add-karpathy-llm-wiki`](https://github.com/nanocoai/nanoclaw/blob/main/.claude/skills/add-karpathy-llm-wiki/SKILL.md) (bundled in the main `nanocoai/nanoclaw` repo, following [Karpathy's public LLM Wiki gist](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f)) — an LLM-maintained, cross-linked markdown knowledge base per conversation group (`wiki/`, `sources/`, `index.md`, `log.md`), explicitly designed as "a git-backed markdown directory." Nothing about the output format is Obsidian-specific — any markdown reader works (VS Code, Logseq, GitHub's own renderer, plain `cat`) — Obsidian is just the pattern doc's suggested viewer (it name-drops Web Clipper, graph view, the Dataview plugin).
- **Only the sync leg is genuinely custom**: the gist author's own iCloud + `rsync` pipeline from a personal Mac Mini to their own Obsidian vault. That's inherently tied to one person's device setup — not something pi-bootstrap can generically automate. If you want the wiki synced somewhere specific, that's a manual step on top of the plain markdown files this skill produces.

**What this environment scaffolds vs. what stays interactive**: `./scaffold-wiki.sh <group-folder>` creates the mechanical, non-collaborative half — `wiki/`, `sources/`, empty `index.md`/`log.md` — for one group, idempotently (safe to re-run). The rest of the upstream skill (choosing a domain, designing the schema, writing a tailored `container/skills/wiki/SKILL.md`, wiring a CLAUDE.md section) is explicitly collaborative by its own design — it discusses the domain with you before writing anything, which unattended scripting can't replicate without producing a generic, shallow wiki. Run `/add-karpathy-llm-wiki` yourself in a Claude Code session against the group for that part; `scaffold-wiki.sh`'s own output prints the exact command.

**Note on how this differs from the gist's own wiki**: `/add-karpathy-llm-wiki` compiles wiki pages straight from raw sources you feed it. In the gist's actual pipeline, the wiki is downstream of mnemon instead — pages are synthesized from mnemon's already-extracted facts, not raw sources directly (see `GIST-PARITY.md`'s embeddings section for the full breakdown, quoted from the gist). Both produce a markdown wiki; the gist's version has an extraction step (mnemon) in between that this environment's scaffolding doesn't replicate.

**A discrepancy worth knowing about**: the skill's Step 3c, as currently documented upstream, edits the group's `CLAUDE.md` directly. But NanoClaw's `container-runner`/`claude-md-compose.ts` now regenerates `CLAUDE.md` fresh on every container spawn (its own header comment: *"Composed at spawn — do not edit. Edit CLAUDE.local.md for per-group content."*) — so a marker-based edit landing in `CLAUDE.md` would silently vanish on the next restart. This looks like the skill doc predates that compose refactor. `scaffold-wiki.sh` flags this in its own output; verify which file the skill actually wrote to afterward, and move the wiki section into `CLAUDE.local.md` if it landed in `CLAUDE.md`.

**More complete alternatives exist — it's an ecosystem, not one project**: at least five independent implementations of the same Karpathy pattern exist outside NanoClaw (`nvk/llm-wiki`, `praneybehl/llm-wiki-plugin`, `ussumant/llm-wiki-compiler`, `lucasastorian/llmwiki`, `Pratiyush/llm-wiki`), none built on each other. See `GIST-PARITY.md` for the full comparison — including the one that matters most if you want to actually integrate one here: `lucasastorian/llmwiki` uses an MCP server rather than a Claude Code plugin, which sidesteps the open question the other four share (whether Claude Code's plugin-install mechanism even works inside NanoClaw's agent-runner container) by reusing the same MCP-server-registration pattern NanoClaw's own `/add-ollama-tool` already proves out.

---

## 💾 Data Directories

Persistent data lives inside the install path and survives `TEARDOWN`:

| Directory | Contents |
|-----------|---------|
| `$NANOCLAW_INSTALL_PATH/groups/` | Per-group files: conversation history, mnemon's persistent memory graph (nested under each group's `.claude/mnemon/`), transcripts, CLAUDE.md, and — if scaffolded — each group's `wiki/`/`sources/` (see "Optional: Karpathy LLM Wiki") |
| `$NANOCLAW_INSTALL_PATH/data/` | Sessions, message database, task scheduler database, IPC streams |

The install directory itself can be re-cloned by `CLEAN` (the mnemon patch reapplies automatically); the `groups/` and `data/` subdirectories are what actually need backing up.

---

## 🎛️ Deployment Policies

| Policy | Action |
|--------|--------|
| `FAST` | Start the orchestrator container if stopped; skip if already active. Clones NanoClaw and applies the mnemon patch on first deploy only |
| `STOP` | Stop the orchestrator container (agent containers keep running) |
| `TEARDOWN` | Stop the orchestrator + remove this install's agent containers (scoped by mount path — see "Coexistence" above); data and install path untouched |
| `CLEAN` | Rebuild the orchestrator image, remove this install's agent containers, wipe and re-clone the install path, reapply the mnemon patch, reinstall |
| `INFO` | List data directories with sizes and useful commands (scrollable via `less` in an interactive terminal) |
| `WIPE` | Delete `groups/` and `data/` only (install dir preserved) |

---

## 🖥️ Desktop Integration

On a Pi with a desktop environment, run once from the repo root:

```bash
./install-desktop-entries.sh
# or just this environment on its own:
./environments/nanoclaw-mnemon/install-desktop.sh
```

This installs a **NanoClaw + Mnemon AI** entry, in its own submenu, separate from the plain `nanoclaw` environment's entry. Skipped entirely on macOS (Linux-only, like every environment's desktop entries in this repo — see the main README's "Desktop Menu Integration" section).

---

## 💡 Useful Commands

```bash
# Orchestrator status and live logs
docker ps --filter name=nanoclaw-mnemon
docker logs -f nanoclaw-mnemon

# Restart after a config change
docker restart nanoclaw-mnemon

# Add messaging channels / update the Anthropic API key
docker exec -it nanoclaw-mnemon bash -lc "cd \$NANOCLAW_INSTALL_PATH && bash setup/add-whatsapp.sh"
docker exec -it nanoclaw-mnemon bash -lc "cd \$NANOCLAW_INSTALL_PATH && bash setup/add-telegram.sh"
docker exec -it nanoclaw-mnemon bash -lc "cd \$NANOCLAW_INSTALL_PATH && bash setup/register-claude-token.sh"

# List this install's agent containers (and the plain nanoclaw environment's, if also deployed — both share the nanoclaw-agent-v2-* name pattern)
docker ps --filter name=nanoclaw-agent

# Confirm mnemon is installed in the agent sandbox image
docker exec nanoclaw-mnemon docker run --rm --entrypoint mnemon nanoclaw-agent:latest --version

# Scaffold a Karpathy LLM Wiki for one group (see "Optional: Karpathy LLM Wiki" above)
./scaffold-wiki.sh <group-folder>

# Web interface
http://<host-ip>:3081
```

---

## What's Verified vs What Isn't

Verified directly, not assumed:
- The mnemon patch's exact text output, byte-for-byte, against the *actual current* `container/Dockerfile` and `container/entrypoint.sh` fetched live from `nanocoai/nanoclaw` — both insertions land exactly where and as the upstream skill file specifies.
- Idempotency — reapplying the patch against already-patched files correctly detects and skips both steps, no duplication.
- The full `FAST` first-deploy control flow, including a real `git clone` of the actual upstream repo (not a stub) followed by the real patch application, then the correct `docker build`/`run`/mount/port sequence.
- The cross-environment agent-container sweep filtering, against synthetic mount data covering exactly the "both environments deployed at once" collision case.

Not verified — no live Docker daemon or real Anthropic/channel credentials available while building this:
- The actual `container/build.sh` rebuild and the interactive `nanoclaw.sh` wizard running end-to-end inside a real container.
- Whether mnemon's own `mnemon setup --target claude-code` step behaves identically inside this containerized agent sandbox as it does in whatever environment mnemon's own maintainers tested against.

Same caveat as the plain `nanoclaw` environment: your first real deploy is the actual test.
