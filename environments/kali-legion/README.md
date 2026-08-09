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
`docker-compose.yml` fallback) because it needs an interactive attach/reattach
session and host X11 socket access for Legion's GUI.

## Tools

| Tool | Interface | Notes |
|---|---|---|
| Legion | Desktop GUI entry | Graphical automated recon — runs Nmap/NSE scans and launches follow-up scripts against discovered open ports. No useful CLI/TUI mode of its own, so there's no in-container menu option to launch it — only the desktop entry / `scripts/launch-legion.sh`. |

## Data Directories

None — Legion's own data-storage location isn't reliably documented
upstream, and this environment's predecessor in `kali-pentest` never
persisted it either. `WIPE` is a no-op here as a result.

## Deployment Policies

| Policy | Effect |
|---|---|
| `FAST` (default) | Reattach to the running container without rebuilding |
| `CLEAN` | `--no-cache` rebuild — reinstalls Legion from scratch |
| `REBUILD` | Cached rebuild — use for `entrypoint.sh`/`run.sh` edits only |
| `STOP` | Pause the container; resume with `FAST` |
| `TEARDOWN` | Stop and remove the container |

## Desktop Integration

Two desktop entries are registered (Linux only, via
`install-desktop-entries.sh`):

- **Kali Legion Terminal** — opens the in-container tool menu (Environment
  Info / Bash Shell / Detach — there's nothing else to launch from here).
- **Legion** — launches Legion directly on the host's X11/XWayland display
  via `scripts/launch-legion.sh`.

## Useful Commands

```bash
docker exec -it ${CONTAINER_NAME:-running-legion-rig} bash                          # Open shell in running container
docker exec -it ${CONTAINER_NAME:-running-legion-rig} /usr/local/bin/entrypoint.sh  # Re-launch entrypoint
docker logs ${CONTAINER_NAME:-running-legion-rig}                                   # Container logs
```
