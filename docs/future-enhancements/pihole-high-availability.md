# Pi-hole High Availability (2-Pi failover)

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
      clients ────► │   VIP (float)    │ ◄──── moves between Pis via VRRP
     (DHCP/DNS)      │  e.g. 192.168.1.10│
                    └────────┬─────────┘
                             │
              ┌──────────────┴──────────────┐
              │                             │
      ┌───────▼────────┐          ┌─────────▼───────┐
      │   Pi #1 (RW)    │          │   Pi #2 (RO)     │
      │ pihole-wireguard│          │ pihole-wireguard │
      │   role=primary  │◄──sync──►│  role=secondary  │
      └─────────────────┘          └──────────────────┘
```

Clients point DNS at the **VIP**, never at either Pi's real address.
Whichever Pi is alive owns the VIP. Both Pis sit on the same L2 subnet —
this design assumes that and doesn't work unmodified across VLANs, since
VRRP's heartbeat is multicast and won't cross a router boundary.

**Pi-hole is the DHCP server** (not the router) — this changes more than
just DNS failover; see [DHCP failover](#dhcp-failover) below, since DHCP
itself now also has to be single-active-writer across the two Pis, not
just DNS.

## Split-brain resolution

With only two nodes, VRRP has a known failure mode: if the link *between
the two Pis* drops while each can still independently reach the LAN, both
stop hearing the other's advertisements and both promote themselves to
MASTER, claiming the VIP simultaneously.

This is resolved deterministically, without needing a third
witness/arbiter node, by **`HA_ROLE` driving a static VRRP `priority`** —
`primary` always gets a higher priority (e.g. `150`) than `secondary`
(e.g. `100`) in the rendered `keepalived.conf`. VRRP's own protocol
handles the rest: any node that hears an advertisement from a
*higher*-priority peer immediately yields to BACKUP, even if it currently
believes itself to be MASTER. So the split-brain window is bounded exactly
to the duration of the network partition itself — the instant the two Pis
can hear each other again, the lower-priority one (`secondary`) steps
down automatically. `HA_ROLE` is the single source of truth for who wins;
nothing else needs to "decide" a tie.

The remaining real risk during that window isn't which one *should* win —
it's that both are answering DNS/DHCP on the LAN at once. For a home LAN
where both Pis share one switch, this is a narrow, short-lived condition
(the switch itself failing takes down connectivity for everyone
regardless of which Pi has the VIP), so it's treated as an accepted
residual risk rather than solved with additional hardware.

## Components

1. **keepalived** (VRRP) — runs on the host OS of both Pis (not
   containerized; it needs raw multicast sockets, same reasoning as why the
   existing netplan network config in `run.sh` is done at the host level
   rather than dockerized). Advertises the VIP; the standby takes over
   automatically if the primary stops responding.
2. **A sync tool**, to keep the standby's blocklists/config from going
   stale before it ever has to take over. Two candidates:
   - **[gravity-sync](https://github.com/vmstan/gravity-sync)** — mature,
     purpose-built for exactly this. Rsyncs `gravity.db` + custom lists
     over SSH on a cron schedule. Needs SSH key exchange between the two
     Pis (manual, one-time setup — can't be automated without the user's
     own credentials).
   - **[orbital-sync](https://github.com/mattwebbio/orbital-sync)** — newer,
     uses Pi-hole v6's Teleporter API instead of SSH/rsync. No SSH keys to
     manage, runs as its own small container, but less granular than
     gravity-sync's file-level sync.

   Recommendation: start with gravity-sync — it's the more established,
   more widely-documented option, and this repo already assumes SSH access
   to the Pi for everything else.

Pi-hole's **DNS** side needs no changes for this — it's already
`network_mode: host`, so it transparently answers on the VIP the moment
keepalived assigns it to that host, and there's no harm in both instances
having DNS enabled simultaneously (a stray query answered by the standby
during a split-brain window is harmless).

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

The lease database itself also needs to be part of the sync from primary
→ secondary (alongside `gravity.db`), so a freshly-promoted secondary
doesn't hand out an address that's already leased. **Needs verification on
real hardware:** exactly where Pi-hole v6's FTL-based DHCP server persists
its lease state (this moved around across Pi-hole versions — v5's
dnsmasq-based DHCP used a plain `/etc/pihole/dhcp.leases` file; v6's
built-in FTL DHCP server may store it differently, possibly inside
`pihole-FTL.db`) — whichever file(s) it turns out to be, add them to the
sync scope.

## WireGuard failover (without breaking existing configs/QR codes)

The naive version of this breaks things: if the secondary ever
independently starts `wg-easy` for the first time (rather than inheriting
primary's exact state), it generates its **own distinct server keypair**.
Every client's saved config and QR code has the server's *public key*
baked into it — the moment the secondary ever answers WireGuard traffic
with a different public key than what the client expects, the handshake
just fails silently. Syncing peer *entries* alone doesn't fix this if the
server identity itself has diverged.

The fix has three parts:

1. **Bootstrap the secondary from a copy, never let it self-initialize.**
   At HA setup time, `etc-wireguard/` is copied wholesale from primary to
   secondary *before* secondary's `wg-easy` ever starts for the first
   time, so both nodes start with the exact same server keypair. This is
   a one-time step, not an ongoing sync concern.
2. **Continuously mirror `etc-wireguard/` afterward** (not just at
   bootstrap) — same mechanism as the DHCP lease sync above, just pointed
   at this directory. Since wg-easy stores each peer's private key in
   `wg0.json` too (unlike a raw `wg genkey` workflow where you must save
   it yourself immediately), a fully and correctly synced `wg0.json` means
   whichever node is active can regenerate the *identical* QR code for any
   existing peer — nothing about the QR code is tied to which physical Pi
   is answering, only to the (now-shared) server keypair and that peer's
   own stored keys.
3. **Single active writer, enforced by keepalived notify scripts** — same
   hooks as DHCP: `docker compose stop wg-easy` on transition to BACKUP,
   `docker compose up -d wg-easy` (picking up whatever was just synced) on
   transition to MASTER. This avoids two independent copies of `wg-easy`
   both being reachable for peer management at once — since the WireGuard
   *traffic* itself is addressed to the VIP, only the active node ever
   receives real handshakes anyway, but stopping the standby's container
   also means anyone managing peers only ever talks to the one authoritative
   instance (reachable at the VIP's web UI), removing any two-writer
   ambiguity about which copy of `wg0.json` is "real."

With all three in place, `WG_HOST` pointed at the VIP, peer configs and
QR codes stay valid across a failover — the only loss window is whatever
changed in the interval since the last sync (e.g. a peer added seconds
before the primary died).

## Sketch of what would change in this repo

Following the existing `NETWORK_STATIC_IPS` pattern in
`environments/pihole-wireguard/run.sh` (env-var driven, confirm-before-apply):

```bash
# .env.example additions
HA_ENABLE=false
HA_ROLE=                    # primary | secondary — also the split-brain tie-breaker (see above)
HA_VIP=                     # e.g. 192.168.1.10 — floating IP clients point DNS/DHCP at
HA_PEER_IP=                 # the other Pi's real IP, for VRRP + sync
HA_VRRP_PASSWORD=           # shared VRRP auth secret
HA_INTERFACE=eth0
```

`run.sh` would grow a new gated section, mirroring the netplan section's
shape:

- If `HA_ENABLE=true`, render `/etc/keepalived/keepalived.conf` from a
  template — `state MASTER` / `priority 150` on `HA_ROLE=primary`,
  `state BACKUP` / `priority 100` on `secondary` — using `HA_VIP`,
  `HA_INTERFACE`, and `HA_VRRP_PASSWORD`.
- Install a keepalived **notify script** referenced by that config, which
  on transition to MASTER: enables Pi-hole's DHCP (`dhcp.active true`) and
  starts `wg-easy`; on transition to BACKUP: disables DHCP and stops
  `wg-easy`. This is the single-active-writer enforcement both the
  [DHCP](#dhcp-failover) and [WireGuard](#wireguard-failover-without-breaking-existing-configsqr-codes)
  sections above depend on.
- `apt-get install -y keepalived gravity-sync`, then
  `systemctl enable --now keepalived`.
- On the secondary only: seed `etc-wireguard/` from the primary as a
  one-time copy (before secondary's `wg-easy` is ever started), then set
  up continuous sync covering `gravity.db`, the DHCP lease file(s), and
  `etc-wireguard/` — gravity-sync natively handles the first; the rest
  need either gravity-sync's custom-file support or a second, simple
  rsync cron alongside it.
- Same two safety layers already used for the netplan changes should apply
  here too: show the user the exact config before writing it, default to
  **no**, and don't touch anything if `HA_ENABLE` is unset.

## Open questions for whoever picks this up

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
