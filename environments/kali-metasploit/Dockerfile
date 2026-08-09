# Use the official Kali Linux base image optimized for ARM architectures
FROM kalilinux/kali-rolling:latest

ENV DEBIAN_FRONTEND=noninteractive

# Seed environment variable default fallbacks within the core image layer
ENV START_METASPLOIT_DB=true

# Split out of kali-pentest into its own environment: metasploit-framework
# alone is ~1.5-2.5GB, by far the single largest package in that environment,
# and forced every CLEAN there to reinstall it regardless of what actually
# changed. Isolating it here means a kali-pentest CLEAN never touches this,
# and a kali-metasploit CLEAN never touches kali-pentest's much larger tool
# list. Armitage came with it — it's Metasploit's own GUI front-end (needs
# a local msfrpcd to connect to), so it can't usefully live anywhere else.
#
# No `apt-get upgrade -y` (same reasoning as kali-pentest's Dockerfile):
# under CLEAN's --no-cache, that would dist-upgrade the entire base image on
# every rebuild, unrelated to anything actually installed here.
# --no-install-recommends: metasploit-framework and armitage both otherwise
# pull large recommended-but-not-required dependency trees.
RUN apt-get update && apt-get install -y --no-install-recommends \
    dialog \
    less \
    metasploit-framework \
    postgresql \
    armitage \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /root

# Establish static paths for persistence hooks
RUN mkdir -p /root/.msf4

# Copy structural entrypoint scripts for manual subshell calls
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# ARCHETYPE REQUIREMENT: Keep background runtime loop alive non-interactively
ENTRYPOINT ["/bin/bash", "-c", "while true; do sleep 30; done"]
