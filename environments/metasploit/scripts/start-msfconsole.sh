#!/bin/bash
# Starts Metasploit's PostgreSQL-backed database (if enabled) and execs
# msfconsole. Run inside the container via `docker exec -it`, from the
# "Metasploit Framework (Console)" custom_action — Metasploit has no
# other in-container menu to sit behind, so this script IS the launcher.
if [ "${START_METASPLOIT_DB:-true}" = "true" ]; then
    service postgresql start >/dev/null 2>&1
    [ ! -d "/root/.msf4/db" ] && msfdb init >/dev/null 2>&1
fi
exec msfconsole
