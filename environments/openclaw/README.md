# OpenClaw

This environment runs the official OpenClaw gateway and Control UI in Docker,
with both Anthropic's Claude CLI and OpenAI's Codex CLI installed in the same
image. All three run as OpenClaw's non-root `node` user and share the OpenClaw
workspace, so either CLI can inspect or maintain the assistant's files without
copying them between containers.

## Deploy

Run `./deploy.sh`, choose **OpenClaw**, and select **FAST**. The first deploy:

1. builds a thin image on top of `ghcr.io/openclaw/openclaw:latest`;
2. installs the official Claude CLI and Codex CLI binaries;
3. generates a gateway token in this environment's `.env`;
4. runs OpenClaw's interactive onboarding; and
5. starts the gateway at `http://<host>:18789`.

Paste `OPENCLAW_GATEWAY_TOKEN` from `.env` into the Control UI when prompted.
The onboarding wizard configures the model provider and any initial channels.
For headless OpenAI/Codex OAuth, follow the wizard's URL and paste its final
redirect URL back into the terminal.

## Claude CLI and Codex CLI

The OpenClaw action menu includes **Open Claude CLI**, **Open Codex CLI**, and
**Codex Device-Code Login**. The first two attach to separate persistent tmux
sessions rooted in OpenClaw's workspace:

```bash
docker exec -u node -it openclaw openclaw-cli-tmux claude
docker exec -u node -it openclaw openclaw-cli-tmux codex
```

Authenticate Claude interactively on first use. For Codex, use the device-code
login action or:

```bash
docker exec -u node -it openclaw codex login --device-auth
```

Claude's `~/.claude` and `~/.claude.json`, Codex's `~/.codex`, OpenClaw state,
auth-profile secrets, and the shared workspace all persist independently.
A CLEAN rebuild updates the gateway and both CLI binaries without deleting any
of those stores.

## Lifecycle

- **FAST** starts or reconciles the existing gateway using the cached image.
  It builds only when the local image does not exist.
- **STOP** stops the gateway while preserving its container and all data.
- **TEARDOWN** removes the Compose containers but preserves named volumes.
- **CLEAN** pulls the current official OpenClaw image, rebuilds both CLIs from
  their official installers, then recreates the gateway only after the build
  and configuration steps succeed.
- **WIPE** removes all declared OpenClaw/Claude/Codex persistent stores after
  confirmation.

## Security and networking

The gateway binds to `lan` inside the container because a loopback-only process
cannot receive traffic through Docker's published port. Gateway token
authentication remains enabled, Linux capabilities `NET_RAW` and `NET_ADMIN`
are dropped, privilege escalation is disabled, and the Control UI origin list
is restricted to localhost plus the host's detected LAN address.

OpenClaw agents are powerful and messaging input is untrusted. Keep channel DM
pairing enabled, review the permissions offered during onboarding, and do not
publish the gateway port directly to the public internet. Use a VPN or SSH
tunnel for remote access.

## Why This Needs a Custom `run.sh`

OpenClaw's official Docker flow requires interactive onboarding and config
writes against the persistent state volume *before* the long-running gateway
starts. The repository's generic Compose dispatcher cannot insert that
interactive pre-start handoff between image build and `compose up`, so this
environment owns the small lifecycle wrapper in `run.sh`. The actual runtime
topology remains ordinary Docker Compose; OpenClaw source is not vendored here.
