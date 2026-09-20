# Herdr agent state across the container boundary

**Status:** detection does **not** work for this repo's containerized
agents, and cannot without building the push path below. This document
describes what that would take.

Written after reading herdr 0.9.1's source directly (`src/detect/`,
`src/pane.rs`, `src/integration/`, `docs/.../agent-automation.mdx`).

---

## Why it does not work

Detection is **two steps, and the first gates everything**:

```rust
// 1. Which agent is this? — LOCAL PROCESS NAMES.
pub fn identify_agent_in_job(job: &ForegroundJob) -> Option<(Agent, String)>
//    walks job.processes, matches each normalized process name.
//    Plain shells and unrecognised programs return None.

// 2. What state is it in? — rendered screen + OSC.
pub fn detect_agent_with_osc(
    agent: Option<Agent>,        // <- from step 1; None means Unknown, full stop
    screen_content: &str,
    osc_title: &str,
    osc_progress: &str,
) -> AgentDetection
```

Step 2 is screen-based and would cross SSH and nested tmux happily — the
bytes arrive either way. **Step 1 does not.** In a pane running
`ssh -p 2222 claude@localhost`, the local foreground process is `ssh`.
`identify_agent("ssh")` returns `None`, so `detect_agent(None, …)` returns
`Unknown` and the per-agent manifests are never consulted.

Manifests ship for `claude`, `codex`, `pi`, `opencode` and `hermes`. None of
them are reachable from here.

Confirm on any pane:

```bash
herdr agent list                 # containerized panes do not appear
herdr agent explain w1:p1        # says why that pane has no agent
```

### This was assessed wrongly twice, in opposite directions

Recorded because the errors are instructive, and because each wrong
conclusion pointed at a different and expensive build:

1. **First: "cannot work"** — correct conclusion, wrong reason. It blamed
   `HERDR_PANE_ID` and the Unix socket, which is the *hook* path, and missed
   that ordinary detection is process-based.
2. **Then: "does work"** — found `detect_agent_with_osc` matching screen
   content and concluded the sidebar would light up, without asking what
   supplies its `agent` argument. Screen matching is real; it is just step 2.

The lesson generalises past this file: **when a function takes the thing you
are trying to explain as a parameter, the explanation is upstream of it.**

### What the `set-titles` change is, and is not, for

Every agent environment's `.tmux.conf` now sets `set-titles on` and
`set-titles-string "#{pane_title}"`, forwarding the inner application's OSC
title outward. It was added believing it enabled detection. **It does not** —
OSC title rules are step-2 rules, and step 2 never runs.

It is kept because it is harmless, gives a more useful terminal title, and
**becomes load-bearing the moment the push path below exists**. Measured per
manifest, at that point:

| Agent | OSC / total | What titles are worth once step 1 is solved |
|:---|:---|:---|
| `codex` | 3 / 9 | **`idle` becomes unreachable without them** — `osc_title_idle` is its ONLY idle rule. `working` also falls back from prio 1050 to `screen_working_fallback` at 500 |
| `claude` | 3 / 16 | Its fastest `working` path (1100) and two idle fallbacks (250). Screen rules still cover all three states |
| `pi` | 0 / 2 | Nothing |
| `opencode` | 0 / 3 | Nothing |
| `aider` | — | Nothing, ever. **Herdr ships no `aider` manifest**, so aider is undetectable even locally |

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

## Recommendation

**The cost/benefit changed when the premise did.** An earlier version of
this section said "the basic sidebar already works… the remaining delta is
reliability and session IDs" and recommended doing nothing. That was written
on the wrong premise. Without this work there is **no agent state at all**
for a containerized agent — and the state sidebar is the main thing Herdr
offers over tmux.

So the real question is not "is the extra signal worth it" but:

> **Is Herdr worth running over containerized agents if every pane is inert?**

Three honest answers, depending on what you want from it:

| If you want | Then |
|:---|:---|
| One window over several machines and repos, with labelled panes and restored layout | **Nothing to build.** That all works today, and is a real improvement over bare SSH |
| The blocked/working/idle sidebar, and Collie's "who needs me" ordering on your phone | **This has to be built**, because Collie reads the same state |
| To evaluate the agents themselves, not the multiplexer | **Run one agent on the host instead of in a container.** Detection works natively there, with zero plumbing — the cheapest way to see what the sidebar is actually like |

That third row is worth trying before building anything: it answers "is this
feature worth the machinery" empirically and costs one `npm install`.

### If it does get built

Pieces 1 and 3 are mechanical. Piece 2 needs the file-based pane ID, because
of the shared-tmux conflict above. Start with **one** agent — whichever
becomes the daily driver — since the hook format differs per agent and five
bespoke hooks is a maintenance surface this repo does not want.

**Revisit sooner if** upstream adds either a way to pin an agent kind onto an
existing pane (there is no `agent adopt` or `--kind` today) or a
network-reachable report endpoint. Either would collapse pieces 1–3 into
configuration and make this close to free.
