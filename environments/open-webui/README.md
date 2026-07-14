# Open WebUI — Chat Frontend for Ollama

A browser-based chat UI for the Ollama models already running on this host (the same Ollama install the `nanoclaw-mnemon` environment depends on for its embeddings). This environment is deliberately thin: a single upstream Docker image, no custom `run.sh`, no Ollama of its own — it just points at the host's existing Ollama daemon over `host.docker.internal`.

## 📂 Services & Ports

| Service | Container | Port | Purpose |
|---------|-----------|------|---------|
| [Open WebUI](https://github.com/open-webui/open-webui) | `open-webui` | 3010 | Chat-style web frontend for local Ollama models |

Confirmed multi-arch (`amd64`/`arm64`) directly against the image's own registry before adding this — no local build required on a Pi.

---

## 🛠️ Prerequisites

- **Docker & Compose Plugin Installed** — see the repo root `README.md` if you haven't set this up yet.
- **Ollama installed on the host** — this environment does not install or run Ollama itself. If you've already deployed `nanoclaw-mnemon`, Ollama is already there (it prompts to install it on first deploy). Otherwise install it yourself first: https://ollama.com/download

---

## 🚀 Deployment & Automation Guide

### 1. Configure your environment

```bash
cd environments/open-webui
cp .env.example .env
# Edit ports if the defaults don't fit your setup
```

Or use the repo's interactive `deploy.sh` menu, which walks you through the same `.env` fields.

### 2. Deploy

```bash
./run.sh
```

### 3. Pull a chat-capable model

Ollama's `nomic-embed-text` (auto-pulled for mnemon's embeddings, see `nanoclaw-mnemon`'s README) is an **embedding-only** model — it cannot generate chat responses. Open WebUI needs an actual chat model:

```bash
ollama pull llama3.2
```

Pull it on the **host**, not inside the `open-webui` container — Ollama itself isn't containerized here (see [Why Open WebUI Reaches Ollama via `host.docker.internal`](#why-open-webui-reaches-ollama-via-hostdockerinternal) below). Once pulled, it shows up in Open WebUI's own model picker with no restart needed.

### 4. Sign up

Visit `http://<pi-ip>:3010`. The **first account created is made admin** — do this yourself before exposing the port to anyone else.

---

## 🧭 Why Open WebUI Reaches Ollama via `host.docker.internal`

Open WebUI is a prebuilt, closed upstream image — there's no source to patch the way `nanoclaw-mnemon` patches NanoClaw's own gateway-detection code (`patch-host-gateway.cjs`). So this environment takes the simpler path instead: point `OLLAMA_BASE_URL` at `host.docker.internal:11434` (Ollama's default port) and rely on Docker's own host-gateway resolution.

**Known caveat on OrbStack specifically** (confirmed directly against this same host-gateway issue while building `nanoclaw-mnemon`): OrbStack resolves `host.docker.internal` to its own internal pseudo-address rather than the bridge network's actual gateway. That breaks reaching *another container's* published port through it — but it does **not** break this case, because Ollama here is a real host process, not a container, and reaching the host itself through `host.docker.internal` is exactly the scenario Docker's `extra_hosts: host-gateway` mechanism is designed for.

If Open WebUI still can't reach Ollama (empty model list, connection errors in `docker logs open-webui`), find your bridge network's actual gateway IP and use that instead:

```bash
docker network inspect bridge --format '{{json .IPAM.Config}}'
# then set OLLAMA_BASE_URL=http://<that-gateway-ip>:11434 in .env and redeploy
```

---

## 🎛️ Deployment Policies

Select a policy when deploying from the `deploy.sh` menu, or set `REBUILD_POLICY` when running `./run.sh` directly:

| Policy | Action |
|--------|--------|
| `FAST` | Start stack if not running; otherwise reconcile against `docker-compose.yml` (no rebuild) so config-only edits still take effect |
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

No local bind-mount directories — everything Open WebUI persists lives in the named volume above. Ollama's own downloaded models live in Ollama's own data directory on the host, untouched by this environment's `WIPE`/`CLEAN` policies.

The volume name is pinned explicitly in `docker-compose.yml` (`name: open-webui_open_webui_data`) rather than left to Compose's default project-name prefixing, so it stays stable regardless of what directory this environment is deployed from in the future — see `portainer`'s README for the fuller rationale behind this pattern.

---

## 🖥️ Desktop Integration

Run `../../install-desktop-entries.sh` (or the `[Desktop] Install Desktop Entries` option in `deploy.sh`) after deploying to add application-menu and Desktop icon shortcuts, grouped in their own **Open WebUI** submenu.

| Desktop entry | Opens |
|:---|:---|
| **Open WebUI** | `http://localhost:<OPEN_WEBUI_PORT>` in default browser |
| **Open WebUI Info** | This environment's generated `post-deploy-info.html` in default browser |

Port values are read from your `.env` at install time. Re-run the script if you change ports.

---

## 💡 Useful Commands

```bash
# Follow live logs
docker logs -f open-webui

# Full stack status
docker compose ps

# Models Ollama has available (shared with mnemon's embeddings)
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

- **First sign-up becomes admin.** Create your own account immediately after first deploy, before exposing port 3010 to any network you don't fully trust.
- **No auth in front of Ollama itself.** Open WebUI's `WEBUI_AUTH` only gates the web UI — it doesn't add authentication to the Ollama daemon it talks to. That's fine as long as Ollama's own port (11434) stays bound to localhost/host-only (Ollama's default), rather than being separately exposed to the LAN.
- Shares the host's Ollama daemon with `nanoclaw-mnemon` — anything pulled or deleted here (`ollama pull`, `ollama rm`) affects that environment too, since it's the same models directory.
