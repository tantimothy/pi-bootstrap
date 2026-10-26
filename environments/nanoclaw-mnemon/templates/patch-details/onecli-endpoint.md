**What it changes.** `src/gateway-providers/onecli.ts` (installed by
`/add-onecli`) hardcodes `host.docker.internal` as the address agent containers
use to reach the OneCLI gateway proxy, in two places. Only one matters:

1. **`contributionFromConfig()`** copies `config.env` verbatim from the gateway
   service's container config. Its `HTTPS_PROXY` / `HTTP_PROXY` / `NO_PROXY`
   values point at `host.docker.internal:<port>`, and that is the address agent
   containers actually dial. **This patch rewrites those values** (any env key
   containing `proxy`, case-insensitive, whose value mentions
   `host.docker.internal`).
2. **`networkAccess.endpoint`** is only used for Docker network-policy
   reconciliation. It is patched too, for consistency, but it is *not* what
   fixes connectivity. Patching only this field (what v1 of this patch did)
   builds and deploys cleanly and changes nothing.

Both go through `_pbOnecliEndpoint()`, defined with `_pbRewriteProxyHost()` in a
version-marked block (`pi-bootstrap:onecli-endpoint`) at the end of the file.
Resolution order: `ONECLI_GATEWAY_ENDPOINT` in the process environment, then in
NanoClaw's `.env` (read from the service's working directory), then
`host.docker.internal`. With nothing set, behavior is unchanged.

**When to set it.** When agents never reply and their model requests fail with
"Connection refused" / retry forever, while the gateway answers on the Docker
bridge IP. Seen on OrbStack, where `host.docker.internal` resolves inside agent
containers to `0.250.250.254`. Check from inside an agent container:
`curl --noproxy '*' http://<bridge-ip>:10255/` (any HTTP status means reached)
versus `http://host.docker.internal:10255/` (refused). Put
`ONECLI_GATEWAY_ENDPOINT=<bridge-ip>` in NanoClaw's `.env` (the install
directory's, not this environment's) and redeploy.

**Anchors.** `endpoint: 'host.docker.internal'` and
`const env = { ...config.env };` (exactly once). A missing anchor is reported on
the status line and nothing is spliced blind; if only the proxy anchor is
missing the patch says it was only partially applied. It rebuilds and restarts
NanoClaw when it freshly applies or upgrades its block.

**What a correct fix has to look like.** Bump `VERSION` in
`scripts/patch-onecli-endpoint.cjs` on any change to the block or the call
site, or existing installs keep the stale text. The block and call site are
re-applied after the skill-wiring restore, which overwrites `onecli.ts` from
the skill's payload on every CLEAN. The sibling `patch-host-gateway.cjs`
patched `hostGatewayArgs()` in `container-runtime.ts`; upstream moved that into
`drivers/docker-driver.ts`, so it now finds nothing and skips.

**Verified.** Against a clone of NanoClaw `2026.10.1-rc.2` with the skill
restored: v1 -> v2 upgrade, idempotent rerun, `tsc --noEmit` clean, and a vitest
probe of `contributionFromConfig` (unset: unchanged; set: proxy keys rewritten
including `no_proxy`, unrelated keys untouched). Not verified on a real install.
