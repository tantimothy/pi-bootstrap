# Browser for agents (`environments/browser` + nanoclaw-mnemon `browser` patch)

Shipped without a Docker daemon available to the author, so only `bash -n`, YAML
parsing and a sandbox run of `apply_browser_patch()` against mock files were
done. Each item below is an assumption, not a confirmed fact; confirm on the
first real deploy and delete the entry (and the "not yet exercised" lines in the
READMEs) once verified.

1. **`docker compose build && up` of `environments/browser`** — Debian's
   `chromium` under Xvfb with `--no-sandbox`, on amd64 and arm64; `x11vnc`
   password auth from a macOS VNC client; the `socat` CDP relay.
2. **Agent containers reaching the browser** by LAN IP through OneCLI's proxy.
   The `NO_PROXY` in the `index.ts` block is a reasoned fix, not a tested one;
   it is also unknown whether the MCP `env:` is merged with, or replaces, the
   inherited environment.
3. **`npm` in the agent base image** — confirmed present: upstream's
   `container/Dockerfile` (2026.10.1-rc.2) is `FROM node:22...-slim`, and the browser
   patch applies cleanly against it (anchor and `index.ts` splice checked on a real
   clone). Whether `playwright-mcp` then starts and connects is still untested.
4. **Whether `container/agent-runner/src/index.ts` is baked into the image or
   mounted at spawn** — the patch rebuilds either way.
5. **`CDP_ALLOW_RANGE`** may be defeated on Docker Desktop / OrbStack, where the
   source address a container sees can be a NAT address.

Possible hardening, if this proves useful: join the browser to the network the
agent containers use so CDP never needs publishing beyond loopback (needs a
`container-runner.ts` splice for `--network`); authenticate CDP behind a small
reverse proxy instead of relying on network scope.
