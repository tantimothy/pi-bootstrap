# Manual Equivalent: Getting from Plain `nanoclaw` to This Environment's State

Everything below is what `./run.sh` in this environment does for you automatically. If you'd rather not use it — or just want to understand exactly what it's doing before trusting it — here's the same result, by hand, starting from an already-deployed plain `nanoclaw` environment (container mode). Every value here is copied directly from this environment's own `run.sh`/`.env.example`, not re-derived or approximated.

**Assumption**: you already have `environments/nanoclaw` deployed in container mode (a running `nanoclaw` orchestrator container, per its own README). These steps build a **second, independent** install alongside it — same as this environment does — rather than modifying your existing one in place. If you'd rather patch your existing install instead of running a second one, skip straight to step 4 and apply it against your existing `$NANOCLAW_INSTALL_PATH` — you lose nothing by doing that except the ability to run both side by side.

---

## 1. Pick a separate identity

Reusing your existing `nanoclaw` container's name, port, or install path will collide with it. This environment's own defaults (from `.env.example`):

```bash
INSTALL_PATH="$HOME/nanoclaw-mnemon"     # or /home/pi/nanoclaw-mnemon on a Pi
CONTAINER_NAME="nanoclaw-mnemon"
IMAGE_TAG="nanoclaw-mnemon-orchestrator:latest"
NANOCLAW_PORT=3081                       # plain nanoclaw uses 3080
MNEMON_VERSION=0.1.1                     # see releases: https://github.com/mnemon-dev/mnemon/releases
MNEMON_EMBED_ENDPOINT=                   # optional, unset by default — see step 4
MNEMON_EMBED_MODEL=                      # optional, unset by default — see step 4
```

## 2. Build a second orchestrator image

The orchestrator's own `Dockerfile`/`entrypoint.sh` in this environment are functionally identical to the plain `nanoclaw` environment's container-mode files (only a comment and a container-name string in a log line differ) — you don't need new ones. Reuse what you already have, just tagged separately:

```bash
docker build -t nanoclaw-mnemon-orchestrator:latest environments/nanoclaw/
```

(Or copy `environments/nanoclaw-mnemon/Dockerfile` and `entrypoint.sh` from this repo directly if you don't have `environments/nanoclaw/` checked out.)

## 3. Clone NanoClaw's source to the new path

```bash
mkdir -p "$INSTALL_PATH"
git clone https://github.com/nanocoai/nanoclaw.git "$INSTALL_PATH"
```

Use `nanocoai/nanoclaw` specifically — that's the current canonical location (`qwibitai/nanoclaw` 301-redirects there, but there's no reason to depend on that).

## 4. Patch mnemon in — before the first build

This is the actual content of NanoClaw's own `.claude/skills/add-mnemon/SKILL.md`, applied by hand instead of interactively. Two ways to do it — pick one:

**Option A — the official way**: open a Claude Code session inside `$INSTALL_PATH` and run `/add-mnemon`. It'll ask clarifying questions and apply the same edits described below itself. This is what you'd do if you had no automation at all.

**Option B — the exact manual edit**, if you'd rather not run an interactive skill:

Edit `$INSTALL_PATH/container/Dockerfile`. Find the line `# ---- Bun runtime` and insert this block immediately **above** it:

```dockerfile
# ---- mnemon — persistent agent memory ----------------------------------------
ARG MNEMON_VERSION=0.1.1
RUN ARCH=$(dpkg --print-architecture) && \
    curl -fsSL "https://github.com/mnemon-dev/mnemon/releases/download/v${MNEMON_VERSION}/mnemon_${MNEMON_VERSION}_linux_${ARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin mnemon && \
    chmod +x /usr/local/bin/mnemon

ENV MNEMON_DATA_DIR=/home/node/.claude/mnemon
```

Edit `$INSTALL_PATH/container/entrypoint.sh`. Find the line `set -e` and insert this line immediately **after** it:

```bash
mnemon setup --target claude-code --yes --global >/dev/stderr 2>&1
```

Both edits are idempotent by nature (re-applying them is only a problem if you paste them in twice by hand) — `grep -q 'MNEMON_VERSION' container/Dockerfile` and `grep -q 'mnemon setup' container/entrypoint.sh` tell you whether they're already there, which is exactly what this environment's own `apply_mnemon_patch()` checks before touching either file.

Do this **before** NanoClaw's own setup wizard builds the agent-sandbox image (step 6) — otherwise you'll need to trigger a rebuild of that image afterward instead of getting it for free on the first build.

### 4a. (Optional) Turn on mnemon's built-in hybrid graph+vector recall

Mnemon ships with this — it's not something this environment or the gist's author built. Its own README documents `MNEMON_EMBED_ENDPOINT`/`MNEMON_EMBED_MODEL` (defaulting to `nomic-embed-text`) as opt-in config: unset, mnemon runs graph-only, which is its own documented default, not a degraded mode.

To enable it, add two more lines to the same `ENV MNEMON_DATA_DIR=...` block from step 4, before the closing `# ---- Bun runtime` marker:

```dockerfile
ENV MNEMON_DATA_DIR=/home/node/.claude/mnemon
ENV MNEMON_EMBED_ENDPOINT=http://host.docker.internal:11434
ENV MNEMON_EMBED_MODEL=nomic-embed-text
```

(`MNEMON_EMBED_MODEL` is only needed if you want something other than mnemon's own default, which already is `nomic-embed-text` — safe to omit.)

**Getting Ollama itself ready** — `run.sh` now automates this part too (`ensure_ollama_ready()`), but by hand it's:

```bash
# 1. Check reachability
curl -fsS http://host.docker.internal:11434/api/tags

# 2. If unreachable, install Ollama
brew install ollama                                    # macOS
curl -fsSL https://ollama.com/install.sh | sh           # Linux

# 3. Start it
brew services start ollama                              # macOS, or:
ollama serve &

# 4. Pull the model
ollama pull nomic-embed-text
```

If `MNEMON_EMBED_ENDPOINT` points somewhere other than `host.docker.internal`/`localhost`/`127.0.0.1` (a remote Ollama), none of the above applies — that's infrastructure you manage yourself, not something either this script or its automated equivalent touches.

## 5. Launch the second orchestrator container

```bash
docker run -d --name nanoclaw-mnemon --restart unless-stopped \
    -e NANOCLAW_INSTALL_PATH="$INSTALL_PATH" \
    -v "$INSTALL_PATH:$INSTALL_PATH" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -p 3081:3081 \
    nanoclaw-mnemon-orchestrator:latest
```

Same shape as your existing `nanoclaw` container's own `docker run` — bind-mounted at the **identical path** on host and container (required for NanoClaw's own Docker-outside-of-Docker agent-spawning to resolve paths correctly — see the plain environment's README if that's unfamiliar), plus the Docker socket, plus the new port.

## 6. Run the setup wizard

```bash
docker exec -it nanoclaw-mnemon bash -lc "cd '$INSTALL_PATH' && bash nanoclaw.sh"
```

Interactive — asks for your Anthropic API key (a separate registration from your existing `nanoclaw` install's own; nothing is shared between the two), first channel setup, and builds the agent-sandbox image for the first time. Because you patched mnemon in first (step 4), that first build already includes it.

## 7. (Optional) Scaffold a wiki for a group

Purely mechanical — no need for automation:

```bash
GROUP=your-group-folder
mkdir -p "$INSTALL_PATH/groups/$GROUP/wiki" "$INSTALL_PATH/groups/$GROUP/sources"
cat > "$INSTALL_PATH/groups/$GROUP/wiki/index.md" <<'EOF'
# Wiki Index

Content-oriented catalog of every wiki page — link, one-line summary, updated on every ingest.
EOF
cat > "$INSTALL_PATH/groups/$GROUP/wiki/log.md" <<'EOF'
# Wiki Log

Append-only chronological record. Each entry starts with `## [YYYY-MM-DD] ingest|query|lint | <title>`.
EOF
```

Then run `/add-karpathy-llm-wiki` in a Claude Code session against that group for the collaborative part (domain design, the tailored `container/skills/wiki/SKILL.md`, the `CLAUDE.md`/`CLAUDE.local.md` section) — see this environment's README for the caveat about which of those two files the skill actually writes to.

## 8. One coexistence gotcha to watch for

NanoClaw names every conversation-group agent container `nanoclaw-agent-v2-*` regardless of which install spawned it. If you ever manually clean up containers with something like `docker ps -a | grep nanoclaw-agent-v2- | xargs docker rm`, you'll catch **both** installs' agent containers, not just this one's. To scope a manual cleanup to just this install:

```bash
for id in $(docker ps -a --format '{{.ID}} {{.Image}}' | awk '$2 ~ /^nanoclaw-agent-v2-/ {print $1}'); do
    docker inspect "$id" --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' | grep -qF "$INSTALL_PATH" && echo "$id"
done
```

That prints only the container IDs whose bind mounts actually trace back to `$INSTALL_PATH` — pipe that into `xargs docker rm` instead of a bare name-prefix grep. This is exactly what this environment's `run.sh` (`sweep_agent_container_ids()`) does automatically on every `TEARDOWN`/`CLEAN`.

---

That's the whole thing `./run.sh` automates: steps 1–4 (plus optional 4a, including Ollama's own setup) and 5–6 on every fresh deploy (idempotently — re-running skips whatever's already done), step 7 via `scaffold-wiki.sh` on request, step 8's filtering built into `TEARDOWN`/`CLEAN` so you never have to think about it by hand.
