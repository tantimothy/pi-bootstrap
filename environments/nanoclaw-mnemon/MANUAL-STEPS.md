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
MNEMON_VERSION=0.1.17                    # see releases: https://github.com/mnemon-dev/mnemon/releases
MNEMON_EMBED_ENDPOINT=                   # optional, unset by default — see step 4
MNEMON_EMBED_MODEL=                      # optional, unset by default — see step 4
```

## 2. Build a second orchestrator image

The orchestrator's own `Dockerfile`/`entrypoint.sh` in this environment are functionally identical to the plain `nanoclaw` environment's container-mode files (only a comment and a container-name string in a log line differ) — you don't need new ones. Reuse what you already have, just tagged separately:

```bash
docker build -t nanoclaw-mnemon-orchestrator:latest environments/nanoclaw/
```

(Or copy `environments/nanoclaw-mnemon/Dockerfile` and `environments/nanoclaw-mnemon/scripts/entrypoint.sh` from this repo directly if you don't have `environments/nanoclaw/` checked out.)

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
ARG MNEMON_VERSION=0.1.17
RUN ARCH=$(dpkg --print-architecture) && \
    curl -fsSL "https://github.com/mnemon-dev/mnemon/releases/download/v${MNEMON_VERSION}/mnemon_${MNEMON_VERSION}_linux_${ARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin mnemon && \
    chmod +x /usr/local/bin/mnemon

ENV MNEMON_DATA_DIR=/home/node/.claude/mnemon
```

Edit `$INSTALL_PATH/container/entrypoint.sh`. Find the line `set -e` and insert this line immediately **after** it:

```bash
mnemon setup --yes --global >/dev/stderr 2>&1
```

`--global` is required here, confirmed by running `mnemon setup` interactively inside a real agent-sandbox container: without it, mnemon auto-detects Claude Code correctly but writes hooks to a *project-local* `.claude/settings.json` relative to entrypoint.sh's own working directory (`/workspace/group` in this image) — not the *global* `~/.claude/settings.json` NanoClaw actually bind-mounts per group and Claude Code actually reads. Adding `--global` back correctly targets `~/.claude/settings.json` instead (confirmed the same way). `--target claude-code` is deliberately NOT included — auto-detection alone was never the problem, only the local-vs-global path was.

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

### 4b. (Optional) Let the agent transcribe video/audio itself

Same idea as step 4 (patch `container/Dockerfile` before the first build), but for giving the agent `yt-dlp`/`ffmpeg`/`whisper-cli` on its own `PATH`, not mnemon. Find `# ---- Bun runtime` in `$INSTALL_PATH/container/Dockerfile` and insert this immediately **above** it:

```dockerfile
# ---- media tools — yt-dlp / ffmpeg / whisper.cpp, so the agent itself can
# transcribe video/audio when given a URL, via its own Bash tool -----------
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Built with clang, not GCC — Debian bookworm's default GCC 12 fails
# outright on ggml's ARM NEON fp16 vector-arithmetic codepath on arm64
# ("inlining failed in call to 'always_inline' float16x8_t vfmaq_f16(...):
# target specific option mismatch"); clang doesn't have this conflict.
RUN apt-get update && apt-get install -y --no-install-recommends build-essential cmake clang \
    && git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git /tmp/whisper.cpp \
    && cmake -B /tmp/whisper.cpp/build -S /tmp/whisper.cpp -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
    && cmake --build /tmp/whisper.cpp/build --config Release -j"$(nproc)" \
    && cp /tmp/whisper.cpp/build/bin/whisper-cli /usr/local/bin/whisper-cli \
    && rm -rf /tmp/whisper.cpp \
    && apt-get purge -y --auto-remove build-essential cmake clang \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp \
    && chmod a+rx /usr/local/bin/yt-dlp
```

Then pull a whisper model into the **specific group's own folder** that wants this (not the top-level install path — verified directly against `container-runner.ts`'s own `buildMounts()`: only that group's folder is mounted into its agent container, at `/workspace/agent`):

```bash
GROUP=your-group-folder
mkdir -p "$INSTALL_PATH/groups/$GROUP/models"
curl -L https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin \
  -o "$INSTALL_PATH/groups/$GROUP/models/ggml-base.bin"
```

See the README's "Transcribing Audio/Video" section for the orchestrator-side manual pipeline instead, and for what to do if a group's agent image was already built before you added this patch (it doesn't rebuild on its own — you have to force it).

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

This environment doesn't bundle a chat UI — want one for Ollama? See the standalone `chat-frontends` environment instead; it's independent of NanoClaw entirely.

## 7. (Optional) Set up a Karpathy LLM Wiki for a group

Two parts — one mechanical, one deliberately not automatable.

### 7a. The mechanical half: scaffold the empty structure

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

This is exactly what `./scripts/scaffold-wiki.sh "$GROUP"` does for you (idempotent — safe to re-run).

### 7b. The collaborative half: run the upstream skill

```bash
docker exec -it nanoclaw-mnemon bash -lc "cd '$INSTALL_PATH/groups/$GROUP' && claude"
```

Then, inside that session, run:

```
/add-karpathy-llm-wiki
```

[`/add-karpathy-llm-wiki`](https://github.com/nanocoai/nanoclaw/blob/main/.claude/skills/add-karpathy-llm-wiki/SKILL.md) is a first-party NanoClaw skill following [Karpathy's public LLM Wiki gist](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f) — it discusses the domain with you before writing anything (choosing what the wiki is actually about, designing its schema, writing a tailored `container/skills/wiki/SKILL.md`, wiring a `CLAUDE.md` section), which is exactly why this part isn't scripted: unattended automation here would produce a generic, shallow wiki instead of one that fits your actual use case.

**A discrepancy worth knowing about before you run it**: the skill's Step 3c, as currently documented upstream, edits the group's `CLAUDE.md` directly. But NanoClaw's `container-runner`/`claude-md-compose.ts` now regenerates `CLAUDE.md` fresh on every container spawn (its own header comment: *"Composed at spawn — do not edit. Edit CLAUDE.local.md for per-group content."*) — so a marker-based edit landing in `CLAUDE.md` would silently vanish on the next restart. This looks like the skill doc predates that compose refactor. Check which file the skill actually wrote to afterward:

```bash
grep -l "wiki" "$INSTALL_PATH/groups/$GROUP/CLAUDE.md" "$INSTALL_PATH/groups/$GROUP/CLAUDE.local.md" 2>/dev/null
```

If it landed in `CLAUDE.md`, move that section into `CLAUDE.local.md` yourself so it survives the next container restart.

### 7c. Adding sources afterward

**"Add sources via Telegram" doesn't mean the file has to travel through Telegram.** `sources/` is a plain directory at `$INSTALL_PATH/groups/$GROUP/sources/`, bind-mounted to your host filesystem — `cp` a file straight into it:

```bash
cp report.pdf "$INSTALL_PATH/groups/$GROUP/sources/"
```

But NanoClaw's agent only acts on inbound messages — nothing watches `sources/` for new files on its own. Send a message on whichever channel the group uses to actually trigger ingestion, e.g. *"I just added `report.pdf` to sources/, please ingest it"* — that message, not the file's arrival, is what wakes the agent up to go read and process it.

**More complete alternatives exist** if this doesn't fit your needs — at least five independent implementations of the same Karpathy pattern exist outside NanoClaw; see this environment's `GIST-PARITY.md` for the full comparison.

## 8. One coexistence gotcha to watch for

NanoClaw names every conversation-group agent container `nanoclaw-agent-v2-*` regardless of which install spawned it. If you ever manually clean up containers with something like `docker ps -a | grep nanoclaw-agent-v2- | xargs docker rm`, you'll catch **both** installs' agent containers, not just this one's. To scope a manual cleanup to just this install:

```bash
for id in $(docker ps -a --format '{{.ID}} {{.Image}}' | awk '$2 ~ /^nanoclaw-agent-v2-/ {print $1}'); do
    docker inspect "$id" --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' | grep -qF "$INSTALL_PATH" && echo "$id"
done
```

That prints only the container IDs whose bind mounts actually trace back to `$INSTALL_PATH` — pipe that into `xargs docker rm` instead of a bare name-prefix grep. This is exactly what this environment's `run.sh` (`sweep_agent_container_ids()`) does automatically on every `TEARDOWN`/`CLEAN`.

---

That's the whole thing `./run.sh` automates: steps 1–4 (plus optional 4a and 4b, including Ollama's own setup and the agent-side media-tools patch — always applied, unlike 4a/4b's own optional configuration) and 5–6 on every fresh deploy (idempotently — re-running skips whatever's already done); step 7a via `scaffold-wiki.sh` on request, with 7b/7c always manual by design (see step 7 above for why); step 8's filtering built into `TEARDOWN`/`CLEAN` so you never have to think about it by hand.
