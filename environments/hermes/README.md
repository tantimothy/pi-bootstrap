# Hermes Agent — Personal Agent Platform with a Learning Loop

[Hermes Agent](https://github.com/NousResearch/hermes-agent) runs one agent
core across a terminal CLI, a TUI, a messaging gateway spanning roughly
twenty platforms, and a desktop app. Its distinguishing feature is a
**learning loop**: it writes its own skills from successful runs and keeps
persistent memory.

A sibling to `openclaw` and `nanoclaw-mnemon` — and **much easier than
`nanoclaw-mnemon`**, because an official multi-arch image means none of that
environment's source-patching machinery. Plain `docker-compose.yml`, no
`run.sh`.

> **Evaluated alongside `nanoclaw-mnemon`, not as a replacement for it.**
> See `docs/future-enhancements/agent-control-environments.md`, settled
> decision 6.

---

## 🧠 Read this before anything else: the state *is* the product

Everything that makes a deployed Hermes yours lives in **one host
directory** — `HERMES_DATA_PATH`, mounted at `/opt/data`:

| Path | What |
|:---|:---|
| `.env` | API keys and platform tokens |
| `config.yaml` | All configuration |
| `SOUL.md` | The agent's personality |
| `sessions/` | Conversation history |
| `memories/` | The persistent memory store |
| `skills/` | Installed skills — **including the ones it wrote itself** |
| `cron/` | Scheduled jobs |
| `hooks/` | Event hooks |
| `home/` | Per-profile `HOME` for tool subprocesses (`git`, `ssh`, `gh`, `npm`, skill CLIs) |

**The image is stateless and replaceable; this directory is not.** A rebuild
costs a `docker pull`. Losing that directory costs everything Hermes has
learned.

`info.yaml` declares it, so `backup.sh` already covers it. Use it *before*
you need it — an environment whose value is entirely accumulated state
deserves a backup path from day one, not after the first loss.

The counterpart: `/opt/hermes` (the install tree) is root-owned and read-only
to the runtime user in published images. Agent self-improvement is scoped to
skills, memory, plugins and config under `/opt/data` — the core cannot be
live-edited.

---

## 🚀 First run

Deploy once, then run the setup wizard. It is interactive and writes your API
keys into the data directory's own `.env`, which is why a deploy cannot do it
for you — `pre-deploy.sh` says so when it sees an unconfigured data
directory.

```bash
docker run -it --rm -v ~/.hermes:/opt/data \
  nousresearch/hermes-agent setup
```

Set up a chat platform at this point; the gateway has nothing to do without
one.

Then, for ordinary use:

```bash
docker exec -it hermes /opt/hermes/.venv/bin/hermes   # interactive chat
docker logs -f hermes                                  # gateway output
```

> **Platform tokens are deliberately NOT in this environment's `.env`.**
> Hermes keeps its own inside the data directory. Duplicating them would give
> you two places to rotate a token and one of them silently stale.

---

## ⚠️ The dashboard drives a real agent

`pre-deploy.sh` **refuses to deploy** with `HERMES_DASHBOARD` on and no auth
provider configured. That is not this repo being cautious on its own account:

> Upstream removed its own `--insecure` flag after an unauthenticated public
> dashboard was the entry point for the June 2026 MCP-config persistence
> campaign — internet scanners reached exposed dashboards and drove the agent
> into planting an SSH-key backdoor.

Hermes now fails closed by itself on a non-loopback bind with no provider —
but it fails closed *inside the container*, as a dashboard that silently
never comes up. Checking at deploy time turns that into a message naming the
missing variable.

Pick one provider:

| Provider | Set | Suitable for |
|:---|:---|:---|
| Username/password | `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` + `_PASSWORD` | Trusted LAN or VPN. Upstream: *"not suitable for direct public-internet exposure"* |
| OAuth (Nous Portal) | `HERMES_DASHBOARD_OAUTH_CLIENT_ID` | Upstream's recommendation for anything internet-facing |
| Self-hosted OIDC | `HERMES_DASHBOARD_OIDC_ISSUER` + `_CLIENT_ID` | Your own identity provider |

Add `HERMES_DASHBOARD_BASIC_AUTH_SECRET` (`openssl rand -hex 32`) with the
first, or every container restart logs you out.

### Or skip the dashboard's exposure entirely

Leave `HERMES_DASHBOARD` unset and tunnel:

```bash
ssh -L 9119:localhost:9119 <host>
```

### Where the bind actually happens

**Inside** the container the dashboard binds `0.0.0.0` — it has to, or a
published port would be unreachable. So the container-side bind is never
loopback, an auth provider is always required, and the thing that actually
decides who can reach it is `HERMES_BIND_ADDRESS`, which this environment
defaults to `127.0.0.1` on the host side.

---

## 🔁 One container, not upstream's two

Upstream's own `docker-compose.yml` runs `gateway` and `dashboard` as
separate services under `network_mode: host`, because the dashboard's
gateway-liveness detection needs a shared PID namespace.

This environment runs **one**, because:

- `network_mode: host` is a Linux-shaped assumption and the container host
  here is a Mac under OrbStack;
- the image already supervises the dashboard as an s6-rc service inside the
  gateway container when `HERMES_DASHBOARD=1`. Upstream's own Docker guide
  documents that as the normal shape, with the separate-container variant as
  the exception that needs the shared namespaces.

`gateway run` inside the image is itself supervised by s6-overlay: the CMD
process is a heartbeat, and s6 restarts the real gateway within seconds if it
crashes. `docker stop` still shuts everything down cleanly.

---

## 📌 Pin the image tag

Upstream tags `:latest` and `:main` on **every push to main**, plus
`:<release-tag>` on a release.

`check-updates.sh` compares running image IDs, so `:latest` reports an
available update several times a week — which trains you to ignore the one
time it matters. Set `HERMES_IMAGE_TAG` to a release tag.

> **`hermes update` refuses here, and that is correct.** Published images
> bake a read-only provenance marker; `hermes update` and the dashboard's
> Update button consult it, refuse cleanly with exit code 2, and name
> `docker pull nousresearch/hermes-agent:latest` instead. The refusal is
> based on what the running filesystem *is*, so it holds even with a source
> checkout bind-mounted in.

There is no `updates.local_images` entry in `maintenance.yaml`: this is a
registry image, not one this repo builds, so `check-updates.sh` takes its
normal pull-and-compare path.

---

## 🔌 The OpenAI-compatible API server

Off unless `API_SERVER_ENABLED=true`. You only need it if something outside
the container should talk to the gateway as if it were OpenAI — this repo's
`chat-frontends`, for instance. Chat platforms do not need it.

To listen beyond the container's own loopback, set `API_SERVER_HOST=0.0.0.0`
**and** `API_SERVER_KEY` (mandatory, minimum 8 characters —
`openssl rand -hex 32`).

---

## 🗑️ Removal

| Policy | What it does |
|:---|:---|
| **STOP** | Stop the container; everything persists |
| **TEARDOWN** | Remove the container; the data directory is untouched |
| **WIPE** | ⚠️ Deletes `HERMES_DATA_PATH` |

**WIPE here is heavier than in any other environment in this repo.** There is
no image state to lose and no volume to rebuild — the data directory *is* the
agent. Every memory, every self-written skill, every session, every
credential, and `SOUL.md`.

---

## 📚 See also

- `docs/future-enhancements/agent-control-environments.md` — why this
  environment exists and how it sits against `nanoclaw-mnemon` and
  `openclaw`.
- `environments/nanoclaw-mnemon/` — the other personal agent platform here.
  It runs on Anthropic's Claude Agent SDK; `openclaw` runs on Pi's SDK;
  Hermes runs on its own core. Three different harnesses, deliberately.
- `environments/herdr-client/` — one window over every agent environment.
  Hermes publishes no SSH port, so the session generator reports it rather
  than emitting a pane for it.
