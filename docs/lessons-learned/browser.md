# Lessons learned: `browser` environment

## Design decisions and the things that bit (2026-10-25/26)

**Status:** shipped in PR #322 and the NanoClaw patch it carries; **not yet run
against Docker** (the authoring session had no daemon). Assumptions still open are
tracked in `docs/future-enhancements/browser-agent.md`.

### What it is

A headed Chromium on Xvfb (VNC for a human to log in) plus a CDP relay (for an agent
to drive the same browser). A containerized browser rather than the operator's
desktop Chrome: isolated, runs on the Pi as well as a Mac, needs no logged-in desktop,
and exposes only the logins deliberately put in it. Cost: it starts empty.

### Things worth remembering

- **CDP needs a non-default profile and a relay.** Recent Chromium silently ignores
  `--remote-debugging-port` on the default `--user-data-dir`, and binds CDP to loopback
  only, so `socat` relays 9222 to 9223. The entrypoint makes Chromium the foreground
  process so a crash restarts the whole container instead of leaving a desktop with no
  browser.
- **Chromium rejects a CDP request whose `Host` header is a hostname** other than
  `localhost` ("not an IP address or localhost"). `http://host.docker.internal:9222`
  therefore fails even with a perfect network path; the endpoint must be an IP. This
  also lines up with the OrbStack finding that `host.docker.internal` can resolve to an
  address that refuses connections while the host's LAN IP works.
- **Reaching it by LAN IP means it cannot be loopback-bound,** so `CDP_BIND` defaults to
  `0.0.0.0` and the security section tells the operator to narrow it (`CDP_BIND`,
  `CDP_ALLOW_RANGE`, a firewall). CDP is unauthenticated full control of every logged-in
  session. Possible hardening: join the browser to the agents' Docker network, or put an
  authenticating proxy in front.
- **VNC default port is 5901,** because macOS Screen Sharing already owns 5900.
- **The browser is outside OneCLI.** Agent traffic goes through the OneCLI gateway, which
  injects credentials per host and blocks hosts it has none for. The browser container
  has its own network path, so what the agent loads through it is not covered by that
  blocking or by per-agent grants, and its logins live in the profile, not the vault.
  The agent's CDP connection is excluded from the proxy with `NO_PROXY` on the Playwright
  MCP subprocess only (not container-wide). Treat the browser as its own trust boundary.
- **The NanoClaw side is an opt-in, version-marked patch** (`apply_browser_patch`),
  keyed on `BROWSER_CDP_URL`. Both blocks interpolate a deploy-time value (package
  version, CDP URL), so "current" also requires that value to be present, otherwise an
  edited `.env` would be silently ignored. Unsetting the variable strips the blocks.
- **Checked against upstream:** `@playwright/mcp@0.0.83` exists with a `playwright-mcp`
  bin and `--cdp-endpoint`; upstream's agent image is `node:22-slim`, so `npm` is
  present; the Dockerfile and `index.ts` anchors matched on a real clone of
  `2026.10.1-rc.2`.

### General Lessons

- **Anything with its own network path is a separate trust boundary from the proxy you
  already have.** Adding a browser widened what the agent can reach without any change
  to the credential gateway; say so in the docs where the operator will read it.
- **A localhost-only service you must reach from a container is a design constraint,**
  not an afterthought: it decides the bind address, the security note, and which
  address form the client may use.

### Related PRs

[#322](https://github.com/tantimothy/pi-bootstrap/pull/322).
