# Kali Metasploit

A minimal Kali Linux container dedicated to the Metasploit Framework and its
graphical front-end, Armitage.

## Why this is a separate environment (and why a custom `run.sh`)

This was split out of `kali-pentest`: `metasploit-framework` alone is
roughly 1.5-2.5GB, by far the single largest package in that environment,
and forced every `kali-pentest` CLEAN to reinstall it regardless of what
actually changed there. Isolating it here means a `kali-pentest` CLEAN never
touches Metasploit, and a `kali-metasploit` CLEAN never touches
`kali-pentest`'s much larger tool list. Armitage came with it — it's
Metasploit's own GUI front-end (it needs a local `msfrpcd`/database to
connect to), so it can't usefully live anywhere else.

Like `kali-pentest`, this uses a custom `run.sh` (not the generic
`docker-compose.yml` fallback) because it needs an interactive attach/reattach
session and host X11 socket access for Armitage.

## Tools

| Tool | Interface | Notes |
|---|---|---|
| Metasploit Framework | In-container menu (option 2) | `msfconsole`; PostgreSQL-backed workspace persisted to `.msf4` |
| Armitage | Desktop GUI entry | Metasploit's graphical front-end; connects to a local `msfrpcd` |

## Data Directories

| Host path | Container path | Contents |
|---|---|---|
| `./.msf4` | `/root/.msf4` | Metasploit workspace, loot, credentials, history |

## Deployment Policies

| Policy | Effect |
|---|---|
| `FAST` (default) | Reattach to the running container without rebuilding |
| `CLEAN` | `--no-cache` rebuild — reinstalls Metasploit/Armitage from scratch |
| `REBUILD` | Cached rebuild — use for `entrypoint.sh`/`run.sh` edits only |
| `STOP` | Pause the container; resume with `FAST` |
| `TEARDOWN` | Stop and remove the container (data directories are untouched) |

## Desktop Integration

Two desktop entries are registered (Linux only, via
`install-desktop-entries.sh`):

- **Kali Metasploit Terminal** — opens the in-container tool menu.
- **Armitage** — launches Armitage directly on the host's X11/XWayland
  display via `scripts/launch-armitage.sh`. Run the terminal entry and start
  Metasploit Framework (menu option 2) at least once first, so the database
  is initialized before Armitage tries to connect to it.

## Useful Commands

```bash
docker exec -it ${CONTAINER_NAME:-running-metasploit-rig} bash                          # Open shell in running container
docker exec -it ${CONTAINER_NAME:-running-metasploit-rig} /usr/local/bin/entrypoint.sh  # Re-launch entrypoint
docker logs ${CONTAINER_NAME:-running-metasploit-rig}                                   # Container logs
```
