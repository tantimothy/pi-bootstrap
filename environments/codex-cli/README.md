# Codex CLI

A standalone Codex CLI container with its own SSH server. SSH in from any
machine and land in a persistent `tmux` session running `codex` against a
bind-mounted repository. It mirrors the remote-terminal workflow of the
`claude-cli` environment without NanoClaw, chat bots, or an orchestrator.

## Supported hosts

The same environment runs on:

- **64-bit Raspberry Pi OS** on an ARM64 Raspberry Pi.
- **macOS on Apple silicon or Intel**, using Docker Desktop, OrbStack, or
  another Docker-compatible Linux VM with Compose support.

OpenAI's standalone Codex installer currently publishes Linux binaries for
ARM64 and x86-64, so a 32-bit ARM Raspberry Pi OS installation is not
supported. Use the 64-bit Raspberry Pi OS image.

Nothing in this folder is tied to the Mac where the repository was edited.
Run deployment commands on the Raspberry Pi or Mac that will host the
container. On macOS, desktop-menu installation is intentionally skipped
because XDG `.desktop` entries are Linux-only; SSH, tmux, persistence,
backup metadata, and the deployment menu still work.

## Requirements

On the Raspberry Pi or Mac that will run the environment:

- Docker Engine with the Compose plugin, Docker Desktop, OrbStack, or another
  Docker-compatible runtime with Compose support.
- A 64-bit ARM64 or x86-64 operating system.
- A host directory to mount as the Codex workspace.
- A real `authorized_keys` file containing the public keys allowed to log in.
- Network access during the image build so the official Codex installer and
  Debian packages can be downloaded.
- A supported Codex authentication method: ChatGPT sign-in through the
  device-code flow, an OpenAI API key, or an access token.

The target Mac does not need any state from the Mac where this repository was
edited. Clone or copy the repository to the target and configure that host's
own paths, UID, and GID.

## Deploy

Clone or copy `pi-bootstrap` onto the **target host**. From its repository
root, run `./deploy.sh`, select **codex-cli**, fill in the environment
values, and choose FAST or CLEAN. Or configure it directly:

```bash
cd environments/codex-cli
cp .env.example .env
mkdir -p ~/codex-cli-workspace
docker compose up -d --build
```

The defaults expose the container's SSH server on host port `2224` and mount
`~/codex-cli-workspace` at `/home/codex/workspace`.

Set `PUID` and `PGID` from the target host:

```bash
id -u
id -g
```

Raspberry Pi OS commonly reports `1000:1000`; macOS commonly reports
`501:20`. Both are supported. The entrypoint deliberately reuses an existing
container group when the requested numeric GID already exists, which avoids
the Debian/macOS GID 20 collision.

Ensure the target host has the configured public-key file. If a new Mac
does not already have one:

```bash
mkdir -p ~/.ssh
touch ~/.ssh/authorized_keys
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
```

Add the public key of each client that should be allowed to connect.

## First login

Codex's browser callback is awkward in a headless container, so use its
[official device-code flow](https://developers.openai.com/codex/auth):

```bash
docker exec -u codex -it codex-cli codex login --device-auth
```

Open the displayed URL on any browser, enter the one-time code, and finish
sign-in. You can also use the **Codex Device-Code Login** custom action in
`deploy.sh`.

Device-code login must be enabled in your ChatGPT security settings or by
your workspace admin. If it is unavailable, authenticate on a local machine
and securely copy `~/.codex/auth.json`, or set `OPENAI_API_KEY` in `.env`.
API-key usage is billed through the API account rather than ChatGPT plan
credits.

Then connect:

```bash
ssh -p 2224 codex@localhost
```

From another computer, replace `localhost` with the Raspberry Pi or target
Mac's hostname or LAN IP:

```bash
ssh -p 2224 codex@target-host.local
```

The first interactive connection starts Codex in `~/workspace`. Later
connections attach to a grouped tmux session. A dropped network connection
does not stop Codex, and simultaneous SSH clients may view different tmux
windows while sharing the same base session.

Detach with `Ctrl-b d`. On a container restart, the tmux process ends; the
next connection runs `codex resume --last`, falling back to a new session
when no saved conversation exists.

To choose an older saved conversation instead of automatically resuming the
most recent one, first open a plain shell as described below and run:

```bash
codex resume
```

Codex will display its normal saved-session picker. Saved sessions live under
the persistent `$CODEX_HOME`, so they remain available after container
recreation and CLEAN rebuilds.

## Plain shell access

An interactive SSH login intentionally enters the persistent Codex tmux
session. Use any of these methods when you need a regular shell:

- From inside tmux, press `Ctrl-b c` to create another window. Change windows
  with `Ctrl-b n` and `Ctrl-b p`.
- Run a noninteractive SSH command:

  ```bash
  ssh -p 2224 codex@target-host.local 'command'
  ```

- Start a shell directly from the Docker host:

  ```bash
  docker exec -u codex -it codex-cli bash
  ```

The direct shell is useful for commands such as `codex resume`, `codex mcp`,
`gh auth status`, and editing persistent user configuration.

## Why the container runs its own SSH server

The container-owned `sshd` gives every client the same stable entry point and
lets interactive connections attach directly to the shared tmux environment.
It also:

- works without installing Codex, tmux, or special shell hooks on the host;
- supports SSH-agent forwarding into the container;
- keeps the allowed login keys scoped to this environment;
- behaves the same on Raspberry Pi OS and inside a macOS Docker VM; and
- lets the container be stopped, recreated, backed up, or moved independently
  of the host's own SSH configuration.

This SSH port is a real network service. See Security below before exposing it
outside a trusted LAN.

## Persistence

Three named volumes are scoped by `CONTAINER_NAME`:

- `${CONTAINER_NAME}_user_home` stores the rest of `/home/codex`, including
  runtime changes to shell/tmux dotfiles, `~/.gitconfig`, `~/.config`,
  SSH configuration and `known_hosts`, personal guidance and skills under
  `~/.agents`, and other user-created settings.
- `${CONTAINER_NAME}_codex_home` is nested at `~/.codex` and stores the
  complete `$CODEX_HOME` runtime state: authentication, `config.toml`, rules,
  plugins, MCP registrations and OAuth state, memories, automations,
  attachments, caches, and saved sessions.
- `${CONTAINER_NAME}_ssh_host_keys` preserves the SSH server fingerprint.

The workspace is a host bind mount and is never removed by this environment's
WIPE action. Repository-scoped Codex settings such as `.codex/config.toml`,
skills, and `AGENTS.md` live in that workspace and therefore persist with it.

The Codex executable itself is deliberately installed under `/opt/codex`,
outside all persistent volumes. OpenAI's standalone installer normally keeps
release packages under `$CODEX_HOME/packages/standalone`. At container
startup, the entrypoint exposes the image-managed standalone tree at that
required runtime path with a symbolic link. This makes commands such as
`codex remote-control` see a valid installer-managed release while a CLEAN
rebuild still installs the image's new Codex release without discarding or
accidentally pinning persistent runtime settings.

The standalone tree under `/opt/codex` is writable by the runtime `codex` user
so Codex can update its managed app-server files. Those program files belong
to the container image and are reinstalled by a CLEAN rebuild. Authentication,
configuration, plugins, MCP state, and saved sessions remain in the persistent
`~/.codex` volume.

FAST, STOP, container recreation, and CLEAN rebuilds preserve all three named
volumes. Only the explicit WIPE action (or manual Docker volume deletion)
removes them.

This persistence covers user and Codex configuration created at runtime. As
with any container image, root-level operating-system changes such as
manually installed `apt` packages or edits under `/etc` do not survive a
rebuild; add those reproducibly to the Dockerfile instead.

### Persistence matrix

| State | Location | Survives CLEAN rebuild? | Removed by WIPE? |
|---|---|---:|---:|
| Codex authentication, `config.toml`, rules, plugins, MCP registrations and sessions | `${CONTAINER_NAME}_codex_home` | Yes | Yes |
| Shell/tmux settings, Git configuration, SSH client state, `~/.config`, and `~/.agents` | `${CONTAINER_NAME}_user_home` | Yes | Yes |
| SSH server identity | `${CONTAINER_NAME}_ssh_host_keys` | Yes | Yes |
| Repository and repository-scoped Codex configuration | `CODEX_WORKSPACE_PATH` bind mount | Yes | No |
| Codex executable and Debian packages | Container image | Reinstalled | Reinstalled |
| Manual edits under `/etc` or ad hoc `apt` installs | Container writable layer | No | Not applicable |

Changing `CONTAINER_NAME` selects a new set of named volumes; it does not
rename or migrate the old ones. Treat a container-name change as creating a
new instance unless you explicitly migrate the volumes.

## GitHub access

SSH agent forwarding keeps private keys on the client:

```bash
ssh -A -p 2224 codex@your-pi
```

Alternatively set `GH_TOKEN` in `.env`. The entrypoint configures `gh` as
Git's HTTPS credential helper. Set `GIT_USER_NAME` and `GIT_USER_EMAIL` if
Codex should create commits.

## Model selection

Leave `CODEX_MODEL` unset to use Codex's default. To pin a model, use the
**Choose Codex Model** action, edit `.env`, or pass a model directly:

```bash
codex --model <model-id>
```

Use `/model` inside Codex to see models available to the signed-in account.
A model changed in `.env` takes effect after the container restart creates a
new base tmux session.

Codex also supports local providers such as Ollama or LM Studio through its
own CLI options and custom remote providers through `model_providers` in
`~/.codex/config.toml`. This environment does not currently provide the
Claude environment's gateway picker/revert scripts. Do not copy its
`ANTHROPIC_BASE_URL` or `ANTHROPIC_AUTH_TOKEN` settings: those are
Claude-specific. A Codex implementation should use named Codex provider
profiles, provider-specific credential environment variables, and an explicit
way to return to the default OpenAI profile. See the
[Codex configuration reference](https://developers.openai.com/codex/config-reference)
before configuring a provider manually.

## Multiple instances

Run:

```bash
./new-instance.sh
```

The wizard copies the environment, assigns a free SSH port, creates a
separate workspace and named volumes, registers the copy in
`config/environments.yaml`, and deploys it. Each instance has independent
Codex authentication, configuration, sessions, and SSH identity.

The copied instance is also a separate Compose project. Its `CONTAINER_NAME`
drives its three volume names, so CLEAN, WIPE, backup, and authentication
state remain isolated from sibling instances.

## Remote access

### SSH over a LAN or VPN

Connect from another machine using the target host's LAN or VPN address:

```bash
ssh -A -p 2224 codex@target-host.local
```

A mesh VPN such as Tailscale or a conventional private VPN is preferable when
accessing the environment away from home. A phone or tablet can use any SSH
client that supports public-key authentication and, if needed, tmux.

Avoid forwarding `SSH_PORT` directly from an internet router unless you
deliberately want to operate a public SSH service. Key-only authentication
substantially reduces password attacks, but it does not eliminate the need for
firewalling, key rotation, updates, and log monitoring.

### Codex remote control

Current Codex CLI releases expose an **experimental** `codex remote-control`
command with `start`, `stop`, and `pair` operations. It is not the same
feature or protocol as Claude Code's `/remote-control`, and the Claude
subscription and `claude.ai/code` instructions do not transfer.

The official standalone installation is included at the fixed path beneath
`$CODEX_HOME` required by remote control. After authenticating Codex, start
and pair it from a plain container shell:

```bash
codex remote-control start
codex remote-control pair
```

Stop it with:

```bash
codex remote-control stop
```

The environment makes the command available but does not automatically start
or supervise the experimental daemon. Run `start` again after a container
restart or recreation. SSH remains the stable, supported access path if
remote control is unavailable for the installed Codex release or account.

## MCP and Home Assistant

Codex MCP registrations are stored under the persistent `$CODEX_HOME`, so a
registration made at runtime survives container recreation and CLEAN
rebuilds.

Home Assistant's current Model Context Protocol Server integration exposes a
Streamable HTTP endpoint at `/api/mcp`. Codex can register Streamable HTTP MCP
servers with `codex mcp add --url` and can read a bearer token from a named
environment variable. Conceptually, the registration is:

```bash
codex mcp add home-assistant \
  --url http://home-assistant.local:8123/api/mcp \
  --bearer-token-env-var HOME_ASSISTANT_TOKEN
```

Before using it:

1. Enable Home Assistant's **Model Context Protocol Server** integration.
2. Expose only the entities that Codex should access through Home Assistant's
   Assist exposure settings.
3. Create the appropriate OAuth credential or long-lived access token.
4. Confirm the container can resolve and reach the Home Assistant address.
5. Make `HOME_ASSISTANT_TOKEN` available to every Codex process without
   committing it to the repository.

This environment does **not** yet provide a Compose variable, secret store, or
deployment action for `HOME_ASSISTANT_TOKEN`; therefore the command above is
an integration reference, not a fully automated environment workflow. Adding
the registration without arranging persistent, secure token delivery leaves
it configured but unable to authenticate after a new login or container
restart.

Do not copy the Claude README's older SSE URL or `claude mcp` command. Those
are not the current Home Assistant Streamable HTTP endpoint or Codex CLI
syntax. Consult the
[Home Assistant MCP Server documentation](https://www.home-assistant.io/integrations/mcp_server/)
and run `codex mcp add --help` on the deployed CLI before registering it.

## Sandbox and approval policy

Codex has its own sandbox and command-approval controls. They are separate
from Docker isolation: Docker limits which host paths are mounted, while the
Codex sandbox controls what an agent may do inside the container and when it
must request approval.

This environment deliberately does not force a global sandbox or approval
policy. Codex defaults and any settings in persistent
`~/.codex/config.toml` or repository `.codex/config.toml` apply. Review those
settings before unattended or remote use. Avoid globally enabling unrestricted
execution merely because Codex already runs in a container; it still has
write access to the mounted workspace, persistent credentials, network
access, and any forwarded SSH agent.

## Deployment policies

Use `./deploy.sh` from the repository root for the safest normal workflow.
The Codex environment has no custom `run.sh`; pi-bootstrap's generic Compose
deployment path provides its lifecycle operations.

| Policy | Effect | Persistent state |
|---|---|---|
| `FAST` | Starts or reconciles the container without a no-cache image rebuild | Preserved |
| `STOP` | Stops the container; FAST resumes it | Preserved |
| `TEARDOWN` | Stops and removes the container | Volumes and workspace preserved |
| `CLEAN` | Builds the replacement image without cache, then recreates the container | Volumes and workspace preserved |
| `INFO` | Displays paths, volumes, sizes, notes, and useful commands | Unchanged |
| `WIPE` | Deletes all three Codex environment named volumes after confirmation | Authentication, settings, sessions, user home, and SSH server identity deleted; workspace preserved |

Raw Compose equivalents from `environments/codex-cli` are:

```bash
docker compose up -d
docker compose stop
docker compose down
docker compose build --no-cache
```

Prefer `deploy.sh` for CLEAN because its generic deployment path builds the
replacement before taking down the running container. INFO and WIPE are
pi-bootstrap operations with no single raw Compose equivalent. A WIPE changes
the SSH server fingerprint and requires Codex authentication again.

## Backup and restore

The environment's `info.yaml` registers all three named volumes with
pi-bootstrap's backup tooling. The host workspace is intentionally outside
those volumes and must be backed up as an ordinary host repository or
directory.

After restoring named volumes to another compatible host, configure that
host's `CODEX_WORKSPACE_PATH`, `SSH_AUTHORIZED_KEYS_PATH`, `PUID`, and `PGID`,
then redeploy the environment. Treat authentication files and provider/MCP
credentials in backups as secrets.

## Desktop integration

Linux desktop installation supplies:

| Entry | Opens |
|---|---|
| **Codex CLI (SSH)** | A terminal connected to the container's persistent tmux session |
| **Codex CLI Info** | The generated pi-bootstrap environment information page |

Install or refresh entries through `deploy.sh` or:

```bash
./install-desktop-entries.sh
```

XDG `.desktop` entries do not apply on macOS and are skipped there. This does
not affect deployment or SSH access.

## Useful commands

```bash
# Connect to the persistent session
ssh -p 2224 codex@localhost

# Connect with SSH-agent forwarding
ssh -A -p 2224 codex@target-host.local

# Open a plain shell from the Docker host
docker exec -u codex -it codex-cli bash

# Authentication
docker exec -u codex codex-cli codex login status
docker exec -u codex -it codex-cli codex login --device-auth

# Attach directly to the base tmux session
docker exec -u codex -it codex-cli tmux attach -t codex

# Logs and lifecycle
docker logs -f codex-cli
docker compose stop
docker compose up -d
docker compose restart

# Conversation and MCP management, from a plain codex-user shell
codex resume
codex mcp list
```

The image installs Codex at build time with OpenAI's
[standalone Linux installer](https://developers.openai.com/codex/cli).
Use a CLEAN rebuild to pick up a newer CLI release.

## Troubleshooting

### `Permission denied (publickey)` on first SSH

The most common cause is that `SSH_AUTHORIZED_KEYS_PATH` did not exist when
Compose first created the bind mount. Docker may create a missing source path
as a directory, but this environment requires a regular file:

```bash
ls -ld ~/.ssh/authorized_keys
```

If it is an empty directory, remove that directory, create the file, add a
trusted public key, and recreate the container:

```bash
rmdir ~/.ssh/authorized_keys
touch ~/.ssh/authorized_keys
ssh-add -L >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
docker compose down
docker compose up -d
```

If `ssh-add -L` reports no identities, copy an existing public key into the
file or generate an Ed25519 key with `ssh-keygen -t ed25519`. A plain
container restart is insufficient when the original mount was created with
the wrong file type; the container must be recreated.

### SSH warns that the host identification changed

WIPE deletes the persisted SSH server identity, and a renamed
`CONTAINER_NAME` uses a different host-key volume. Verify that this was
expected, then remove only the affected host-and-port entry:

```bash
ssh-keygen -R '[target-host.local]:2224'
```

Do not ignore an unexpected host-key change.

### Files in the workspace have the wrong owner

Run `id -u` and `id -g` on the Docker host and put those exact values in this
environment's `.env`, then recreate the container. Do not assume Linux's
common `1000:1000` on macOS; `501:20` is common there.

### Codex starts a new conversation after restart

Check authentication and saved sessions from a plain shell:

```bash
codex login status
codex resume
```

Also confirm that `CODEX_HOME=/home/codex/.codex` is still set and that the
instance's `${CONTAINER_NAME}_codex_home` volume exists. Changing
`CONTAINER_NAME` selects a different volume and therefore a different session
history.

### Runtime settings disappeared after a rebuild

Settings under `/home/codex` and `/home/codex/.codex` should persist. Settings
under `/etc`, software installed manually with `apt`, or edits elsewhere in
the container image do not. Use:

```bash
docker inspect codex-cli
docker volume ls
```

Confirm that all three expected named volumes are mounted and that
`CONTAINER_NAME` has not changed. Put operating-system customizations in the
Dockerfile rather than applying them interactively.

### Remote control reports that the managed standalone install was not found

Rebuild and recreate the container with CLEAN so the image includes the
standalone-path integration, then verify the fixed runtime path:

```bash
test -x ~/.codex/packages/standalone/current/codex
codex remote-control start
```

The runtime path normally resolves into `/opt/codex`. Do not replace
`~/.codex/packages/standalone` with a stale copied release; CLEAN rebuilds
update the image-managed release while preserving the rest of `~/.codex`.

### The container cannot reach a LAN service

Test DNS and routing from a plain container shell. On Docker Desktop or
OrbStack, the container is inside a Linux VM; `localhost` means the container,
not the Mac. Use the service's LAN hostname/IP or, for a service running on
the Docker host, the runtime's supported host gateway name.

## Security

- SSH password authentication and root login are disabled. Only keys copied
  from `SSH_AUTHORIZED_KEYS_PATH` are accepted.
- `SSH_PORT` is network-facing. Bind or firewall it to the networks that
  should reach Codex; do not casually publish it to the internet.
- SSH-agent forwarding exposes the agent socket to processes in that SSH
  session. Forward only to a host and container you trust.
- `GH_TOKEN`, `OPENAI_API_KEY`, `CODEX_ACCESS_TOKEN`, Home Assistant tokens,
  provider keys, and persistent Codex authentication are secrets. Do not
  commit a populated `.env` or include unencrypted volumes in an untrusted
  backup.
- `PUID` and `PGID` determine the ownership of files created in the bind
  mount. Match them to the target host user.
- Codex can read and modify everything under `CODEX_WORKSPACE_PATH` and use
  credentials made available to it. Mount only the repository or directory
  you intend to place in scope.
- The Docker socket is not mounted, and the container is not privileged.
  Codex therefore cannot administer the Docker host through this environment
  unless additional access is added later.
- Home Assistant exposure settings are the resource boundary for its MCP
  server. Expose only required entities and revoke its token when access is no
  longer needed.

## Claude CLI requirement comparison

The environment mirrors the useful parts of the `claude-cli` remote-terminal
workflow, but product-specific details cannot be copied literally.

| Claude environment requirement | Codex status |
|---|---|
| Standalone container without an orchestrator | Implemented |
| Raspberry Pi and macOS target support | Implemented; target-host runtime testing is still required |
| Container-owned, key-only SSH | Implemented |
| Shared persistent tmux workflow and simultaneous clients | Implemented |
| Resume after container restart and select older sessions | Implemented |
| Model override | Implemented |
| Plain shell access | Implemented and documented above |
| Runtime authentication, settings, skills, MCP, and session persistence | Implemented |
| GitHub access through SSH forwarding or `GH_TOKEN` | Implemented |
| Multiple isolated instances | Implemented |
| Deployment policies, backup metadata, INFO, WIPE, and desktop metadata | Implemented |
| Remote access over SSH/LAN/VPN | Implemented; internet exposure remains an operator decision |
| Codex remote-control workflow | Installed and manually startable; the current CLI feature is experimental and is not auto-started or supervised |
| Gateway/provider picker and revert action | Not implemented; Codex provider profiles are the appropriate design |
| Home Assistant MCP deployment workflow | Not implemented; manual integration requirements are documented above |
| Troubleshooting and security guidance | Documented above |
| Explicit sandbox/approval guidance | Documented above; no policy is forced |

Claude-specific items that do not make sense as Codex requirements are:

- Claude's `/remote-control` command, Claude subscription requirements, and
  `claude.ai/code` endpoint. Codex exposes a different experimental command;
  the environment installs what that Codex command requires instead.
- `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, and an
  Anthropic-Messages-API gateway. Codex uses model-provider configuration.
- Claude's separately persisted `~/.claude.json`. Codex state is already
  covered by the complete persistent user home and `$CODEX_HOME`.
- Claude command names such as `/login`, `--continue`, and `/resume`; their
  Codex equivalents are used throughout this README.
- The older Home Assistant SSE path and `claude mcp add` syntax. Codex uses
  its own MCP command and Home Assistant now documents Streamable HTTP at
  `/api/mcp`.

This README describes repository behavior verified by inspection. The image
has not been built or exercised on the target Raspberry Pi or second Mac from
the Mac where these files were prepared. Complete deployment acceptance still
requires a build, authentication, SSH connection, persistence test across a
CLEAN rebuild, and architecture-specific smoke test on each intended target.
