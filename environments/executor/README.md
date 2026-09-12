# Executor — MCP Gateway

[Executor](https://github.com/RhysSullivan/executor) is an **MCP gateway**:
one endpoint fronting every integration, with credentials held server-side
and per-tool **allow / require-approval / block**. Agents point at it instead
of each holding its own copy of every token.

Single container — the typed API, the MCP server, Better Auth, QuickJS code
execution and the web UI, all in one process over a libSQL (SQLite) file. No
external database, worker or proxy, no build, and nothing bind-mounted from
the host.

Plain `docker-compose.yml`, no `run.sh`.

---

## 🖥️ Host this on the Mac, not the Pi

The moment Mac-hosted agents depend on it, the Pi stops being something you
can switch off — and **keeping the Pi removable is an explicit constraint of
this whole design.** Keep the Pi leaf-shaped: environments that are
self-contained, or used only by other Pi-hosted things.

See `docs/future-enhancements/agent-control-environments.md`, "The Pi must
remain removable".

---

## 🚪 First run is a one-shot decision

A fresh instance shows a setup screen, and **the first person to create an
account becomes the owner**. Self-service signup then closes *permanently*;
everyone else joins by single-use invite minted from the **Admin** page.

**Create your account before anything else can reach the port.** There is no
second chance and no "reset to first-run" short of wiping the data volume.

If you would rather not have a browser step at all — a scripted deploy, for
instance — set `EXECUTOR_BOOTSTRAP_ADMIN_EMAIL` **and**
`EXECUTOR_BOOTSTRAP_ADMIN_PASSWORD` and the admin is pre-created headlessly.
For a single-operator deploy the browser flow is simpler.

```bash
curl localhost:4788/api/setup-status   # has the owner account been created?
```

---

## ⚠️ The data volume is the credentials

`${CONTAINER_NAME}_data` holds the SQLite database **and** the generated
secret-encryption key that protects the credentials inside it.

**Losing it loses every stored credential at once, for every agent pointed
here**, and they are not recoverable from anywhere else. That is the whole
cost of consolidating credentials into one gateway — a benefit and a single
point of failure in the same sentence.

Set `BETTER_AUTH_SECRET` (and `EXECUTOR_SECRET_KEY`) yourself if you want
those managed outside the volume. Note that rotating `BETTER_AUTH_SECRET`
signs every user out.

---

## 🌐 `EXECUTOR_WEB_BASE_URL` — the most common way this looks broken

It must match **scheme + host + port exactly** as you type it into the
browser, or browser logins are rejected with nothing obviously wrong.

Leave it unset while you reach Executor at `http://localhost:4788`. Set it
the moment there is a domain, TLS, or a different port in front.
`EXECUTOR_TRUSTED_ORIGINS` adds extra origins allowed to authenticate,
without moving the OAuth callbacks — those stay pinned to
`EXECUTOR_WEB_BASE_URL`.

---

## 🔓 The two switches that widen what Executor can reach

Both are **off by default upstream and stay off here**.

| Variable | What it opens up |
|:---|:---|
| `EXECUTOR_ALLOW_LOCAL_NETWORK` | Lets sandboxed code reach loopback and private addresses. Upstream's reason for the default: *"adversarial generated code should not reach your internal network"* |
| `EXECUTOR_ALLOW_STDIO_MCP` | Lets users configure MCP servers whose commands **execute on this host**. Upstream: *"trusted deployments only"*. Only honoured when set to the exact string `true` |

Neither is abstract here. `EXECUTOR_ALLOW_LOCAL_NETWORK` covers exactly the
network `ollama`, `llm-gateways`, `nanoclaw-mnemon` and every agent container
live on. And while `EXECUTOR_ALLOW_STDIO_MCP`'s blast radius is only the
container, that container holds every credential you gave Executor.

---

## 🔌 Why the port is published on all interfaces

Unlike `hermes`, this one does **not** bind to the host's loopback by
default. That is deliberate.

The point of Executor is that **other containers** reach it, and they do so
through `host.docker.internal` — which resolves to a host-gateway address,
not to the host's loopback. Binding to `127.0.0.1` would make it unreachable
from exactly the agents it exists to serve. `llm-gateways` publishes the same
way for the same reason.

What protects it is **Executor's own gate**: the first account created
becomes owner and signup then closes, so there is no window in which an
unauthenticated stranger can use it. Contrast `hermes`, whose dashboard auth
is opt-in and therefore needs the bind to do the work.

Set `EXECUTOR_BIND_ADDRESS=127.0.0.1` if only host processes need it.

---

## 🤝 Who actually points at this

| Agent | How it reaches Executor |
|:---|:---|
| `pi` | Through `mcporter` — no native MCP by design, so MCP stays a command |
| `opencode` | Native MCP, directly |
| `claude-cli`, `codex-cli` | Native MCP, directly |
| `aider` | **Neither, deliberately** — see settled decision 7 |

`aider` is a `python:3.12-slim` image, and giving it MCP would mean adding a
whole Node runtime for one tool. The design doc records a plausible escape
hatch (`mcporter generate-cli --compile` producing a static binary), but
flags it as **designed, not demonstrated** — nobody has built it, and it
cannot be tested until this environment exists to point it at.

> **Sequenced last on purpose.** Executor was the easiest of these
> environments to build, which made it tempting to lead with — but its whole
> pitch is consolidating credentials across agents that did not exist yet.
> For a single operator still evaluating candidates, it is the *last* thing
> that pays.

---

## 🗑️ Removal

| Policy | What it does |
|:---|:---|
| **STOP** | Stop the container; everything persists |
| **TEARDOWN** | Remove the container; the volume survives |
| **WIPE** | ⚠️ Deletes the data volume — see above |

---

## 📚 See also

- `docs/future-enhancements/agent-control-environments.md` — the full design
  reasoning, settled decision 7 on `aider`, and why this was sequenced last.
- `environments/pi/` — the one agent here that reaches Executor through
  `mcporter` rather than natively.
- `environments/llm-gateways/` — the other shared service in this repo, and
  the precedent for how this one publishes its port.
