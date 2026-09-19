# Herdr agent state across the container boundary

**Status:** the basic signal already works and needs nothing. This document
is about the *enhanced* signal, which does not cross — what it would take,
and why it is not obviously worth doing.

Written after reading herdr 0.9.1's source directly (`src/detect/`,
`src/pane.rs`, `src/integration/`, `docs/.../agent-automation.mdx`) rather
than inferring from behaviour.

---

## What already works, and why

Herdr detects an agent's state by **matching the rendered screen**, not by
inspecting processes:

```rust
pub fn detect_agent_with_osc(
    agent: Option<Agent>,
    screen_content: &str,
    osc_title: &str,
    osc_progress: &str,
) -> AgentDetection
```

Per-agent regex manifests live in `src/detect/manifests/*.toml` and match
the agent's own TUI — spinner glyphs, `esc to interrupt`, prompt shapes.

**Rendered bytes cross SSH and nested tmux unchanged**, so a containerized
agent lights up the sidebar exactly like a local one. Manifests ship for
every agent this repo deploys: `claude`, `codex`, `pi`, `opencode`,
`hermes`.

This was initially — and wrongly — assessed the other way round in this
repo's own notes, on the assumption that detection was process- or
environment-based. It is not. Recording the correction here because the
wrong conclusion would have justified a large and pointless build.

### The one screen-adjacent gap, now closed

OSC **title** and **progress** sequences are a separate detection region,
and tmux owns the outer terminal title — by default it reports itself, so
title-region rules silently never fire through a container's tmux.

A minority of rules, but not evenly distributed:

| Agent | OSC-title rules / total |
|:---|:---|
| `claude` | 2 / 16 |
| `codex` | 3 / 9 — including its highest-priority `working` rule |
| `pi` | 0 / 2 |
| `opencode` | 0 / 3 |

Without forwarding, a busy `codex` can read as idle. Every agent
environment's `.tmux.conf` now sets:

```tmux
set -g set-titles on
set -g set-titles-string "#{pane_title}"
```

**Unverified against a real Herdr session** — it follows from how tmux
titles work, not from an observed sidebar change. Worth confirming on the
first real use, and the cheapest confirmation is watching whether `codex`
shows `working` while it is plainly working.

---

## What does not cross: the hook integrations

`herdr integration install <claude|codex|pi|opencode|hermes|…>` writes a
hook into the agent's own configuration. The hook calls
`herdr pane report-agent-session <pane_id>` back over `HERDR_SOCKET_PATH`,
using the `HERDR_PANE_ID` that Herdr injects into the pane process
(`src/pane.rs:168`).

All three legs break at the container boundary:

| Needed | Reality here |
|:---|:---|
| `HERDR_PANE_ID` visible to the agent | Set on the **ssh client** on the host. The images set no `AcceptEnv`, so it never crosses |
| A `herdr` binary where the agent runs | Not in any image |
| A reachable `HERDR_SOCKET_PATH` | A Unix socket on the host |

What that costs is the **enhanced** signal: agent session IDs, and faster,
more reliable state transitions than screen-matching infers. Not the basic
sidebar.

---

## What closing it would take

Three mechanical pieces, and one that is not mechanical at all.

1. **Forward the socket.** `ssh -R /tmp/herdr.sock:$HERDR_SOCKET_PATH …`
   (OpenSSH has supported remote Unix-socket forwards since 6.7), with
   `HERDR_SOCKET_PATH=/tmp/herdr.sock` inside the container.
2. **Carry the pane ID.** `AcceptEnv HERDR_PANE_ID` in each image's
   `sshd_config`, plus `-o SendEnv=HERDR_PANE_ID` from the generator.
3. **Put `herdr` in each image** and run `herdr integration install <kind>`
   once inside it. Herdr publishes an `aarch64-unknown-linux-musl` build,
   so this is a binary fetch, not a Rust toolchain.

### The part that is not mechanical

**A long-lived shared tmux session has one environment; Herdr's model is one
pane per agent.**

Every agent environment here auto-attaches SSH logins to a *persistent*
tmux session. The agent process inside it was started once, with whatever
environment existed at that moment. A later SSH connection carrying a
different `HERDR_PANE_ID` cannot change the environment of an
already-running process — and two Herdr panes onto the same container would
disagree about which pane ID is current.

So piece 2 does not actually work as stated. The options are:

- **Write the pane ID to a file** on each SSH connection
  (`/run/herdr-pane-id`) and install a *custom* hook that reads the file
  instead of the env var. Works, but replaces the upstream hook with one
  this repo maintains — against five agents whose hook formats differ.
- **Give up the shared session** so each Herdr pane starts its own agent
  process with its own pane ID. Restores upstream semantics exactly, and
  throws away the persistence that is the main reason the containers run
  tmux at all.

---

## Recommendation: don't, yet

The basic sidebar already works, which was the actual goal. The remaining
delta is reliability and session IDs, and the honest price is either a
bespoke hook per agent or losing session persistence.

**Revisit when** one of these is true:

- screen-based detection proves unreliable in practice for an agent
  actually in daily use — measurable, and the only evidence that would
  justify the cost;
- a single agent becomes the clear daily driver, making a one-agent custom
  hook a much smaller commitment than five;
- upstream adds a way to set a pane ID on an existing agent, or a
  network-reachable report endpoint, which would collapse pieces 1–3 into
  configuration.

**Check first, cheaply:** confirm the `set-titles` change fixes `codex`'s
title-based `working` rule. If it does, the gap is narrower than this
document assumes, and the case for building anything gets weaker still.
