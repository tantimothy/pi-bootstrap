# collie-client

[Collie](https://colliepwa.dev) is a mobile web interface for terminal-based
AI agents, served over Tailscale. It bridges one multiplexer — here,
[Herdr](https://herdr.dev) — and puts the agent that needs you at the top of
a phone screen: tap it, type a normal reply with the system keyboard, send
`Esc` or `Ctrl+C` with one thumb, get a push notification when an agent
blocks.

This environment installs it on **this machine** and seeds its config.

> **Client-side.** No container runs. Nothing is deployed to a remote host.
> Same shape as `herdr-client` and `mac-terminal-setup`: it installs into
> your home directory and backs up anything it would overwrite into
> `~/.pi-bootstrap-backups/collie-client-<timestamp>/`.

---

## 🚨 Read this before deploying

**Collie is remote shell access to this machine, from a phone, by design.**
That is not a caveat this repo is adding — it is the opening line of
upstream's own security page:

> A single Collie API call sends arbitrary keystrokes directly to a live
> terminal pane. Anyone with access to the URL can read pane output (source
> code, secrets, environment variables, agent output) and execute arbitrary
> commands with your full user privileges. There is no sandbox and no
> command allow-list, as these would defeat the core workflow. Treat the URL
> as a root login.

With `herdr-client` deployed, the privilege chain is:

```
phone  →  Collie  →  Herdr  →  every agent pane
```

`run.sh` therefore asks for an explicit **yes** before the first install.
That prompt is not decoration — it is the one place this decision is made
out loud. Set `COLLIE_ACK_REMOTE_SHELL=1` in `.env` only when you are
deploying non-interactively and have read this page.

### The three mitigations, in the order they matter

| | What it does | How |
|:---|:---|:---|
| **Tailnet-only** | Keeps the URL off the public internet | `tailscale serve`, never `funnel` — `run.sh` refuses to install while any funnel is on |
| **Pairing** | The **write** credential. Until a device is paired, the write gate is **inactive** | `collie pair` — do this immediately after the first `collie start` |
| **`COLLIE_TRUSTED_USER`** | Rejects any tailnet login but yours | Set it in this environment's `.env`; `run.sh` writes it through |

Two things pairing does **not** do, worth knowing rather than discovering:
it gates writes only — **reads stay open** to anything that passes the
same-origin check — and Collie listens on a **local TCP port**, so every
local UID on this machine can read panes, where a tmux/Herdr socket would
have used filesystem permissions.

### 🚫 Never `tailscale funnel` this

`serve` restricts to your private tailnet. `funnel` publishes to the open
internet. Upstream: *"there is no supported use case for running Collie over
Funnel."*

`run.sh` does not merely avoid configuring one — it **refuses to install
while any funnel is enabled on this machine**, and names it. The check is
deliberately blunt: matching a funnel to Collie's specific backend port
means parsing Tailscale's JSON without `jq`, and a wrong parse there fails
*open*, which is the wrong direction for this particular check. If you
funnel something genuinely unrelated, check `tailscale funnel status`
yourself and set `COLLIE_ALLOW_EXISTING_FUNNEL=1`.

---

## 📋 Requirements

Every one of these is checked **before** anything is installed, and each
failure names its own fix.

| Requirement | Why | Provided by |
|:---|:---|:---|
| **Herdr** | Collie mirrors one multiplexer per install; this repo points it at Herdr | the `herdr-client` environment |
| **Tailscale, logged in** | The default front door | you (`tailscale up`) |
| **No funnel** | See above | you |
| `curl`, `tar`, `sha256sum`/`shasum` | The installer verifies its download | your OS |

| Platform | Supported | Notes |
|:---|:---|:---|
| macOS Apple Silicon | ✅ | `macos-arm64` |
| Linux arm64 (64-bit Raspberry Pi OS) | ✅ | `linux-arm64` |
| Linux x86_64 | ✅ | `linux-x64`, built against Bun's *baseline* target so it runs on pre-AVX2 hardware |
| macOS Intel | ❌ | The row exists in upstream's release matrix, **commented out**. A source build with Bun would work; that is out of scope here |
| Linux armv7l (32-bit Pi OS) | ❌ | No build; `run.sh` fails with the reason rather than letting the installer fail obscurely |

---

## 🚀 What a deploy does

1. Checks the preconditions above. Any failure stops here, having installed
   nothing.
2. Asks for consent (first install only).
3. Installs with the **official installer**, which downloads the release
   tarball *and* its `.sha256` sidecar, refuses to install anything it
   cannot verify, never asks for `sudo`, and writes only inside
   `~/.local/share/collie` and `~/.local/bin`. Adding our own checksum step
   would be redundant — the same conclusion `herdr-client` reached.
4. Seeds `~/.config/collie/.env` with `COLLIE_MUX=herdr`, `COLLIE_PORT`, and
   `COLLIE_TRUSTED_USER` if you set one.

It does **not** start Collie. Starting publishes a URL that is a root login
to this machine; that is your call, made deliberately, not a side effect of
a deploy.

```bash
collie start        # build if needed, serve, print the tailnet URL
collie pair         # ⚠️  next — the write credential
collie qr           # the URL as a scannable code
```

### The config file is seeded, never overwritten

`run.sh` adds only keys that are **absent**, and reports (without changing)
any key already set to something different.

That is not politeness. `~/.config/collie/.env` is the same file
`collie push-keys` writes the VAPID keypair into and `collie start` writes
`COLLIE_MUX` into. A deploy that rewrote it would silently destroy push
notifications, and the failure would show up days later as "notifications
stopped working" with nothing pointing back here.

---

## 🎛️ Deployment Policies

| Policy | What it does |
|:---|:---|
| **FAST** | Check preconditions; install if missing; seed the config. Leaves an existing install alone. Does not start Collie. |
| **CLEAN** | Stop first, **then** move the version — `collie update` when unpinned, or the installer at `COLLIE_TAG`. Leaves it stopped. |
| **STOP** | `collie stop` **and** `collie unserve`. |
| **TEARDOWN** | STOP, then `collie uninstall` (service definition + serve mapping), then remove the binary and config. |

### Why STOP does two things

`collie stop` pauses the bridge but leaves the `tailscale serve` mapping
published — the tailnet URL would stay mapped to a dead port. "Stopped"
would mean *broken*, not *unreachable*. `collie unserve` withdraws the
mapping, and only ever one Collie created.

### Why CLEAN stops before upgrading

Upstream is explicit that a Collie replaced on disk *"keeps serving the old
build on a deleted binary until you restart it"*. That is exactly the
silently-stale-copy failure this repo has been bitten by before — see
`docs/lessons-learned/nanoclaw-mnemon.md`, where a patched base image passed
every check while the running agent used a two-week-old copy. Stopping first
makes it impossible rather than merely unlikely.

### What TEARDOWN deliberately leaves behind

`~/.local/state/collie` — paired-device credentials, agent beacons, uploads,
and `audit.log`.

Deleting pairings silently **disables the write gate** (it is active only
while at least one device is paired), and `audit.log` is the only record of
what was typed into your panes. Remove it by hand when you mean to.

> **Known wording bug:** `deploy.sh`'s STOP confirmation is hardcoded
> per-policy and reads *"Pause \[env]'s running container(s)?"*. There are no
> containers here. The prompt is wrong; the behaviour above is right. Same
> note applies to `herdr-client`.

---

## 🔗 How this fits the rest of the repo

```
phone ──tailnet──▶ collie-client ──socket──▶ herdr-client ──ssh──▶ agent containers
                                                   ▲
                          scripts/generate-session.sh puts the panes there
```

`herdr-client`'s session generator emits **SSH panes** rather than
`docker exec` panes, even for containers on this same machine. Collie is
precisely why: it inherits whatever the Herdr account can do, so keeping the
phone-reachable path pointed at an unprivileged container account — instead
of at the container runtime, which on Linux means the `docker` group and
therefore effectively root — is worth a local SSH hop.

**`herdr-client`'s STOP kills the server Collie bridges.** Collie will still
be running; it will just have nothing to show. `run.sh` reports a missing
Herdr socket rather than leaving you to work that out.

---

## 📚 See also

- `environments/herdr-client/` — the multiplexer Collie mirrors. Deploy it
  first.
- `docs/future-enhancements/agent-control-environments.md` — the full design
  reasoning and the settled decisions behind these choices.
- Upstream, offline and out of the binary: `collie docs --all`,
  `collie skill`.
