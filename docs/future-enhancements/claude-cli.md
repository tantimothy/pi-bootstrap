# Claude CLI Environment — Future Enhancements & Refactoring Opportunities

**Status:** ideas only — none of this is implemented. Captured here after
the environment's first real deploy surfaced several issues one at a time
(see `docs/lessons-learned/claude-cli.md` for the full account); these are
the follow-ups worth doing deliberately rather than reactively.

## Future Enhancements

### 1. CI build validation

All three build-breaking issues hit on first deploy (bad `gh` apt URL, UID
1000 collision, `groupdel` failure — see lessons-learned doc) would have
been caught by a plain `docker build` before ever reaching a real Pi. A
GitHub Actions workflow that builds `environments/claude-cli`'s image (and
ideally every Docker-based environment in this repo) on any PR touching its
Dockerfile would close this gap for good, not just for this one environment.

### 2. Confirm (not assume) `claude --continue`'s empty-history behavior

The fix that makes conversation continuity survive a container restart
(`bashrc-tmux-attach.sh` launching `claude --continue` instead of bare
`claude`) rests on an unverified assumption: that `--continue` degrades
gracefully to a fresh session when there's no history to continue, rather
than erroring. Once confirmed against a genuinely fresh `claude_cli_home`
volume, update the README to state this as verified fact rather than an
assumption. If it turns out `--continue` does error in that case, this
needs a deliberate fix — not a blind `claude --continue || claude` fallback,
since that risks turning every intentional `/exit` into an unwanted
auto-restarted new session. A real fix would need some way to distinguish
"nothing to continue" from "the user exited on purpose."

### 3. Expose `claude --resume` as its own menu action

"SSH into Claude CLI" already exists as a `deploy.sh` `custom_actions` menu
entry (`info.yaml`). A second entry that SSHes in and runs `claude --resume`
directly would let a user pick an older conversation from `deploy.sh`
itself, without first having to know about `Ctrl-b c` / getting a plain
shell manually.

### 4. Detect/warn on the `authorized_keys` directory-vs-file footgun

Right now this is purely a documented manual diagnosis (README's
Troubleshooting section). `entrypoint.sh` already checks
`[ -f /run/host-authorized_keys ]` and silently falls back to an empty file
when that's false — it could instead detect the specific "it's a directory"
case and print an explicit, actionable warning (mirroring the diagnosis in
the Troubleshooting doc) instead of just going quiet and rejecting every
key with no hint why.

### 5. Generalize PUID/PGID collision handling

The UID 1000 fix (issue #2 in lessons-learned) only handles the one
collision this repo happens to know about — the base image's own `node`
user. A user who sets `PUID`/`PGID` in `.env` to some other value that
happens to collide with a different pre-existing account in the image
(anything else baked into `node:20-slim`, or added by a future Dockerfile
change) would hit the same class of failure, just with a more cryptic
runtime `usermod`/`groupmod` error and no explanation. `entrypoint.sh`
could check `getent passwd "$PUID"` / `getent group "$PGID"` before
attempting the rename and fail with a clear message naming the conflicting
account, instead of usermod's own opaque error.

## Refactoring Opportunities

### 1. Make the Dockerfile's node-removal step more explicit

```dockerfile
RUN userdel -r node \
    && (groupdel node || true) \
    && useradd --uid 1000 --create-home --shell /bin/bash claude
```

This works, but relies on knowing Debian's `USERGROUPS_ENAB=yes` default
behavior (that `userdel -r` already removes the private group, making the
follow-up `groupdel` a coin-flip between "no-op" and "already gone"). A more
self-documenting version would check for existence explicitly rather than
suppressing the failure blindly:

```dockerfile
RUN (getent passwd node >/dev/null && userdel -r node || true) \
    && (getent group node >/dev/null && groupdel node || true) \
    && useradd --uid 1000 --create-home --shell /bin/bash claude
```

Functionally equivalent today, but doesn't depend on the reader already
knowing the login.defs behavior to understand why the `groupdel` might
legitimately fail.

### 2. `entrypoint.sh`'s usermod/groupmod hardening

Same underlying gap as Future Enhancement #5 above — the current
`usermod -u "$PUID" claude` / `groupmod -g "$PGID" claude` calls have no
guard against colliding with any other account, and their failure mode
(under `set -euo pipefail`) is the container exiting with no clear
diagnostic beyond whatever `usermod` printed. Worth revisiting alongside
that enhancement rather than as a separate change, since it's the same code
path.

### 3. Desktop entry ID collisions across multiple instances

Already documented as a known limitation in the README's "Running Multiple
Instances" section, not something newly discovered here — carried over
into this list since it's a genuine, still-open refactoring target.
`desktop-entries.yaml`'s `entries[].id`/`menu.id`/`info.id` are fixed
literals rather than `${CONTAINER_NAME}`-expanded (unlike
`docker-compose.yml`'s own `container_name:`/volume `name:` fields), so a
second `claude-cli`-derived instance's desktop shortcuts silently overwrite
the first instance's on install.
