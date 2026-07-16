# Chat Frontends — Browser Chat UIs for Ollama

A small hub of browser-based chat UIs for the Ollama models already running on this host (the same Ollama install the `nanoclaw-mnemon` environment depends on for its embeddings). This environment is deliberately thin: prebuilt upstream Docker images only, no custom `run.sh`, no Ollama of its own — every frontend here points at the host's existing Ollama daemon over `host.docker.internal`.

**Already using `nanoclaw-mnemon`?** It no longer bundles a chat UI of its own — deploy this standalone environment instead if you want one for your host's Ollama. The two are namespaced apart (different container names, ports, and data volumes) so both can run at once, though there's normally no reason to run both.

Three frontends are available, toggled independently via `COMPOSE_PROFILES` in `.env` — no rebuild needed, just re-run `./run.sh` (or the generic Compose fallback's `up -d`) after changing it:

## 📂 Services & Ports

| Service | Container | Port | Profile | On by default? | Purpose |
|---------|-----------|------|---------|:---:|---------|
| [Open WebUI](https://github.com/open-webui/open-webui) | `open-webui` | 3010 | `open-webui` | ✅ | General-purpose chat frontend, closest to a ChatGPT-style UI |
| [SillyTavern](https://github.com/SillyTavern/SillyTavern) | `sillytavern` | 8000 | `sillytavern` | ✅ | Character-card / role-play focused chat frontend |
| [LobeHub](https://github.com/lobehub/lobe-chat) | `lobehub` | 3210 | `lobehub` | ❌ opt-in | Full-featured chat frontend (plugins, agents, multi-user) — needs its own Postgres |
| LobeHub's Postgres ([ParadeDB](https://github.com/paradedb/paradedb)) | `lobehub-postgres` | *(internal)* | `lobehub` | ❌ opt-in | Database backing LobeHub's accounts/chat history — only started alongside `lobehub` |

All four are confirmed multi-arch (`amd64`/`arm64`) directly against their own registries before adding this — no local build required on a Pi.

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
# Edit ports, COMPOSE_PROFILES, or the LobeHub secrets below if you want it
```

Or use the repo's interactive `deploy.sh` menu, which walks you through the same `.env` fields.

**Want LobeHub too?** Add `lobehub` to `COMPOSE_PROFILES` and generate its three required secrets first — it (and its Postgres) will refuse to start with the `CHANGE_ME_*` placeholders left in place:

```bash
# LOBEHUB_DB_PASSWORD — any strong password
openssl rand -base64 24

# LOBEHUB_KEY_VAULTS_SECRET and LOBEHUB_AUTH_SECRET — run this twice,
# once for each, they must be different values
openssl rand -base64 32
```

Put the results in `.env`, then set `COMPOSE_PROFILES=open-webui,sillytavern,lobehub` (or drop whichever of the first two you don't want).

### 2. Deploy

```bash
./run.sh
```

### 3. Pull a chat-capable model

Ollama's `nomic-embed-text` (auto-pulled for mnemon's embeddings, see `nanoclaw-mnemon`'s README) is an **embedding-only** model — it cannot generate chat responses. Every frontend here needs an actual chat model:

```bash
ollama pull llama3.2
```

Pull it on the **host**, not inside any of these containers — Ollama itself isn't containerized here (see [Why These Reach Ollama via `host.docker.internal`](#-why-these-reach-ollama-via-hostdockerinternal) below). Once pulled, it shows up in each frontend's own model picker with no restart needed.

### 4. Sign up / configure each frontend

- **Open WebUI** (`http://<pi-ip>:3010`): the **first account created is made admin** — do this yourself before exposing the port to anyone else.
- **SillyTavern** (`http://<pi-ip>:8000`): no accounts by default — point it at Ollama under Settings > API Connections > Text Completion (or Chat Completion) > Ollama, using `http://host.docker.internal:11434` (already the default `OLLAMA_BASE_URL` this environment sets).
- **LobeHub** (`http://<pi-ip>:3210`, if enabled): first visit walks you through initial setup; Ollama is pre-wired via `OLLAMA_PROXY_URL`.

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

Select a policy when deploying from the `deploy.sh` menu, or set `REBUILD_POLICY` when running `./run.sh` directly:

| Policy | Action |
|--------|--------|
| `FAST` | Start stack if not running; otherwise reconcile against `docker-compose.yml` (no rebuild) so config-only edits (including `COMPOSE_PROFILES` changes) still take effect |
| `STOP` | Pause containers (resumable with FAST) |
| `TEARDOWN` | Stop + remove containers; data directories untouched |
| `CLEAN` | Pull/rebuild fresh, then stop + remove + redeploy |
| `INFO` | List data directories with sizes and useful commands |
| `WIPE` | Delete persisted data directories (irreversible — back up first) |

---

## 💾 Data Directories

### Named Docker Volumes

| Volume | Contents |
|--------|---------|
| `open-webui_open_webui_data` | Open WebUI's own app state — accounts, chat history, per-model settings |
| `open-webui_sillytavern_config` | SillyTavern's own settings, user accounts, and UI config |
| `open-webui_sillytavern_data` | SillyTavern character cards, chat logs, and persona data |
| `open-webui_sillytavern_plugins` | SillyTavern server plugins |
| `open-webui_sillytavern_extensions` | SillyTavern third-party front-end extensions |
| `open-webui_lobehub_postgres_data` | LobeHub's Postgres database — accounts, chat history, settings (only created if you've enabled the `lobehub` profile) |

No local bind-mount directories — everything each frontend persists lives in its own named volume above. Ollama's own downloaded models live in Ollama's own data directory on the host, untouched by this environment's `WIPE`/`CLEAN` policies.

Volume names are pinned explicitly in `docker-compose.yml` (still prefixed `open-webui_*`, this environment's previous folder name) rather than left to Compose's default project-name prefixing, so they stay stable across the rename and regardless of what directory this environment is deployed from — see `portainer`'s README for the fuller rationale behind this pattern.

---

## 🖥️ Desktop Integration

Run `../../install-desktop-entries.sh` (or the `[Desktop] Install Desktop Entries` option in `deploy.sh`) after deploying to add application-menu and Desktop icon shortcuts, grouped in their own **Chat Frontends** submenu.

| Desktop entry | Opens |
|:---|:---|
| **Open WebUI** | `http://localhost:<OPEN_WEBUI_PORT>` in default browser |
| **SillyTavern** | `http://localhost:<SILLYTAVERN_PORT>` in default browser |
| **LobeHub** | `http://localhost:<LOBEHUB_PORT>` in default browser (won't resolve until you've enabled its profile) |
| **Chat Frontends Info** | This environment's generated `post-deploy-info.html` in default browser |

Port values are read from your `.env` at install time. Re-run the script if you change ports.

---

## 💡 Useful Commands

```bash
# Follow live logs
docker logs -f open-webui
docker logs -f sillytavern
docker logs -f lobehub

# Full stack status
docker compose ps

# Models Ollama has available (shared across all frontends and mnemon's embeddings)
ollama list

# Pull a chat-capable model
ollama pull llama3.2

# Pause / resume without losing data
REBUILD_POLICY=STOP ./run.sh
REBUILD_POLICY=FAST ./run.sh

# Full teardown (data directories untouched)
REBUILD_POLICY=TEARDOWN ./run.sh
```

---

## 🔒 Security Notes

- **Open WebUI: first sign-up becomes admin.** Create your own account immediately after first deploy, before exposing port 3010 to any network you don't fully trust.
- **No auth in front of Ollama itself.** None of these frontends add authentication to the Ollama daemon they talk to. That's fine as long as Ollama's own port (11434) stays bound to localhost/host-only (Ollama's default), rather than being separately exposed to the LAN.
- **LobeHub's secrets are real credentials**, not placeholders to skip — `LOBEHUB_KEY_VAULTS_SECRET` encrypts stored API keys/settings and `LOBEHUB_AUTH_SECRET` signs sessions. Treat `.env` itself accordingly (already gitignored repo-wide).
- Shares the host's Ollama daemon with `nanoclaw-mnemon` — anything pulled or deleted here (`ollama pull`, `ollama rm`) affects that environment too, since it's the same models directory.
