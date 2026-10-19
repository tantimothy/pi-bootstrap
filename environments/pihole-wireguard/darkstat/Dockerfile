FROM debian:bookworm-slim
# apt-get upgrade, not just install: security fixes to packages already baked
# into the base image (e.g. perl-base) otherwise wait on Debian republishing
# the base tag, and check-updates.sh keeps flagging them after every rebuild.
RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends darkstat && rm -rf /var/lib/apt/lists/*
