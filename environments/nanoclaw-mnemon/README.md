# NanoClaw + Mnemon — Persistent Memory AI Assistant

The same self-hosted [NanoClaw](https://github.com/nanocoai/nanoclaw) AI assistant as the plain `nanoclaw` environment, with [mnemon](https://github.com/mnemon-dev/mnemon) — a real, independent, third-party persistent-memory tool — patched into NanoClaw's own per-conversation-group agent sandbox for cross-session graph memory. Two extras layer on top of that core: mnemon's own built-in optional Ollama embeddings for hybrid graph+vector recall (opt-in via `.env`, off by default), and a scaffolding script for NanoClaw's own Karpathy-pattern wiki skill (`scaffold-wiki.sh`, run manually per group).

**Fully independent of the plain `nanoclaw` environment**: its own install path, its own container name, its own port. Both can be deployed on the same machine without colliding. The plain `nanoclaw` environment is intentionally left untouched by this one — see "Coexistence" below.

**Credit**: this environment follows the architecture described in a public gist by GitHub user [VivianBalakrishnan](https://gist.github.com/VivianBalakrishnan/a7d4eec3833baee4971a0ee54b08f322), which describes NanoClaw combined with mnemon, local embeddings, a wiki layer, and a personal Obsidian sync into a "second brain." **Worth reading with some skepticism**: the gist claims wiki pages are synthesized *from* mnemon's extracted facts (raw sources → mnemon → wiki), but that specific pipeline has no corroborating implementation anywhere — not in the gist author's own public GitHub work (their only repo is an untouched, zero-commits-ahead fork of mnemon), and not in any of the five independently-built "Karpathy pattern" wiki tools surveyed in `GIST-PARITY.md`, all of which compile wikis directly from raw sources with no memory-tool intermediary. This environment implements each piece the gist names against real upstream sources — NanoClaw's own [`.claude/skills/add-mnemon/SKILL.md`](https://github.com/nanocoai/nanoclaw/blob/main/.claude/skills/add-mnemon/SKILL.md), mnemon's own genuinely-real optional embeddings feature (`MNEMON_EMBED_ENDPOINT`/`MNEMON_EMBED_MODEL`, opt-in via `.env`, defaulting to `nomic-embed-text`), and [`/add-karpathy-llm-wiki`](https://github.com/nanocoai/nanoclaw/blob/main/.claude/skills/add-karpathy-llm-wiki/SKILL.md) for the wiki layer — but mnemon and the wiki run as independent systems here, which the evidence above suggests is the architecture matching real-world practice, not a shortfall relative to the gist's specific claim. **See [`GIST-PARITY.md`](./GIST-PARITY.md) for the full analysis** — what's built and verified, what's still missing, and the credibility caveat in full. **See [`MANUAL-STEPS.md`](./MANUAL-STEPS.md)** if you'd rather not use this environment's automation — it's the exact same result (starting from a plain `nanoclaw` deploy), spelled out by hand.

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

**Optional hybrid graph+vector recall**: mnemon has this built in (`MNEMON_EMBED_ENDPOINT`/`MNEMON_EMBED_MODEL`, defaulting to `nomic-embed-text`) — set `MNEMON_EMBED_ENDPOINT` in `.env` (see `.env.example`'s own comment, commented out by default) to bake it into the Dockerfile as a plain `ENV` line. Left unset, mnemon runs graph-only — its own documented default, not a degraded mode. Requires `CLEAN` to take effect on an already-deployed install, same as bumping `MNEMON_VERSION`. The patch also bakes in `NO_PROXY`/`no_proxy` for that endpoint's host, so OneCLI's own unconditional `HTTPS_PROXY` injection (see "Security Notes" below) doesn't end up intercepting mnemon's embeddings traffic if you point it at an HTTPS endpoint.

When set, `run.sh`'s `ensure_ollama_ready()` checks whether that endpoint is reachable before proceeding, and — only for a local address (`host.docker.internal`/`localhost`/`127.0.0.1`) — offers to install Ollama itself (Homebrew on macOS, the official installer on Linux, gated behind an explicit y/N prompt), starts it if it's installed but not running, and pulls the model if it's missing. A remote `MNEMON_EMBED_ENDPOINT` is left alone entirely — that's your own infrastructure, not something this script manages. Every failure here is a warning, not a hard stop: the rest of the deploy proceeds regardless, with mnemon simply running graph-only until you resolve it.

**Provider compatibility**: mnemon's Claude Code hooks only fire for groups running the default Claude provider. If you've configured a group with `"provider": "opencode"` or similar in its `container.json`, mnemon's hooks won't run for that group — check with `grep -H '"provider"' groups/*/container.json` inside the install path.

---

## 🧭 First-Time Setup: What to Expect

The wizard is interactive and pauses for your input several times. None of what follows is a bug — every invisible-prompt issue below has since been fixed in `run.sh` itself — this is the real, sequential walkthrough of a fresh `CLEAN` deploy, including the parts most likely to trip you up the first time, straight from an actual deploy.

**1. "You are running as root" warning.** NanoClaw's own wizard opens with this. Answer **`2` (continue as root)** — this container has no `USER` directive by design, so it's expected and safe here; the Docker socket it needs is already root-equivalent regardless of which user runs inside the container. See "Security Notes" below for the full reasoning.

**2. Claude CLI sign-in (OAuth).** The Claude CLI is pre-installed in the image now, so this step should just show "already-installed" and move straight to sign-in. It tries to open a browser automatically — that fails silently inside this headless container, so it prints a URL instead, with a `c` shortcut to copy it. Two gotchas worth knowing before you hit them:

- **Don't copy the URL by selecting the wrapped terminal text.** A long URL gets soft-wrapped across several lines by your terminal; copying the *displayed* wrapped text (rather than the real single line) inserts a literal space or newline right in the middle of the `client_id` value, breaking the OAuth request (`OAuth Request Failed: client_id: Input should be a valid UUID...`). Widen your terminal window so the URL prints on one unwrapped line before copying it, or use the `c` shortcut instead.
- **`c` to copy may put nothing on your clipboard.** It works via OSC 52, a terminal escape sequence that lets a process running in a container/remote shell write to your *local* clipboard without needing `pbcopy` inside the container. Not every terminal honors this by default — Terminal.app has historically had weak support; iTerm2 needs Preferences → General → Selection → "Applications in terminal may access clipboard" enabled; tmux needs `set -g set-clipboard on`. If `c` silently does nothing, fall back to widening the terminal and selecting the single unwrapped line by hand.

Paste the (correctly copied) URL into a real browser, sign in, and paste the resulting code back into the wizard.

**3. Ollama install prompt — only if `MNEMON_EMBED_ENDPOINT` is set.** You'll see `⚠️ Ollama isn't installed on this host.` followed by a `[y/N]` question asking whether to install it via Homebrew (macOS) or the official installer (Linux). Answer **`y`** to have it installed automatically now; anything else skips it, and mnemon simply runs graph-only until you install Ollama yourself later — never a hard stop either way.

**4. Chat works — everything after this is optional.** Once the wizard finishes and you've paired a first channel (e.g. Telegram), required setup is done. From here: enable/verify Ollama embeddings (below), scaffold a Karpathy wiki (further down), add more channels, or just use it.

---

## 🔍 Verifying Ollama & Mnemon Are Actually Being Used

Two independent things to check — one being fine doesn't guarantee the other.

**Ollama itself works:**

```bash
ollama list
curl -s http://localhost:11434/api/embeddings -d '{"model": "nomic-embed-text", "prompt": "test"}' | head -c 200
```

The second command should return real JSON with an `"embedding": [...]` array — not `{"error":"model ... not found, try pulling it first"}` (run `ollama pull nomic-embed-text`) and not a connection error (Ollama itself isn't running — `brew services start ollama`, or `ollama serve &`).

**Mnemon is actually using it** — the authoritative check, straight from mnemon's own CLI, run from inside a *live agent container* (not the orchestrator itself):

```bash
docker ps --filter "name=nanoclaw-v2-" --format '{{.Names}}'
docker exec -it <that-container-name> mnemon embed --status
```

```json
{
  "total_insights": 87,
  "embedded": 87,
  "coverage": "100%",
  "ollama_available": true,
  "model": "nomic-embed-text"
}
```

`ollama_available` is a **live reachability check at the moment you run this** (2-second timeout, per mnemon's own docs) — not "is Ollama installed." It can read `false` even with Ollama fully installed and running, if the model isn't pulled yet, the endpoint's misconfigured, or Ollama just isn't running right now — the three cases above cover all of those. If `coverage` is stuck below 100% from conversations that happened before Ollama was ready, backfill once: `mnemon embed --all` (same `docker exec -it <container>` form).

**What's actually generating your replies, regardless of the above: always Claude, never Ollama.** Ollama only scores *which* past memories mnemon surfaces during recall — mnemon's own architecture doc is explicit about the division of labor: *"The LLM decides WHAT to remember and link. Mnemon handles HOW to store, index, and retrieve."* Turning Ollama off just makes recall fall back to keyword/graph-only scoring; it never changes who's replying to you.

---

## Security Notes

Worth being precise about what this environment does and doesn't change, relative to the plain `nanoclaw` environment's own security model (see its README's "Deployment Modes" section, and the point that Docker socket access is inherently root-equivalent on the host — that discussion applies identically here). That includes the first-run wizard's "you are running as root" warning: this environment's orchestrator image has no `USER` directive either, and the same reasoning applies — see the plain `nanoclaw` README's "Notes" section for why answering "continue as root" is fine here too.

- **This does not expand the orchestrator's own trust boundary.** Mnemon runs inside the per-conversation-group agent containers, which — verified directly against NanoClaw's own `src/container-runner.ts` — never hold the Docker socket, never run `--privileged`, and have tightly group-scoped bind mounts to begin with. Adding mnemon inside that same sandbox doesn't give it any access the agent container didn't already have.
- **It does add a new third-party dependency.** `mnemon-dev/mnemon` is a real, independent, Apache-2.0-licensed project (377 stars at last check) — a separate trust relationship from `nanocoai/nanoclaw` itself, running as a single Go binary with filesystem access scoped to whatever the agent container already has (its own group's mounts).
- **The patch mechanism itself is text-editing NanoClaw's own build files** (`container/Dockerfile`, `container/entrypoint.sh`) inside your local clone — verify the patch output yourself after first deploy if you want to confirm exactly what changed, or diff against upstream's own `/add-mnemon` skill output.
- **Credential handling is unchanged from plain NanoClaw** — this environment doesn't touch it at all. `setup/register-claude-token.sh` (verified directly) hard-requires the `onecli` binary with no fallback; your Anthropic token is registered into OneCLI's own vault by the wizard and never lands in `.env` or gets held directly by an agent container. `/add-ollama-provider`'s `NO_PROXY`/`no_proxy` env vars exist specifically to bypass OneCLI's proxy for Ollama traffic, which is a good pointer to what OneCLI actually does day to day — it's a local HTTP proxy sitting in front of outbound API calls, injecting credentials at request time rather than handing them to the container outright. Same mechanism, same trust model, as the plain `nanoclaw` environment's own README documents.

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

## 🚀 Launching Claude CLI Directly (Skills, Ad-Hoc Questions, etc.)

Beyond the setup wizard, you can start an interactive Claude Code session against the orchestrator's own NanoClaw checkout at any time — this is how you run skills like `/add-karpathy-llm-wiki` (above), re-run `/add-mnemon` (already applied automatically by this environment, but useful to know it's there), or just ask Claude something about the codebase directly:

```bash
docker exec -it nanoclaw-mnemon bash -lc "cd \$NANOCLAW_INSTALL_PATH && claude"
```

**Discovering what's available**: NanoClaw ships its own skills under `.claude/skills/` in its checkout — list them directly from outside the session:

```bash
docker exec nanoclaw-mnemon ls "$NANOCLAW_INSTALL_PATH/.claude/skills/"
```

Or, once inside an interactive `claude` session, type `/` on its own — Claude Code's own command palette lists every available slash command, built-in and skill-provided alike, with a one-line description each, and autocompletes as you keep typing.

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
bash lib/run-install-desktop.sh environments/nanoclaw-mnemon
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

# Find a specific group's own live agent container (needed for the mnemon commands below)
docker ps --filter "name=nanoclaw-v2-" --format '{{.Names}}\t{{.Status}}'

# Confirm mnemon is installed in the agent sandbox image
docker exec nanoclaw-mnemon docker run --rm --entrypoint mnemon nanoclaw-agent:latest --version

# Check mnemon's own embedding coverage / whether Ollama is actually reachable right now
# (see "Verifying Ollama & Mnemon Are Actually Being Used" above)
docker exec -it <agent-container-name> mnemon embed --status
docker exec -it <agent-container-name> mnemon embed --all      # backfill after enabling Ollama late
docker exec -it <agent-container-name> mnemon status            # general memory statistics

# Ollama itself (runs on the host, not in a container — see "Mnemon Integration" above)
ollama list
ollama pull nomic-embed-text
curl -s http://localhost:11434/api/embeddings -d '{"model": "nomic-embed-text", "prompt": "test"}'

# Scaffold a Karpathy LLM Wiki for one group (see "Optional: Karpathy LLM Wiki" above)
./scaffold-wiki.sh <group-folder>

# Launch an interactive Claude Code session against the orchestrator's own
# checkout — run skills (/add-karpathy-llm-wiki, /add-mnemon), or just ask
# Claude something directly (see "Launching Claude CLI Directly" above)
docker exec -it nanoclaw-mnemon bash -lc "cd \$NANOCLAW_INSTALL_PATH && claude"

# List every skill NanoClaw ships (or type `/` inside an interactive claude
# session for the same list with descriptions and autocomplete)
docker exec nanoclaw-mnemon ls "$NANOCLAW_INSTALL_PATH/.claude/skills/"
```

NanoClaw has no web UI by default (see the plain `nanoclaw` environment's README) — there's no `http://<host-ip>:3081` to visit unless you've separately added its optional `/add-dashboard` skill.

---

## What's Verified vs What Isn't

Verified directly against a real deploy, not assumed:
- The mnemon patch's exact text output, byte-for-byte, against the *actual current* `container/Dockerfile` and `container/entrypoint.sh` fetched live from `nanocoai/nanoclaw` — both insertions land exactly where and as the upstream skill file specifies.
- Idempotency — reapplying the patch against already-patched files correctly detects and skips both steps, no duplication.
- The full `FAST`/`CLEAN` control flow end-to-end, including a real `git clone`, real patch application, real `docker build`/`run`/mount/port sequence, the interactive `nanoclaw.sh` wizard running to completion inside a real container (Anthropic OAuth sign-in, root warning, Telegram channel pairing), and a real chat message getting a real model response.
- The cross-environment agent-container sweep filtering, against synthetic mount data covering exactly the "both environments deployed at once" collision case.
- Mnemon's own `mnemon embed --status`/`mnemon setup --target claude-code` steps, working correctly inside this containerized agent sandbox — including the Ollama install prompt and reachability checks. `ollama_available: true` specifically (i.e. mnemon's embed pipeline actually succeeding end-to-end) was not directly confirmed in this environment's own build/test process — `mnemon embed --status` is exactly how to check it yourself after pulling the embedding model.
- Several genuine, non-obvious bugs found and fixed only by testing against a real OrbStack/macOS deploy rather than synthetic stubs — see the git history for `run.sh`, `patch-host-gateway.cjs`, and `patch-nohup-autostart.cjs` if you want the full diagnostic trail for any of them: NanoClaw's own nohup-fallback service-start step (writes but never runs its own wrapper), `systemctl`-based channel-installer restarts silently no-op'ing (no real systemd in this container), OrbStack's `host.docker.internal`/`host-gateway` resolving to a different address than the one its own port-publishing actually uses, and `/tmp` not being shared between this container and the host (breaking OneCLI's own certificate hand-off to spawned agent containers).

Same caveat as the plain `nanoclaw` environment: this covers what's been tested, not a guarantee against everything upstream might change — treat your own first deploy as the real test, and see `MANUAL-STEPS.md` if you ever want to understand or reproduce any of this by hand.

---

## 📚 Further Reading

- **NanoClaw** — [nanocoai/nanoclaw](https://github.com/nanocoai/nanoclaw): the orchestrator and per-group agent sandbox this environment wraps. Its own `.claude/skills/` directory documents every skill referenced above (`/add-mnemon`, `/add-karpathy-llm-wiki`, `/add-telegram`, `/add-ollama-tool`, `/add-ollama-provider`, `/add-dashboard`, and more).
- **Claude Code** — [code.claude.com/docs](https://code.claude.com/docs): the CLI/SDK NanoClaw's agent containers run on — slash commands, skills, hooks, MCP servers, and the OAuth/subscription sign-in flow covered above.
- **Mnemon** — [mnemon-dev/mnemon](https://github.com/mnemon-dev/mnemon): the persistent-memory tool patched into the agent sandbox here. Its own `docs/USAGE.md` has the full CLI reference (`remember`, `recall`, `link`, `forget`, `gc`, `embed --status`, `embed --all`) and `docs/design/` covers the four-graph model.
- **Ollama** — [ollama.com](https://ollama.com): the optional local inference server mnemon's hybrid recall uses purely for embeddings, never for chat (see "Verifying Ollama & Mnemon" above). [ollama.com/download](https://ollama.com/download) for manual installs; [ollama.com/library](https://ollama.com/library) for browsing models beyond the default `nomic-embed-text`.
- **Karpathy's LLM Wiki pattern** — [the original gist](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f): the source pattern `/add-karpathy-llm-wiki` implements. `GIST-PARITY.md` in this directory compares this environment's implementation against it and five other independent implementations of the same pattern.
- **The gist this environment follows** — [VivianBalakrishnan's gist](https://gist.github.com/VivianBalakrishnan/a7d4eec3833baee4971a0ee54b08f322): NanoClaw + mnemon + local embeddings + wiki + Obsidian sync as a "second brain," with the credibility caveat discussed at the top of this README.
