# Bundles the three CLI/GUI network-traffic tools that don't fit any other
# service in this stack: iftop (live per-connection bandwidth), nethogs
# (bandwidth by process), and EtherApe (graphical live traffic map). None of
# these are always-on background daemons like darkstat/NetAlertX — they're
# interactive tools you attach to on demand via `docker exec`, so this
# container just sleeps until something execs into it.
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    iftop \
    nethogs \
    etherape \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
ENTRYPOINT ["/bin/bash", "-c", "while true; do sleep 30; done"]
