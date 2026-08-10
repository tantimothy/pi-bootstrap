# Use the official Kali Linux base image optimized for ARM architectures
FROM kalilinux/kali-rolling:latest

ENV DEBIAN_FRONTEND=noninteractive

# Seed environment variable default fallbacks within the core image layer
ENV START_METASPLOIT_DB=true

# Split out of kali-pentest into its own environment: metasploit-framework
# alone is ~1.5-2.5GB, by far the single largest package in that environment,
# and forced every CLEAN there to reinstall it regardless of what actually
# changed. Isolating it here means a kali-pentest CLEAN never touches this,
# and a metasploit CLEAN never touches kali-pentest's much larger tool
# list. Armitage came with it — it's Metasploit's own GUI front-end (needs
# a local msfrpcd to connect to), so it can't usefully live anywhere else.
#
# No `apt-get upgrade -y` (same reasoning as kali-pentest's Dockerfile):
# under CLEAN's --no-cache, that would dist-upgrade the entire base image on
# every rebuild, unrelated to anything actually installed here.
# --no-install-recommends: metasploit-framework and armitage both otherwise
# pull large recommended-but-not-required dependency trees.
#
# No `dialog`/`less`: no in-container menu here — msfconsole (this
# environment's only real CLI tool) is launched straight from the "Metasploit
# Framework (Console)" custom_action via scripts/start-msfconsole.sh, and
# Armitage is GUI-only (its own custom_action / desktop entry).
RUN apt-get update && apt-get install -y --no-install-recommends \
    metasploit-framework \
    postgresql \
    armitage \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /root

# Establish static paths for persistence hooks
RUN mkdir -p /root/.msf4

# Starts the Metasploit DB (if enabled) and execs msfconsole — see the
# script's own comment. Copied in under the same /usr/local/bin location
# every other environment's launcher script convention uses.
COPY scripts/start-msfconsole.sh /usr/local/bin/start-msfconsole.sh
RUN chmod +x /usr/local/bin/start-msfconsole.sh

# ARCHETYPE REQUIREMENT: Keep background runtime loop alive non-interactively
ENTRYPOINT ["/bin/bash", "-c", "while true; do sleep 30; done"]
