# Agent Browser

A persistent Chromium that **you** log into over VNC and that **an agent**
then drives over the Chrome DevTools Protocol (CDP). Built for NanoClaw, but
nothing here is NanoClaw-specific — anything that can speak CDP can use it
(Playwright MCP, Puppeteer, Chrome DevTools MCP).

```
 you ──VNC :5901──► Xvfb + fluxbox + Chromium ◄──CDP :9222── agent container
                          └─ /data/profile (named volume: logins persist)
```

## Why a container rather than your desktop Chrome

It's isolated, runs on the Pi as well as a Mac, doesn't need your desktop
awake, and exposes only the logins you chose to put in it — not your real
profile. The cost is that it starts empty; you log into each site once.

## Use

1. `./deploy.sh` → Environments → Agent Browser.
2. Connect a VNC client to `<host>:5901` (macOS: `open vnc://localhost:5901`).
   Password: `docker exec browser cat /data/vnc-password`.
3. Log into whatever the agent will need. Sessions persist in the volume
   across restarts; they expire like any browser's, so re-login when they do.
4. Confirm CDP answers: `curl http://<lan-ip>:9222/json/version`.
5. Point NanoClaw at it — see below.

## Connecting NanoClaw

In `environments/nanoclaw-mnemon/.env` set

```
BROWSER_CDP_URL=http://<this-host's-LAN-IP>:9222
```

then deploy `nanoclaw-mnemon`. Its `browser` patch installs Playwright MCP in
the agent image and registers it against that URL. See
`../nanoclaw-mnemon/templates/patch-details/browser.md`.

### It must be an IP address, not a hostname

Chromium rejects any CDP HTTP request whose `Host` header is a hostname other
than `localhost`, with *"Host header is specified and is not an IP address or
localhost"*. So `http://host.docker.internal:9222` fails even when the network
path is fine. Use the host's LAN IP — which is also the route that works on
OrbStack, where `host.docker.internal` can resolve to an address that refuses
connections (documented in `nanoclaw-mnemon/.env.example` for Ollama). If the
LAN IP is DHCP-assigned, pin it, or the URL silently goes stale.

## Security

CDP is **unauthenticated full control** of the browser and everything logged
into it. Reaching it from agent containers via the LAN IP means it can't be
bound to loopback, so by default it's published on `0.0.0.0`. Narrow that:

- `CDP_BIND=<this host's LAN IP>` rather than `0.0.0.0`
- `CDP_ALLOW_RANGE=<cidr>` to filter source addresses in the relay
- firewall the port to this host

Only log into accounts you're willing to let the agent act as. VNC is
password-protected but unencrypted; it's bound to loopback by default — use an
SSH tunnel from another machine.

## Not verified yet

Written without access to Docker, so only `bash -n` and a YAML parse have been
run. The first real `docker compose build && up` is the first real test.
Specifically unconfirmed: the `chromium` package starting under Xvfb with
`--no-sandbox` on arm64, and `x11vnc` auth with a macOS client.
