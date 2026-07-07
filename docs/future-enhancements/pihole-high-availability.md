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

Clients and the router point DNS at the **VIP**, never at either Pi's real
address. Whichever Pi is alive owns the VIP.

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

Pi-hole itself needs **no changes** — it's already `network_mode: host` in
`docker-compose.yml`, so it transparently answers on the VIP the moment
keepalived assigns it to that host.

## Sketch of what would change in this repo

Following the existing `NETWORK_STATIC_IPS` pattern in
`environments/pihole-wireguard/run.sh` (env-var driven, confirm-before-apply):

```bash
# .env.example additions
HA_ENABLE=false
HA_ROLE=                    # primary | secondary
HA_VIP=                     # e.g. 192.168.1.10 — floating IP clients/router point DNS at
HA_PEER_IP=                 # the other Pi's real IP, for VRRP + gravity-sync
HA_VRRP_PASSWORD=           # shared VRRP auth secret
HA_INTERFACE=eth0
```

`run.sh` would grow a new gated section, mirroring the netplan section's
shape:

- If `HA_ENABLE=true`, render `/etc/keepalived/keepalived.conf` from a
  template — `state MASTER` / higher `priority` on `HA_ROLE=primary`,
  `state BACKUP` / lower `priority` on `secondary` — using `HA_VIP`,
  `HA_INTERFACE`, and `HA_VRRP_PASSWORD`.
- `apt-get install -y keepalived gravity-sync`, then
  `systemctl enable --now keepalived`.
- On the secondary only, set up gravity-sync's cron (its own installer
  handles this once SSH access to the primary is configured).
- Same two safety layers already used for the netplan changes should apply
  here too: show the user the exact config before writing it, default to
  **no**, and don't touch anything if `HA_ENABLE` is unset.

## The catch: WireGuard doesn't get this for free

`wg-easy`'s state (server keys, every peer's config) lives in
`etc-wireguard/wg0.json` on whichever Pi runs it — not synced by anything
above. Pointing `WG_HOST` at the VIP would make the *tunnel endpoint*
fail over at the network level, but each Pi's wg-easy would have an
independent, unsynced peer database. A failover would silently drop every
existing peer's connection until it's manually reconfigured on whichever
Pi is now active.

Options, in increasing order of effort:

1. **Document it as a known limitation.** Pi-hole/DNS gets HA; WireGuard
   stays a single point of failure. Simplest, and arguably fine — losing
   remote VPN access temporarily is a much smaller problem than losing DNS
   for every device on the LAN.
2. **Extend the sync to `etc-wireguard/` too** — a second, simple rsync
   cron job (same shape as gravity-sync, just pointed at a different
   directory) keeping the secondary's `wg0.json` current. This gives
   WireGuard the same kind of failover DNS gets, at the cost of one more
   moving part to keep working.

Recommendation: ship option 1 first (Pi-hole HA only, clearly documented),
and treat option 2 as a further, separate enhancement once the base
failover has actually been proven on real hardware.

## Open questions for whoever picks this up

- Does the target network's router/DHCP actually let DNS be reconfigured
  to point at a VIP, or is Pi-hole itself expected to also serve DHCP
  (`network_mode: host` already supports this) — if so, DHCP failover
  needs its own VRRP-aware config (keepalived can run notify scripts to
  start/stop a DHCP-serving mode on transition).
- VRRP multicast needs to actually reach both Pis — if they're on
  different VLANs/subnets this design doesn't work unmodified.
- Split-brain handling: what happens if both Pis think they're primary
  (network partition)? keepalived's defaults are usually fine for a small
  home LAN, but worth a deliberate check before relying on this.
