# Use the official Kali Linux base image optimized for ARM architectures
FROM kalilinux/kali-rolling:latest

ENV DEBIAN_FRONTEND=noninteractive

# Split out of kali-pentest into its own environment: legion alone took
# ~1900s (32+ min) in a real build — by far the single largest cost in
# that environment once its Forensics layer was split per-tool to find
# the actual culprit (Legion's Kali package pulls a fairly heavy
# Python/Qt GUI + bundled recon-module dependency tree, unrelated to
# WiFi/network tooling itself). Isolating it here means a kali-pentest
# CLEAN never touches Legion, and a kali-legion CLEAN never touches
# kali-pentest's much larger tool list. Also lets Legion be deployed
# standalone, independent of kali-pentest.
#
# No `apt-get upgrade -y` (same reasoning as kali-pentest's Dockerfile):
# under CLEAN's --no-cache, that would dist-upgrade the entire base image
# on every rebuild, unrelated to anything actually installed here.
# --no-install-recommends: legion otherwise pulls a larger
# recommended-but-not-required dependency tree on top of its already
# sizable hard dependencies.
#
# No `dialog`/`less`: Legion is GUI-only, with no CLI/TUI of its own to
# put behind an in-container menu — this environment has none, unlike
# kali-pentest/kali-metasploit. Shell access is the "Open Bash Shell"
# custom_action; Legion itself is the "Launch Legion (GUI)" custom_action
# / desktop entry, both going straight through `docker exec`.
RUN apt-get update && apt-get install -y --no-install-recommends \
    legion \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /root

# ARCHETYPE REQUIREMENT: Keep background runtime loop alive non-interactively
ENTRYPOINT ["/bin/bash", "-c", "while true; do sleep 30; done"]
