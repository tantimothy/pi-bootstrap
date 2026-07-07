# Pi-hole High Availability (multi-node failover)

**Status:** design proposal — not implemented. Needs a second physical Pi to
build and test against, so this is written up for later rather than coded now.

## Problem

`pihole-wireguard` runs Pi-hole as the LAN's DNS (and optionally DHCP)
server on a single Raspberry Pi. If that Pi goes down (SD card failure,
power loss, a bad `CLEAN` redeploy), every client on the network loses DNS
until it's back up. There's no failover today.

## Topology

```
                    ┌─────────────────┐
      clients ────► │   VIP (float)    │ ◄──── owned by whichever node is
     (DHCP/DNS)      │  e.g. 192.168.1.10│      currently MASTER (see below)
                    └────────┬─────────┘
                             │
        ┌────────────────────┼────────────────────┐
        │                    │                     │
 ┌──────▼───────┐    ┌───────▼────────┐    ┌────────▼───────┐
 │     Pi A      │    │     Pi B       │    │     Pi C       │  ← any number
 │pihole-wireguard│◄─►│pihole-wireguard│◄─►│pihole-wireguard│    of nodes
 │HA_PRIORITY=200│sync│HA_PRIORITY=150│sync│HA_PRIORITY=100│
 └───────────────┘    └────────────────┘    └────────────────┘
```

Clients point DNS at the **VIP**, never at any node's real address.
`HA_PRIORITY` decides who wins the VIP *at initial election* (cold start,
or after whoever was serving genuinely fails) — but not automatically ever
after; see [Preemption](#preemption-a-returning-node-must-not-silently-become-the-source-of-truth)
below for why a node coming back online doesn't just reclaim the VIP the
instant it's reachable again. This isn't fixed at exactly two nodes — VRRP
natively supports any number of routers in one group, so adding capacity
is just deploying another Pi with its own unique `HA_PRIORITY`, and
retiring one is just decommissioning it; no relabeling of "the primary" or
"the secondary" required, since nothing is hardcoded to a 2-node pair.

All nodes sit on the same L2 subnet — this design assumes that and doesn't
work unmodified across VLANs, since VRRP's heartbeat is multicast and
won't cross a router boundary.

**Pi-hole is the DHCP server** (not the router) — this changes more than
just DNS failover; see [DHCP failover](#dhcp-failover) below, since DHCP
itself now also has to be single-active-writer across every node, not
just DNS.

## Split-brain resolution

VRRP has a known failure mode with more than one node: if a node loses
contact with whichever node currently holds the VIP (a link drop) while
it can still independently reach the LAN, it stops hearing that node's
advertisements and promotes itself to MASTER — potentially leaving two (or
more) nodes simultaneously claiming the VIP.

This is resolved deterministically, without needing a separate
witness/arbiter node, by **each node's `HA_PRIORITY` being a distinct,
static number** (e.g. `200`, `150`, `100` — an arbitrary VRRP `priority`
value, 1–254, unique per node) written straight into that node's
`keepalived.conf`. VRRP's own protocol handles the rest: any node that
hears an advertisement from a *higher*-priority peer immediately yields to
BACKUP, even if it currently believes itself to be MASTER. So the
split-brain window is bounded exactly to the duration of the network
partition itself — the instant every node can hear each other again, all
but the single highest-priority one step down automatically.
`HA_PRIORITY` is the single source of truth for resolving *this* kind of
tie — a genuine simultaneous election, where multiple nodes are booting up
or reconnecting at once with no clear incumbent. Nothing else needs to
"decide" that case, and it scales to any node count without new logic.
This is a narrower claim than "the highest number always wins" — see the
next section for the case where it must deliberately *not* win.

The remaining real risk during a partition isn't which node *should*
win — it's that more than one is answering DNS/DHCP on the LAN at once.
For a home LAN where all nodes share one switch, this is a narrow,
short-lived condition (the switch itself failing takes down connectivity
for everyone regardless of which node has the VIP), so it's treated as an
accepted residual risk rather than solved with additional hardware.

## Preemption: a returning node must not silently become the source of truth

VRRP's *default* behavior is **preemption**: if a node with higher
`HA_PRIORITY` than the current MASTER comes online (or reconnects after a
partition), it immediately reclaims MASTER — purely because its number is
higher, with no regard for whether its data is actually current.

That default is actively dangerous for this design. Say Pi A
(`HA_PRIORITY=200`) was MASTER, crashed, and Pi B (`HA_PRIORITY=150`) has
been covering for hours — new WireGuard peers added, new DHCP leases
handed out, blocklist updates. Sync (as described throughout this doc)
always flows from *whoever is currently active* outward. The instant Pi A
comes back online and preempts, sync direction follows it: Pi A becomes
the source, and everything Pi B accumulated while covering gets
silently overwritten by Pi A's stale, pre-crash state. Nothing errors —
it just quietly loses hours of real changes.

**Fix: set `nopreempt` in every node's `vrrp_instance` block in
`keepalived.conf`.** With
preemption disabled, `HA_PRIORITY` still resolves a genuine simultaneous
election (see above), but a node that returns after being down does
*not* forcibly retake MASTER just because its number is higher — it
rejoins as BACKUP and stays there, quietly catching up via the normal
sync path, until whoever is *currently* MASTER actually fails. Only then
does priority ordering matter again, among whichever nodes are left. This
means `HA_PRIORITY` is better read as "who wins when there's genuinely no
incumbent," not "who's supposed to be in charge at all times."

## Components

1. **keepalived** (VRRP) — runs on the host OS of every node (not
   containerized; it needs raw multicast sockets, same reasoning as why the
   existing netplan network config in `run.sh` is done at the host level
   rather than dockerized). Advertises the VIP; whichever standby has the
   next-highest `HA_PRIORITY` takes over automatically if the current
   holder stops responding.
2. **A sync tool**, to keep every standby's blocklists/config from going
   stale before it ever has to take over. Two candidates:
   - **[gravity-sync](https://github.com/vmstan/gravity-sync)** — mature,
     purpose-built for exactly this. Rsyncs `gravity.db` + custom lists
     over SSH on a cron schedule. Needs SSH key exchange between nodes
     (manual, one-time setup — can't be automated without the user's own
     credentials).
   - **[orbital-sync](https://github.com/mattwebbio/orbital-sync)** — newer,
     uses Pi-hole v6's Teleporter API instead of SSH/rsync. No SSH keys to
     manage, runs as its own small container, but less granular than
     gravity-sync's file-level sync.

   Recommendation: start with gravity-sync — it's the more established,
   more widely-documented option, and this repo already assumes SSH access
   to the Pi for everything else. Since sync should always pull from
   *whoever is currently active* rather than a fixed node, pointing it at
   the **VIP** itself (rather than a specific peer's real IP) means it
   keeps working correctly through a failover without reconfiguring
   anything — see the [sync-source open question](#open-questions-for-whoever-picks-this-up)
   below for the one thing this needs to guard against.

Pi-hole's **DNS** side needs no changes for this — it's already
`network_mode: host`, so it transparently answers on the VIP the moment
keepalived assigns it to that host, and there's no harm in more than one
instance having DNS enabled simultaneously (a stray query answered by a
standby during a split-brain window is harmless).

## DHCP failover

DHCP is a different story from DNS: **two independently-run DHCP servers
answering the same subnet's `DHCPDISCOVER` broadcasts will actively fight**
— clients can get offers from both, and each Pi-hole tracks its own lease
database, so nothing reconciles who's leased what. This needs the same
"exactly one active writer" discipline WireGuard needs (see below), not
the "both can run harmlessly" model DNS gets away with.

Handled via keepalived **notify scripts** — hooks it runs on every state
transition:

- **On transition to MASTER:** `docker exec pihole pihole-FTL --config dhcp.active true` (the same `FTLCONF_*`-style config mechanism already used elsewhere in this stack, e.g. `FTLCONF_webserver_api_password` in `docker-compose.yml`).
- **On transition to BACKUP:** `docker exec pihole pihole-FTL --config dhcp.active false`.

The lease database itself also needs to be part of the sync (alongside
`gravity.db`), so a freshly-promoted node doesn't hand out an address
that's already leased. **Needs verification on
real hardware:** exactly where Pi-hole v6's FTL-based DHCP server persists
its lease state (this moved around across Pi-hole versions — v5's
dnsmasq-based DHCP used a plain `/etc/pihole/dhcp.leases` file; v6's
built-in FTL DHCP server may store it differently, possibly inside
`pihole-FTL.db`) — whichever file(s) it turns out to be, add them to the
sync scope.

## WireGuard failover (without breaking existing configs/QR codes)

The naive version of this breaks things: if a new node ever independently
starts `wg-easy` for the first time (rather than inheriting the currently
active node's exact state), it generates its **own distinct server
keypair**. Every client's saved config and QR code has the server's
*public key* baked into it — the moment a different node ever answers
WireGuard traffic with a different public key than what the client
expects, the handshake just fails silently. Syncing peer *entries* alone
doesn't fix this if the server identity itself has diverged.

The fix has three parts:

1. **Bootstrap every new node from a copy, never let it self-initialize.**
   Before a new node's `wg-easy` ever starts for the first time,
   `etc-wireguard/` is copied wholesale from any currently-running node, so
   every node ends up with the exact same server keypair. This is a
   one-time step per node joining the group, not an ongoing sync concern.
2. **Continuously mirror `etc-wireguard/` afterward** (not just at
   bootstrap) — same mechanism as the DHCP lease sync above, just pointed
   at this directory, fanning out from whichever node is currently active
   to every other node. Since wg-easy stores each peer's private key in
   `wg0.json` too (unlike a raw `wg genkey` workflow where you must save
   it yourself immediately), a fully and correctly synced `wg0.json` means
   whichever node is active can regenerate the *identical* QR code for any
   existing peer — nothing about the QR code is tied to which physical Pi
   is answering, only to the (now-shared) server keypair and that peer's
   own stored keys.
3. **Single active writer, enforced by keepalived notify scripts** — same
   hooks as DHCP: `docker compose stop wg-easy` on transition to BACKUP,
   `docker compose up -d wg-easy` (picking up whatever was just synced) on
   transition to MASTER. This avoids more than one copy of `wg-easy` being
   reachable for peer management at once — since the WireGuard *traffic*
   itself is addressed to the VIP, only the active node ever receives real
   handshakes anyway, but stopping every standby's container also means
   anyone managing peers only ever talks to the one authoritative instance
   (reachable at the VIP's web UI), removing any ambiguity about which
   copy of `wg0.json` is "real" — however many nodes exist.

With all three in place, `WG_HOST` pointed at the VIP, peer configs and
QR codes stay valid across a failover — the only loss window is whatever
changed in the interval since the last sync (e.g. a peer added seconds
before the previously-active node died).

## Sketch of what would change in this repo

Following the existing `NETWORK_STATIC_IPS` pattern in
`environments/pihole-wireguard/run.sh` (env-var driven, confirm-before-apply):

```bash
# .env.example additions
HA_ENABLE=false
HA_PRIORITY=                # numeric VRRP priority, 1-254 — unique per node, highest wins the VIP.
                             # Adding a node = pick an unused number; retiring one = just stop it.
HA_VIP=                     # e.g. 192.168.1.10 — floating IP clients point DNS/DHCP at
HA_VRRP_PASSWORD=           # shared VRRP auth secret, same value on every node
HA_INTERFACE=eth0
```

No peer-IP field is needed: VRRP discovers other nodes itself via
multicast on the same subnet (no explicit peer list required in
`keepalived.conf`), and sync targets `HA_VIP` — always whoever's currently
active — rather than a specific node's address.

`run.sh` would grow a new gated section, mirroring the netplan section's
shape:

- If `HA_ENABLE=true`, render `/etc/keepalived/keepalived.conf` from a
  template using `HA_PRIORITY` directly as the VRRP `priority` value
  (`state MASTER` if it turns out to be the highest currently seen, `state
  BACKUP` otherwise — keepalived figures this out itself at runtime, it
  doesn't need to be decided by `run.sh`), plus `HA_VIP`, `HA_INTERFACE`,
  `HA_VRRP_PASSWORD`, and **`nopreempt`** (see
  [Preemption](#preemption-a-returning-node-must-not-silently-become-the-source-of-truth)
  above — without this, a returning node can silently become the sync
  source and overwrite real changes with its own stale state).
- Install a keepalived **notify script** referenced by that config, which
  on transition to MASTER: enables Pi-hole's DHCP (`dhcp.active true`) and
  starts `wg-easy`; on transition to BACKUP: disables DHCP and stops
  `wg-easy`. This is the single-active-writer enforcement both the
  [DHCP](#dhcp-failover) and [WireGuard](#wireguard-failover-without-breaking-existing-configsqr-codes)
  sections above depend on, and it's identical regardless of how many
  nodes are in the group.
- `apt-get install -y keepalived gravity-sync`, then
  `systemctl enable --now keepalived`.
- On every node except whichever is currently active: seed
  `etc-wireguard/` from `HA_VIP` as a one-time copy (before that node's
  `wg-easy` is ever started), then set up continuous sync — pulling from
  `HA_VIP`, not a fixed peer — covering `gravity.db`, the DHCP lease
  file(s), and `etc-wireguard/`. gravity-sync natively handles the first;
  the rest need either gravity-sync's custom-file support or a second,
  simple rsync cron alongside it. The sync job needs to detect "am I
  currently the active node" (e.g. checking whether `HA_VIP` is assigned
  to one of its own interfaces) and skip pulling from itself.
- Same two safety layers already used for the netplan changes should apply
  here too: show the user the exact config before writing it, default to
  **no**, and don't touch anything if `HA_ENABLE` is unset.

## Open questions for whoever picks this up

- **`nopreempt` + static `state MASTER`/`BACKUP` interaction.** keepalived
  documentation generally recommends pairing `nopreempt` with every node
  configured `state BACKUP` (letting priority alone determine the initial
  MASTER at first boot, rather than hardcoding `state MASTER` anywhere) —
  worth confirming the exact interaction before assuming the straightforward
  reading above is correct, since getting this wrong could reintroduce the
  same stale-reclaim problem `nopreempt` is meant to solve.
- **Syncing via the VIP's SSH host key.** Since `HA_VIP` moves between
  physical nodes, an SSH-based sync tool (gravity-sync) connecting to it
  will see a different SSH host key depending on which node currently
  answers — `known_hosts` would flag this as a possible MITM on every
  failover unless every node is deliberately configured to share the same
  SSH host key (or sync connects to each node's real IP for the initial
  handshake instead of the VIP, only using the VIP for the "am I active"
  self-check). Needs a deliberate choice here, not left implicit.
- **Where Pi-hole v6's FTL DHCP server persists its lease state** (see
  [DHCP failover](#dhcp-failover)) — needs confirming against real FTL
  source/behavior, not assumed.
- **gravity-sync's support for syncing arbitrary extra files/directories**
  (the DHCP lease file, `etc-wireguard/`) beyond its built-in `gravity.db`
  scope — if it doesn't support that natively, those two need their own
  bolt-on rsync cron jobs rather than folding into gravity-sync's existing
  one.
- **Keepalived notify-script failure handling** — if `docker compose up -d
  wg-easy` (or the DHCP toggle) fails on the notify script during a
  transition to MASTER, does keepalived retry, or does the node sit there
  holding the VIP for DNS/DHCP without WireGuard actually up? Needs an
  explicit decision (e.g., a health check that demotes the node back to
  BACKUP if the notify script fails) rather than assuming it silently
  works.
- None of this has been tried on real hardware yet — the whole design
  above is reasoned from documentation and existing conventions in this
  repo, not verified against actual keepalived/gravity-sync/Pi-hole v6
  behavior.
