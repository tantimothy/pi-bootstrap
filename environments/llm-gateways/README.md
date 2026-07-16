# LLM Gateways — OpenAI-Compatible Proxy for Ollama (and Beyond)

A small hub of self-hosted LLM gateways — an OpenAI-compatible HTTP layer in front of the Ollama models already running on this host (the same Ollama install the `nanoclaw-mnemon` and `chat-frontends` environments depend on). Point any OpenAI-SDK-compatible client (scripts, IDE plugins, the `chat-frontends` environment itself) at one of these instead of Ollama directly, and you get a single stable endpoint, request logging, and — if you opt into it — hosted-provider fallback and per-caller virtual keys, all without changing anything about how Ollama itself runs.

This environment is deliberately thin: prebuilt upstream Docker images only, no custom `run.sh`, no Ollama of its own.

Two gateways are available, toggled independently via `COMPOSE_PROFILES` in `.env` — no rebuild needed, just re-run `./run.sh` (or the generic Compose fallback's `up -d`) after changing it:

## 📂 Services & Ports

| Service | Container | Port | Profile | On by default? | Purpose |
|---------|-----------|------|---------|:---:|---------|
| [LiteLLM](https://github.com/BerriAI/litellm) | `litellm` | 4000 | `litellm` | ✅ | OpenAI-compatible proxy, config-driven model routing, optional hosted-provider fallback |
| LiteLLM's Postgres ([postgres:16](https://hub.docker.com/_/postgres)) | `litellm-postgres` | *(internal)* | `litellm-db` | ❌ opt-in | Backs LiteLLM's Virtual Keys / spend tracking / Admin UI login — see below |
| [Portkey Gateway](https://github.com/Portkey-AI/gateway) | `portkey-gateway` | 8787 | `portkey` | ❌ opt-in | A second, lighter no-config/no-database gateway alternative |

Confirmed directly against each project's own deployment docs before adding this: LiteLLM's own `docker-compose.yml` (image `docker.litellm.ai/berriai/litellm:main-stable`) and Portkey's `docs/installation-deployments.md` (`docker run -p 8787:8787 portkeyai/gateway:latest` — no compose file, no env vars, no volumes at all in its own quick-start).

---

## 🛠️ Prerequisites

- **Docker & Compose Plugin Installed** — see the repo root `README.md` if you haven't set this up yet.
- **Ollama installed on the host** — this environment does not install or run Ollama itself. If you've already deployed `nanoclaw-mnemon`, Ollama is already there (it prompts to install it on first deploy). Otherwise install it yourself first: https://ollama.com/download

---

## 🚀 Deployment & Automation Guide

### 1. Configure your environment

```bash
cd environments/llm-gateways
cp .env.example .env
# At minimum, replace LITELLM_MASTER_KEY — everything else has a working default
openssl rand -base64 32
```

Or use the repo's interactive `deploy.sh` menu, which walks you through the same `.env` fields.

**Which models does LiteLLM proxy?** That's controlled by `litellm-config.yaml` in this directory, not `.env` — it ships wired to your host's Ollama (every model you've pulled, under `ollama/*`) with commented-out examples for adding OpenAI/Anthropic alongside it. Uncomment an entry and set the matching `*_API_KEY` in `.env` to add a hosted provider.

### 2. Deploy

```bash
./run.sh
```

### 3. Call it

```bash
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "ollama/llama3.2", "messages": [{"role": "user", "content": "Hello"}]}'
```

Any OpenAI-SDK-compatible client works the same way — set its base URL to `http://<host-ip>:4000` and its API key to `LITELLM_MASTER_KEY`.

---

## 🔑 Optional: Virtual Keys / Spend Tracking (LiteLLM + Postgres)

LiteLLM runs config-only by default — no database, no persistent state beyond `litellm-config.yaml`. That's enough for a single-user local gateway. If you want per-caller virtual API keys, spend tracking, or the browser Admin UI (login-gated), it needs its own Postgres:

1. Generate a password: `openssl rand -base64 24`, put it in `LITELLM_DB_PASSWORD` in `.env`.
2. Set `LITELLM_DATABASE_URL=postgresql://litellm:<that password>@litellm-postgres:5432/litellm` in `.env` (the user/db name are fixed — only the password varies).
3. Add `litellm-db` to `COMPOSE_PROFILES` in `.env`.
4. Redeploy: `./run.sh` (or `REBUILD_POLICY=FAST ./run.sh`).

Both steps 2 and 3 are required — the profile starts the database container, the connection string tells LiteLLM to actually use it. Skipping either leaves LiteLLM in its default config-only mode.

---

## 🧭 Why LiteLLM Reaches Ollama via `host.docker.internal`

LiteLLM is a prebuilt, closed upstream image — there's no source to patch the way `nanoclaw-mnemon` patches NanoClaw's own gateway-detection code (`patch-host-gateway.cjs`). So this environment takes the simpler path instead: point `OLLAMA_BASE_URL` at `host.docker.internal:11434` (Ollama's default port) and rely on Docker's own host-gateway resolution (`extra_hosts: host-gateway` in `docker-compose.yml`).

**Known caveat on OrbStack specifically** (confirmed directly against this same host-gateway issue while building `nanoclaw-mnemon`): OrbStack resolves `host.docker.internal` to its own internal pseudo-address rather than the bridge network's actual gateway. That breaks reaching *another container's* published port through it — but it does **not** break this case, because Ollama here is a real host process, not a container, and reaching the host itself through `host.docker.internal` is exactly the scenario Docker's `extra_hosts: host-gateway` mechanism is designed for.

If LiteLLM still can't reach Ollama (empty model list, connection errors in `docker logs litellm`), find your bridge network's actual gateway IP and use that instead:

```bash
docker network inspect bridge --format '{{json .IPAM.Config}}'
# then set OLLAMA_BASE_URL=http://<that-gateway-ip>:11434 in .env and redeploy
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
| `llm-gateways_litellm_postgres_data` | LiteLLM's Postgres database — virtual keys, spend tracking, Admin UI accounts (only created if you've enabled the `litellm-db` profile) |

No local bind-mount directories, and no volume at all for LiteLLM itself or Portkey Gateway — both are stateless beyond the committed `litellm-config.yaml` (read-only mounted, not user data) unless you opt into Postgres. Ollama's own downloaded models live in Ollama's own data directory on the host, untouched by this environment's `WIPE`/`CLEAN` policies.

The volume name is pinned explicitly in `docker-compose.yml` (`name: llm-gateways_litellm_postgres_data`) rather than left to Compose's default project-name prefixing, so it stays stable regardless of what directory this environment is deployed from in the future — see `portainer`'s README for the fuller rationale behind this pattern.

---

## 🖥️ Desktop Integration

Run `../../install-desktop-entries.sh` (or the `[Desktop] Install Desktop Entries` option in `deploy.sh`) after deploying to add application-menu and Desktop icon shortcuts, grouped in their own **LLM Gateways** submenu.

| Desktop entry | Opens |
|:---|:---|
| **LiteLLM API Console** | `http://localhost:<LITELLM_PORT>/docs` in default browser (interactive API docs, always available — unlike the separate `/ui` Admin dashboard, which needs `litellm-db` enabled to log in) |
| **LLM Gateways Info** | This environment's generated `post-deploy-info.html` in default browser |

No entry for Portkey Gateway — it's a pure API proxy with no browser landing page of its own. Port values are read from your `.env` at install time. Re-run the script if you change ports.

---

## 💡 Useful Commands

```bash
# Follow live logs
docker logs -f litellm
docker logs -f litellm-portkey-gateway   # (prefix matches your CONTAINER_NAME)

# Full stack status
docker compose ps

# Health check
curl http://localhost:4000/health/liveliness

# Models Ollama has available (shared across every environment in this repo)
ollama list

# Pause / resume without losing data
REBUILD_POLICY=STOP ./run.sh
REBUILD_POLICY=FAST ./run.sh

# Full teardown (data directories untouched)
REBUILD_POLICY=TEARDOWN ./run.sh
```

---

## 🔒 Security Notes

- **`LITELLM_MASTER_KEY` is a real credential, not a placeholder to skip** — it's the only thing gating LiteLLM's endpoint. Generate a real value before exposing port 4000 to any network you don't fully trust.
- **Portkey Gateway ships with no auth of its own by default** — it forwards whatever provider credentials the *caller* sends per-request rather than storing any server-side, but that also means anyone who can reach port 8787 can use it to relay requests to any provider they supply a key for. Keep it on a trusted LAN/VPN, or put it behind your own reverse proxy with auth if you need it exposed more broadly.
- **No auth in front of Ollama itself.** Neither gateway adds authentication to the Ollama daemon it talks to. That's fine as long as Ollama's own port (11434) stays bound to localhost/host-only (Ollama's default), rather than being separately exposed to the LAN.
- Shares the host's Ollama daemon with `nanoclaw-mnemon` and `chat-frontends` — anything pulled or deleted here (`ollama pull`, `ollama rm`) affects those environments too, since it's the same models directory.
