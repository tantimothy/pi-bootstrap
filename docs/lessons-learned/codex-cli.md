# codex-cli — Issues Found & Fixed

## `chown` following a dangling symlink restart-loops the container

**Status:** Fixed.

**Summary:** A recursive ownership fix-up in `entrypoint.sh` used `find …
-exec chown` without `-h`. `chown` follows symlinks by default, Codex leaves
dangling symlinks inside its own state directory, the `chown` failed, `find`
returned non-zero, and `set -euo pipefail` killed the entrypoint before
`sshd` started.

**Symptom:** `ssh: connect to host localhost port 2224: Connection refused`,
immediately after a *successful* CLEAN. `docker ps -a` showed
`Restarting (1) 34 seconds ago` — a crash loop, not a missing container.

`docker logs` was the only place the real cause appeared:

```
chown: cannot dereference '/home/codex/.codex/tmp/arg0/codex-arg0FyjEuc/apply_patch': No such file or directory
chown: cannot dereference '/home/codex/.codex/tmp/arg0/codex-arg0FyjEuc/codex-linux-sandbox': No such file or directory
```

**Root cause:**

```sh
find /home/codex -path /home/codex/workspace -prune \
    -o -exec chown "$PUID:$PGID" {} +
```

Codex writes `~/.codex/tmp/arg0/codex-argXXXXXX/` containing symlinks to
`apply_patch`, `applypatch`, `codex-linux-sandbox` and
`codex-execve-wrapper`. After an image rebuild those targets no longer
exist. `chown` without `-h` tries to follow each link, fails with "cannot
dereference", and **`find` propagates a non-zero exit** — measured, not
assumed: `find` returns `1`, and under `set -euo pipefail` the script dies
there.

Two things made this hard to see:

- **The symptom names the wrong layer.** "Connection refused" reads as
  *never deployed*. The container was being created and dying, over and
  over.
- **CLEAN could not fix it.** The stale symlinks live in the persistent
  `codex_home` volume. CLEAN rebuilds the *image*. So the heaviest repair
  the menu offers left the cause untouched — and in fact *created* it,
  since rebuilding is what invalidates the symlink targets.

**Fix:** `chown -h` (`--no-dereference`) in the `find -exec`. It changes the
link itself and never touches the target, so a broken link is chowned
successfully instead of aborting the boot.

Applied to `codex-cli`, and to `pi` and `opencode`, which were built from
this same template and carried the same latent bug.

`claude-cli` and `aider` are **not** affected: they use `chown -R`, which
does not dereference symlinks encountered during recursion. Verified rather
than assumed — `chown -R` over a dangling symlink returns 0 and survives
`set -e`.

**General lessons:**

- **`chown` dereferences; `chown -R` does not.** Any recursive ownership
  pass over a directory an *agent* writes into needs `-h`, because agents
  routinely leave temp symlinks whose targets are rebuilt away.
- **`set -euo pipefail` in an entrypoint turns a cosmetic warning into a
  crash loop.** `find -exec … +` returning non-zero because one of many
  invocations failed is exactly that shape.
- **"Connection refused" means the container is not listening — check
  `docker ps -a` for `Restarting`, then `docker logs`, before assuming it
  was never deployed.** Two hypotheses were proposed from reading code
  against the symptom, and both were wrong; the log named the cause
  immediately.
- **When CLEAN does not fix something, suspect volume state.** The rule of
  thumb: CLEAN rebuilds images, WIPE removes volumes, and a bug that
  survives CLEAN lives in the half CLEAN does not touch.
