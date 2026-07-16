# Chat Frontends — Browser Chat UIs for Ollama

A small hub of browser-based chat UIs for the Ollama models already running on this host (the same Ollama install the `nanoclaw-mnemon` environment depends on for its embeddings). This environment is deliberately thin: prebuilt upstream Docker images only, no custom `run.sh`, no Ollama of its own — every frontend here points at the host's existing Ollama daemon over `host.docker.internal`.

**Already using `nanoclaw-mnemon`?** It no longer bundles a chat UI of its own — deploy this standalone environment instead if you want one for your host's Ollama. The two are namespaced apart (different container names, ports, and data volumes) so both can run at once, though there's normally no reason to run both.

Five frontends are available, toggled independently via `COMPOSE_PROFILES` in `.env` — no rebuild needed, just `docker compose up -d` again (or redeploy via `deploy.sh`) after changing it:

## 📂 Services & Ports

| Service | Container | Port | Profile | On by default? | Purpose |
|---------|-----------|------|---------|:---:|---------|
| [Open WebUI](https://github.com/open-webui/open-webui) | `open-webui` | 3010 | `open-webui` | ✅ | General-purpose chat frontend, closest to a ChatGPT-style UI |
| [SillyTavern](https://github.com/SillyTavern/SillyTavern) | `sillytavern` | 8000 | `sillytavern` | ✅ | Character-card / role-play focused chat frontend |
| [LobeHub](https://github.com/lobehub/lobe-chat) | `lobehub` | 3210 | `lobehub` | ❌ opt-in | Full-featured chat frontend (plugins, agents, multi-user) — needs its own Postgres |
| LobeHub's Postgres ([ParadeDB](https://github.com/paradedb/paradedb)) | `lobehub-postgres` | *(internal)* | `lobehub` | ❌ opt-in | Database backing LobeHub's accounts/chat history — only started alongside `lobehub` |
| [NextChat](https://github.com/ChatGPTNextWeb/NextChat) | `nextchat` | 3020 | `nextchat` | ❌ opt-in | Minimal ChatGPT-styled frontend — no server-side storage at all, chat history lives in the browser |
| [AnythingLLM](https://github.com/Mintplex-Labs/anything-llm) | `anythingllm` | 3011 | `anythingllm` | ❌ opt-in | RAG/knowledge-base focused — document ingestion, built-in embedded vector DB |

Open WebUI, SillyTavern, and LobeHub are confirmed multi-arch (`amd64`/`arm64`) directly against their own registries. NextChat and AnythingLLM ship prebuilt images too (`yidadaa/chatgpt-next-web`, `mintplexlabs/anythingllm`) — check their own Docker Hub pages for your specific Pi architecture before relying on them if you're on anything other than a 64-bit Pi OS.

---

## 🛠️ Prerequisites

- **Docker & Compose Plugin Installed** — see the repo root `README.md` if you haven't set this up yet.
- **Ollama installed on the host** — this environment does not install or run Ollama itself. If you've already deployed `nanoclaw-mnemon`, Ollama is already there (it prompts to install it on first deploy). Otherwise install it yourself first: https://ollama.com/download

---

## 🚀 Deployment & Automation Guide

### 1. Configure your environment

```bash
cd environments/chat-frontends
cp .env.example .env
# Set a real SILLYTAVERN_PASSWORD (see below) — required even for the
# default deploy, since SillyTavern is on by default. Edit ports,
# COMPOSE_PROFILES, or the LobeHub secrets below if you want them too.
```

Or use the repo's interactive `deploy.sh` menu, which walks you through the same `.env` fields.

**`SILLYTAVERN_PASSWORD` is required, not optional, even for a bare default deploy** — SillyTavern is one of the two frontends on by default, and this environment forces its own auth on (see "Sign up / configure each frontend" below for why). Generate a real one:

```bash
openssl rand -base64 18
```

Leaving the `CHANGE_ME_TO_A_SECURE_PASSWORD` placeholder in place means SillyTavern starts up fine but with a publicly-known, guessable password — set a real one before you actually expose port 8000 to anything but yourself.

**Want LobeHub too?** Add `lobehub` to `COMPOSE_PROFILES` and generate its three required secrets first — it (and its Postgres) will refuse to start with the `CHANGE_ME_*` placeholders left in place:

```bash
# LOBEHUB_DB_PASSWORD — any strong password
openssl rand -base64 24

# LOBEHUB_KEY_VAULTS_SECRET and LOBEHUB_AUTH_SECRET — run this twice,
# once for each, they must be different values
openssl rand -base64 32
```

Put the results in `.env`, then add `lobehub` to `COMPOSE_PROFILES`.

**Want NextChat or AnythingLLM too?** Both are simpler opt-ins — NextChat needs nothing beyond adding `nextchat` to `COMPOSE_PROFILES` (its defaults already point at Ollama). AnythingLLM needs one secret first:

```bash
# ANYTHINGLLM_JWT_SECRET — any random string
openssl rand -base64 32
```

Put it in `.env`, then add `anythingllm` to `COMPOSE_PROFILES`.

### 2. Deploy

```bash
docker compose up -d
```

Or use `deploy.sh`'s menu instead (**Chat Frontends** under **AI Assistants**) — it also pre-creates data directories, refreshes desktop entries, and prints the INFO summary afterward, none of which a bare `docker compose up -d` does on its own. There's no `run.sh` here (see the intro above) — `deploy.sh`'s generic Compose fallback drives this environment directly.

### 3. Pull a chat-capable model

Ollama's `nomic-embed-text` (auto-pulled for mnemon's embeddings, see `nanoclaw-mnemon`'s README) is an **embedding-only** model — it cannot generate chat responses. Every frontend here needs an actual chat model:

```bash
ollama pull llama3.2
```

Pull it on the **host**, not inside any of these containers — Ollama itself isn't containerized here (see [Why These Reach Ollama via `host.docker.internal`](#-why-these-reach-ollama-via-hostdockerinternal) below). Once pulled, it shows up in each frontend's own model picker with no restart needed.

### 4. Sign up / configure each frontend

- **Open WebUI** (`http://<pi-ip>:3010`): the **first account created is made admin** — do this yourself before exposing the port to anyone else.
- **SillyTavern** (`http://<pi-ip>:8000`): your browser will prompt for the `SILLYTAVERN_USERNAME`/`SILLYTAVERN_PASSWORD` you set in `.env` (see "Configure your environment" above) — SillyTavern itself has no separate account system beyond that. Once in, point it at Ollama under Settings > API Connections > Text Completion (or Chat Completion) > Ollama, using `http://host.docker.internal:11434` (already the default `OLLAMA_BASE_URL` this environment sets).
- **LobeHub** (`http://<pi-ip>:3210`, if enabled): first visit walks you through initial setup; Ollama is pre-wired via `OLLAMA_PROXY_URL`.
- **NextChat** (`http://<pi-ip>:3020`, if enabled): Ollama is pre-wired via `BASE_URL` — just start chatting. If you set `NEXTCHAT_ACCESS_CODE`, enter it when prompted.
- **AnythingLLM** (`http://<pi-ip>:3011`, if enabled): first visit walks you through initial setup (admin account, workspace creation); Ollama is pre-wired for both chat and embeddings via `OLLAMA_MODEL_PREF`/`EMBEDDING_MODEL_PREF`.

---

## 🧭 Why These Reach Ollama via `host.docker.internal`

Every frontend here is a prebuilt, closed upstream image — there's no source to patch the way `nanoclaw-mnemon` patches NanoClaw's own gateway-detection code (`patch-host-gateway.cjs`). So this environment takes the simpler path instead: point each frontend's own Ollama URL variable at `host.docker.internal:11434` (Ollama's default port) and rely on Docker's own host-gateway resolution (`extra_hosts: host-gateway` in `docker-compose.yml`).

**Known caveat on OrbStack specifically** (confirmed directly against this same host-gateway issue while building `nanoclaw-mnemon`): OrbStack resolves `host.docker.internal` to its own internal pseudo-address rather than the bridge network's actual gateway. That breaks reaching *another container's* published port through it — but it does **not** break this case, because Ollama here is a real host process, not a container, and reaching the host itself through `host.docker.internal` is exactly the scenario Docker's `extra_hosts: host-gateway` mechanism is designed for.

If a frontend still can't reach Ollama (empty model list, connection errors in its container logs), find your bridge network's actual gateway IP and use that instead:

```bash
docker network inspect bridge --format '{{json .IPAM.Config}}'
# then set OLLAMA_BASE_URL (Open WebUI) / OLLAMA_PROXY_URL (LobeHub) to
# http://<that-gateway-ip>:11434 in .env and redeploy; for SillyTavern,
# change the same address in its own API Connections settings instead,
# since it isn't driven by a .env variable
```

---

## 🎛️ Deployment Policies

Select a policy from `deploy.sh`'s menu — recommended, since it also handles data-dir pre-creation, desktop-entry refresh, and `CLEAN`'s safe build-before-swap ordering. There's no `run.sh` here to set `REBUILD_POLICY` on directly (see the intro above); the table below shows the equivalent raw `docker compose` command for each policy if you'd rather run it by hand from this directory:

| Policy | Action | Direct equivalent |
|--------|--------|--------------------|
| `FAST` | Start stack if not running; otherwise reconcile against `docker-compose.yml` (no rebuild) so config-only edits (including `COMPOSE_PROFILES` changes) still take effect | `docker compose up -d` |
| `STOP` | Pause containers (resumable with FAST) | `docker compose stop` |
| `TEARDOWN` | Stop + remove containers; data directories untouched | `docker compose down` |
| `CLEAN` | Pull/rebuild fresh, then stop + remove + redeploy | `docker compose pull && docker compose build --no-cache && docker compose down && docker compose up -d` |
| `INFO` | List data directories with sizes and useful commands | `deploy.sh` menu only |
| `WIPE` | Delete persisted data directories (irreversible — back up first) | `deploy.sh` menu only |

---

## 💾 Data Directories

### Named Docker Volumes

| Volume | Contents |
|--------|---------|
| `chat-frontends_open_webui_data` | Open WebUI's own app state — accounts, chat history, per-model settings |
| `chat-frontends_sillytavern_config` | SillyTavern's own settings, user accounts, and UI config |
| `chat-frontends_sillytavern_data` | SillyTavern character cards, chat logs, and persona data |
| `chat-frontends_sillytavern_plugins` | SillyTavern server plugins |
| `chat-frontends_sillytavern_extensions` | SillyTavern third-party front-end extensions |
| `chat-frontends_lobehub_postgres_data` | LobeHub's Postgres database — accounts, chat history, settings (only created if you've enabled the `lobehub` profile) |
| `chat-frontends_anythingllm_storage` | AnythingLLM's own storage — accounts, workspaces, ingested documents, and its embedded LanceDB vector store (only created if you've enabled the `anythingllm` profile) |

No local bind-mount directories — everything each frontend persists lives in its own named volume above (NextChat persists nothing server-side at all — its chat history lives in the browser's own IndexedDB). Ollama's own downloaded models live in Ollama's own data directory on the host, untouched by this environment's `WIPE`/`CLEAN` policies.

Volume names are pinned explicitly in `docker-compose.yml` rather than left to Compose's default project-name prefixing, so they stay stable regardless of what directory this environment is deployed from — see `portainer`'s README for the fuller rationale behind this pattern.

### ⚠️ Migrating from the old `open-webui_*` volume names

If you deployed this environment back when it was still called `open-webui` (before SillyTavern/LobeHub/NextChat/AnythingLLM were added and it was renamed to `chat-frontends`), your existing data is sitting in volumes named `open-webui_*` — the table above lists the **current**, `chat-frontends_*`-prefixed names. Docker Compose does not rename volumes on its own; if you just redeploy against the new `docker-compose.yml`, you'll get brand-new, empty `chat-frontends_*` volumes and your old data will sit untouched (not deleted) under its old names.

Check what you actually have first:

```bash
docker volume ls | grep open-webui_
```

If that returns nothing, there's nothing to migrate — skip this section. Otherwise, for each volume you have real data in, copy it into the new name **before** redeploying:

```bash
# Repeat for each volume you actually have (open_webui_data is the one
# nearly everyone has; the others only exist if you'd enabled that
# particular frontend before)
docker volume create chat-frontends_open_webui_data
docker run --rm \
  -v open-webui_open_webui_data:/from \
  -v chat-frontends_open_webui_data:/to \
  alpine sh -c "cd /from && cp -av . /to/"
```

Swap in `sillytavern_config`/`sillytavern_data`/`sillytavern_plugins`/`sillytavern_extensions`/`lobehub_postgres_data`/`anythingllm_storage` for whichever others you have. Once you've deployed and confirmed the new volumes actually have your data (sign in, check chat history), the old `open-webui_*` volumes are safe to remove: `docker volume rm open-webui_open_webui_data ...`. Until you do that cleanup, both old and new volumes exist side by side, so there's no risk of data loss from running the migration itself.

---

## 🖥️ Desktop Integration

Run `../../install-desktop-entries.sh` (or the `[Desktop] Install Desktop Entries` option in `deploy.sh`) after deploying to add application-menu and Desktop icon shortcuts, grouped in their own **Chat Frontends** submenu.

| Desktop entry | Opens |
|:---|:---|
| **Open WebUI** | `http://localhost:<OPEN_WEBUI_PORT>` in default browser |
| **SillyTavern** | `http://localhost:<SILLYTAVERN_PORT>` in default browser |
| **LobeHub** | `http://localhost:<LOBEHUB_PORT>` in default browser (won't resolve until you've enabled its profile) |
| **NextChat** | `http://localhost:<NEXTCHAT_PORT>` in default browser (won't resolve until you've enabled its profile) |
| **AnythingLLM** | `http://localhost:<ANYTHINGLLM_PORT>` in default browser (won't resolve until you've enabled its profile) |
| **Chat Frontends Info** | This environment's generated `post-deploy-info.html` in default browser |

Port values are read from your `.env` at install time. Re-run the script if you change ports.

---

## 💡 Useful Commands

```bash
# Follow live logs
docker logs -f open-webui
docker logs -f open-webui-sillytavern   # (prefix matches your CONTAINER_NAME)
docker logs -f open-webui-lobehub
docker logs -f open-webui-nextchat
docker logs -f open-webui-anythingllm

# Full stack status
docker compose ps

# Models Ollama has available (shared across all frontends and mnemon's embeddings)
ollama list

# Pull a chat-capable model
ollama pull llama3.2

# Pause / resume without losing data
docker compose stop
docker compose up -d

# Full teardown (data directories untouched)
docker compose down
```

---

## 🔒 Security Notes

- **Open WebUI: first sign-up becomes admin.** Create your own account immediately after first deploy, before exposing port 3010 to any network you don't fully trust.
- **SillyTavern's `SILLYTAVERN_PASSWORD` is a real credential, not optional.** This environment forces `whitelistMode` off and `basicAuthMode` on (see `docker-compose.yml`'s own comment) — SillyTavern's default IP-whitelist security doesn't reliably work in a containerized/NAT'd setup (confirmed directly: it blocked even the host machine's own browser under Docker Desktop for Mac), so basic auth is the only thing actually gating access now. Leaving the placeholder password in place is a real security gap, not just an inconvenience.
- **No auth in front of Ollama itself.** None of these frontends add authentication to the Ollama daemon they talk to. That's fine as long as Ollama's own port (11434) stays bound to localhost/host-only (Ollama's default), rather than being separately exposed to the LAN.
- **LobeHub's secrets are real credentials**, not placeholders to skip — `LOBEHUB_KEY_VAULTS_SECRET` encrypts stored API keys/settings and `LOBEHUB_AUTH_SECRET` signs sessions. Treat `.env` itself accordingly (already gitignored repo-wide).
- **NextChat has no auth by default.** Set `NEXTCHAT_ACCESS_CODE` before exposing port 3020 beyond your own trusted LAN — anyone who reaches it otherwise gets a free chat interface to your Ollama models.
- **AnythingLLM's `JWT_SECRET` is a real credential too** — it signs its own auth sessions. Generate a real value before exposing port 3011 to any network you don't fully trust.
- Shares the host's Ollama daemon with `nanoclaw-mnemon` — anything pulled or deleted here (`ollama pull`, `ollama rm`) affects that environment too, since it's the same models directory.
