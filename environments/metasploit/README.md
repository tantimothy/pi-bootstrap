# Metasploit

A minimal Kali Linux container dedicated to the Metasploit Framework and its
graphical front-end, Armitage.

## Why this is a separate environment (and why a custom `run.sh`)

This was split out of `kali-pentest`: `metasploit-framework` alone is
roughly 1.5-2.5GB, by far the single largest package in that environment,
and forced every `kali-pentest` CLEAN to reinstall it regardless of what
actually changed there. Isolating it here means a `kali-pentest` CLEAN never
touches Metasploit, and a `metasploit` CLEAN never touches
`kali-pentest`'s much larger tool list. Armitage came with it — it's
Metasploit's own GUI front-end (it needs a local `msfrpcd`/database to
connect to), so it can't usefully live anywhere else.

Like `kali-pentest`, this uses a custom `run.sh` (not the generic
`docker-compose.yml` fallback) because it needs host X11 socket access for
Armitage and its own config-drift fingerprinting. Unlike `kali-pentest`,
it has **no interactive attach and no in-container menu** — `msfconsole`
and Armitage are each reachable through their own `custom_action` instead.
`FAST`/`CLEAN`/`REBUILD` just deploy or reconcile the container, print the
`INFO` summary, and return to `deploy.sh`'s menu — the same shape as the
generic `docker-compose.yml`/`Dockerfile` archetype, just with the
host-level X11 wiring a custom `run.sh` is needed for.

## Tools

| Tool | Interface | Notes |
|---|---|---|
| Metasploit Framework | `custom_action` / desktop entry | `msfconsole`, launched via `scripts/start-msfconsole.sh` (starts the PostgreSQL-backed DB first if `START_METASPLOIT_DB=true`); workspace persisted to `.msf4` |
| Armitage | `custom_action` / desktop entry | Metasploit's graphical front-end; connects to a local `msfrpcd` |

## Data Directories

| Host path | Container path | Contents |
|---|---|---|
| `./.msf4` | `/root/.msf4` | Metasploit workspace, loot, credentials, history |

## Deployment Policies

| Policy | Effect |
|---|---|
| `FAST` (default) | Start the container if not running (or reconcile if already running), print the `INFO` summary, return to the menu — no interactive attach |
| `CLEAN` | `--no-cache` rebuild — reinstalls Metasploit/Armitage from scratch |
| `REBUILD` | Cached rebuild — use for `run.sh` edits only |
| `STOP` | Pause the container; resume with `FAST` |
| `TEARDOWN` | Stop and remove the container (data directories are untouched) |

## Action Menu

Three `custom_actions` (`deploy.sh`'s own policy menu, alongside FAST/CLEAN/etc.):

- **Metasploit Framework (Console)** — starts the DB (if enabled) and
  execs `msfconsole` via `docker exec -it`.
- **Open Bash Shell** — `docker exec -it` into the running container.
- **Launch Armitage (GUI)** — same command the desktop entry runs
  (`scripts/launch-armitage.sh`), reachable here too for
  SSH-with-X11-forwarding (`ssh -X`) use without a local desktop session
  to click an icon from. Run "Metasploit Framework (Console)" at least
  once first, so the database is initialized before Armitage tries to
  connect to it.

## Desktop Integration

Three desktop entries are registered (Linux only, via
`install-desktop-entries.sh`):

- **Metasploit Framework Console** — opens a terminal straight into
  `msfconsole` (same as the custom_action above).
- **Metasploit Bash Shell** — opens a terminal directly into the running
  container (`docker exec -it ... bash`).
- **Armitage** — launches Armitage directly on the host's X11/XWayland
  display via `scripts/launch-armitage.sh`.

## Useful Commands

```bash
docker exec -it ${CONTAINER_NAME:-running-metasploit-rig} /usr/local/bin/start-msfconsole.sh  # Metasploit console
docker exec -it ${CONTAINER_NAME:-running-metasploit-rig} bash                                # Open shell in running container
docker logs ${CONTAINER_NAME:-running-metasploit-rig}                                         # Container logs
```
