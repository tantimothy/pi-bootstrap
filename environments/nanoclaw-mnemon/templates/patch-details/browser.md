**What this patch is for.** It gives every agent a browser: a Playwright MCP
server connected, over the Chrome DevTools Protocol (CDP), to the persistent
Chromium that the sibling `environments/browser` environment runs. A human logs
into sites in that Chromium once over VNC; agents then reuse those sessions.
It is **opt-in** — it does nothing unless `BROWSER_CDP_URL` is set in this
environment's `.env`, and it strips its own blocks if that is later unset.

**Files it changes, and where.**

| File | How | Anchor |
|---|---|---|
| `container/Dockerfile` | version-marked block, `# >>> pi-bootstrap:browser v<N> >>>` | `# ---- Bun runtime` |
| `container/agent-runner/src/index.ts` | version-marked block, `// >>> pi-bootstrap:browser v<N> >>>` | `args: ['run', mcpServerPath],` (+2 lines) |

Only `@playwright/mcp` is installed into the agent image (pinned by
`BROWSER_MCP_VERSION`, default `0.0.83`). No browser is downloaded
(`PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1`); the browser lives in its own container.

**"Current" is more than the marker version.** Both blocks interpolate a
deploy-time value (the package version; the CDP URL). The marker's `v<N>` only
tracks the block's *text*, so each block is also re-written when its
interpolated value is missing from it. If you hand-edit a block, keep that
value present or the next deploy will overwrite your edit.

**The shape a correct fix has to have.**

1. **The endpoint must be an IP, never a hostname.** Chromium answers a CDP
   HTTP request whose `Host` header is a hostname other than `localhost` with
   *"Host header is specified and is not an IP address or localhost"*.
   `http://host.docker.internal:9222` therefore fails even when the network path
   is fine. Do not "fix" a failure by switching to a name.
2. **`NO_PROXY` for the browser host is set on the MCP subprocess, not on the
   container.** Agent containers get `HTTPS_PROXY` / `NODE_USE_ENV_PROXY` from
   OneCLI, and Playwright honours proxy env for its CDP connect. The browser is
   a LAN address the proxy has no route for. The `env:` in the `index.ts` block
   is what excludes it; removing it sends CDP traffic to the gateway. (Setting a
   container-wide `NO_PROXY` instead would repeat the `NO_PROXY` interaction the
   Ollama patch documents.)
3. **Whether `index.ts` is baked into the agent image or mounted at spawn is not
   confirmed.** The patch sets `AGENT_IMAGE_NEEDS_REBUILD` on any write, which
   is correct either way (rebuild, then replace running agent containers).
4. **`npm` being present in the agent base image is assumed, not confirmed.**
   The Dockerfile block prints a warning rather than failing the build if it is
   missing. Check with the commands below.

**OneCLI does not cover the browser.** Agent traffic goes through OneCLI,
which injects credentials per host and blocks hosts it has none for. The browser
is a separate container: what the agent loads through it is not subject to that
blocking or to per-agent grants, and its logins live in the browser profile, not
the vault. This patch widens what the agent can reach; it is not a OneCLI
feature. (Credentials for ordinary agent requests are managed with the "Manage
OneCLI Credentials" action.)

**Hostname vs IP.** See rule 1. The deploy warns when `BROWSER_CDP_URL` uses a
hostname.

**Reachability.** The deploy probes, from inside a container with
`--noproxy '*'`, whether `<BROWSER_CDP_URL>/json/version` answers. A host-side
`curl` succeeding proves nothing here. `host.docker.internal` is not dependable
on every platform (on OrbStack it can resolve to an address that refuses
connections); the host's LAN IP is the route that works. If the LAN IP is
assigned by DHCP, pin it, or this URL goes stale silently. The browser
environment's `CDP_BIND` must also allow the container's source address in — a
loopback-only bind refuses it.

**How to check whether it is actually working.**

```
# image has the tool (should print a path; empty means npm was missing at build)
docker run --rm --entrypoint sh <agent-image> -c 'command -v playwright-mcp'

# from a live agent container — CDP answers, with no proxy in the way
curl --noproxy '*' -s http://<ip>:9222/json/version
env | grep -i -E 'proxy'
```

If the image has `playwright-mcp` and `curl` answers, but the agent has no
browser tools, the problem is the `index.ts` registration or a stale agent
container (see "Before you conclude a patch is broken", check 2). If `curl`
fails, it is the browser environment's `CDP_BIND` / `CDP_ALLOW_RANGE`, or the
URL, not this patch.

Related: `environments/browser/README.md`.
