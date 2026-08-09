# Kali Legion

A minimal Kali Linux container dedicated to Legion, a graphical automated
network reconnaissance tool.

## Why this is a separate environment (and why a custom `run.sh`)

This was split out of `kali-pentest`: once that environment's grouped
Forensics apt layer was split per-tool to find its actual bottleneck,
Legion alone took roughly 1900s (32+ minutes) in a real build — by far the
single largest cost remaining in that environment, and unrelated to
WiFi/network tooling itself (Legion's Kali package pulls a fairly heavy
Python/Qt GUI plus a bundled recon-module dependency tree). Isolating it
here means a `kali-pentest` CLEAN never touches Legion, a `kali-legion`
CLEAN never touches `kali-pentest`'s much larger tool list, and Legion can
be deployed standalone on its own, independent of the rest of `kali-pentest`.

Like `kali-pentest`, this uses a custom `run.sh` (not the generic
`docker-compose.yml` fallback) because it needs host X11 socket access for
Legion's GUI and its own config-drift fingerprinting. Unlike `kali-pentest`,
it has **no interactive attach and no in-container menu** — Legion is
GUI-only, with no CLI/TUI of its own to put behind one. `FAST`/`CLEAN`/
`REBUILD` just deploy or reconcile the container, print the `INFO` summary,
and return to `deploy.sh`'s menu — the same shape as the generic
`docker-compose.yml`/`Dockerfile` archetype, just with the host-level X11
wiring a custom `run.sh` is needed for.

## Tools

| Tool | Interface | Notes |
|---|---|---|
| Legion | Desktop entry / `custom_action` | Graphical automated recon — runs Nmap/NSE scans and launches follow-up scripts against discovered open ports. No CLI/TUI mode of its own. |

## Data Directories

None — Legion's own data-storage location isn't reliably documented
upstream, and this environment's predecessor in `kali-pentest` never
persisted it either. `WIPE` is a no-op here as a result.

## Deployment Policies

| Policy | Effect |
|---|---|
| `FAST` (default) | Start the container if not running (or reconcile if already running), print the `INFO` summary, return to the menu — no interactive attach |
| `CLEAN` | `--no-cache` rebuild — reinstalls Legion from scratch |
| `REBUILD` | Cached rebuild — use for `run.sh` edits only |
| `STOP` | Pause the container; resume with `FAST` |
| `TEARDOWN` | Stop and remove the container |
| `INFO` | Data directories and useful commands (there are none of the former) |

## Action Menu

Two `custom_actions` (`deploy.sh`'s own policy menu, alongside FAST/CLEAN/etc.):

- **Open Bash Shell** — `docker exec -it` into the running container. The
  only way to get a shell here, since `FAST` no longer attaches interactively.
- **Launch Legion (GUI)** — same command the desktop entry runs
  (`scripts/launch-legion.sh`), reachable here too for SSH-with-X11-forwarding
  (`ssh -X`) use without a local desktop session to click an icon from.

## Desktop Integration

Two desktop entries are registered (Linux only, via
`install-desktop-entries.sh`):

- **Kali Legion Bash Shell** — opens a terminal directly into the running
  container (`docker exec -it ... bash`).
- **Legion** — launches Legion directly on the host's X11/XWayland display
  via `scripts/launch-legion.sh`.

## Useful Commands

```bash
docker exec -it ${CONTAINER_NAME:-running-legion-rig} bash  # Open shell in running container
docker logs ${CONTAINER_NAME:-running-legion-rig}           # Container logs
```
