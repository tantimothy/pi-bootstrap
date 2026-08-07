**Not a patch — a host dependency.** Ollama is a single native process on the
host, outside every container, shared by mnemon's embeddings, the Ollama MCP
tool, and any other AI environment on this machine. It is included here because
when it is misconfigured the symptoms appear entirely inside containers, and
nothing on the host looks wrong at all.

**Why the status above is worth having.** You are reading this from inside a
container. You cannot run `lsof`/`ss` against the host, so you cannot see what
address the daemon is bound to — which is the single most useful fact for
diagnosing `ollama_available: false`. The deploy runs on the host, so it records
what it saw there. Treat it as a snapshot from deploy time, not live truth.

**The failure this exists for.** Ollama's default bind is `127.0.0.1:11434` —
loopback only. A container reaching `host.docker.internal:11434` arrives at the
host as *external* traffic and is refused. Meanwhile every host-side check
passes, because they all probe `localhost`. That asymmetry cost five rounds of
misdiagnosis: `curl` from inside an agent container appeared to succeed, but
only because it was routing through a host-side HTTP proxy that *can* reach
loopback, while mnemon's Go client went direct and was refused. **Two different
network paths to the same URL — one working tells you nothing about the other.**

**What you can actually test from in here.** Run this in a live agent container
(not the orchestrator), forcing a direct connection so no proxy can mask the
result:

```
curl -s -o /dev/null -w '%{http_code}\n' --noproxy '*' http://host.docker.internal:11434/api/tags
```

- **`200`** — the daemon is reachable from containers. If mnemon still reports
  `ollama_available: false`, that is a genuinely new finding: connectivity is
  fine and the fault is elsewhere. Say so plainly rather than reaching for the
  proxy explanations below, which have all been ruled out.
- **`000`** — no connection at all. Almost always a loopback-bound daemon.
  Compare against the recorded listen address above.

**Fixing it is a host action; you cannot do it from a container.** Report it and
let a human run it. What that involves, and why it is not one command:

- The value lives in `environments/ollama/.env` as `OLLAMA_SERVE_HOST`
  (e.g. `0.0.0.0:11434`), and a redeploy of the `ollama` environment applies it.
  Note this also exposes Ollama to the local network, so it is a deliberate
  choice, not a default.
- **A service supervisor may override it and silently win.** On macOS,
  Homebrew's service definition carries its own environment that beats
  `launchctl setenv`, and `brew services start` regenerates its plist from the
  formula every time — so hand-editing that plist is reverted on the next start.
  Where supervision cannot honour the configured address, the deploy stops the
  service and runs Ollama directly instead, and says so. On Linux a systemd
  drop-in *is* supported, so the unit keeps its restart-on-crash.
- **A supervisor can also resurrect it faster than you can reconfigure it.** A
  real host respawned Ollama on loopback within two seconds of every `pkill`,
  so each attempted fix added a *second* daemon rather than replacing the first
  — leaving one wide IPv6 listener and one loopback IPv4 listener, with
  containers still refused because they dial IPv4.

**So when the status above reports two listeners, do not read that as "fine,
something is bound wide".** It means two daemons are fighting over the port and
a container can still be refused. It needs the same host-side attention as the
loopback-only case.

**One thing that is genuinely not your problem:** the `NO_PROXY` handling in the
mnemon patch. It was blamed for `ollama_available: false` through four rounds of
changes in both directions and was never the cause. Check the bind address
first, every time.
