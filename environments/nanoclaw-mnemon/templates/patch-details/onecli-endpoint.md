**What it changes.** `src/gateway-providers/onecli.ts` (installed by
`/add-onecli`) hardcodes `endpoint: 'host.docker.internal'`, the address
agent containers use to reach the OneCLI gateway proxy. This patch replaces
it with `_pbOnecliEndpoint()`, defined in a version-marked block
(`pi-bootstrap:onecli-endpoint`) at the end of the file. Resolution order:
`ONECLI_GATEWAY_ENDPOINT` in the process environment, then in NanoClaw's
`.env` (read from the service's working directory), then the original
`host.docker.internal`. With nothing set, behavior is unchanged.

**When to set it.** When agents never reply and their requests to the model
API retry forever, while `host.docker.internal` resolves inside agent
containers to an address that refuses the connection (seen on OrbStack,
where it resolved to `0.250.250.254` while the gateway was on the Docker
bridge IP). Find the bridge IP with
`docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}'`
(or take it from `curl` tests inside an agent container), put
`ONECLI_GATEWAY_ENDPOINT=<ip>` in NanoClaw's `.env`, and redeploy.

**Anchors.** The literal `endpoint: 'host.docker.internal'`. If upstream
changes it the patch is SKIPPED with that reason in the status line and the
deploy continues; nothing is spliced blind. It rebuilds and restarts NanoClaw
when it freshly applies or upgrades its block.

**What a correct fix has to look like.** Bump `VERSION` in
`scripts/patch-onecli-endpoint.cjs` on any text change to the block, or
existing installs keep the stale text. The sibling
`patch-host-gateway.cjs` fixes only the `--add-host` argument given to agent
containers; this value is passed to OneCLI directly and never goes through
it, which is why both exist. `ollama-mcp-stdio.ts` already honours
`OLLAMA_HOST`, so it needs no equivalent.

**Not yet verified.** Written without access to the upstream file or a
Docker daemon; confirm the anchor matches on a real install.
