**Read this before diagnosing any "the patch is applied but the agent still
behaves like it isn't" symptom.** It is not a patch. It is the layer between
the patches and what an agent actually runs, and not knowing it existed cost
a real deployment several days of chasing correct code.

**The thing to know.** NanoClaw does not always run agents from the base
agent-sandbox image. A conversation group that installs custom packages —
through its own `install_packages` self-modification flow, or
`ncl groups add-package` — gets **its own derived image**, built FROM the
base and tagged `nanoclaw-agent-v2-<slug>:<group-id>`. That tag is stored in
NanoClaw's `container_configs` table, and `container-runner.ts` passes it
straight to `docker run` on every spawn for that group.

So there are two images in play, and they drift apart:

| | Base image | Derived per-group image |
|---|---|---|
| Tag | `nanoclaw-agent-v2-<slug>:latest` | `nanoclaw-agent-v2-<slug>:<group-id>` |
| Rebuilt by | every CLEAN deploy, from the patched `container/Dockerfile` | **nothing in pi-bootstrap** — only `ncl groups restart --id <id> --rebuild` |
| Contains this deploy's patches | yes | only as of whenever it was last rebuilt |

**Why this produces the most confusing possible symptom.** Every patch this
environment applies goes into `container/Dockerfile`, which builds the
*base*. A group with a derived image keeps running whatever the base looked
like on the day that derived image was built. So you get:

- the base image passes every check — `whisper-cli` statically linked,
  correct mnemon ENVs, everything the manifest claims;
- the group's actual agent fails those same checks;
- and **replacing the container changes nothing**, because it respawns from
  the same stale derived image.

A real install ran a 2026-07-21 derived image against a 2026-08-06 base for
over two weeks. `whisper-cli` stayed dynamically linked and mnemon kept
reporting `ollama_available: false` through repeated CLEAN deploys, while
every image-level check said healthy. Both symptoms were the derived image,
not the patches — which had been correct the whole time.

`run.sh` now rebuilds any derived image older than the base after each base
rebuild, so this should not recur. The status above says what it found.

**The second failure mode: deleting a derived image breaks that group
silently and totally.** The tag stays in NanoClaw's database. `docker run`
against a tag with no image and no registry fails instantly with exit 125,
and the captured stderr comes back empty, so NanoClaw's close handler emits
nothing at INFO. The only visible symptom is:

```
INFO Spawning container containerName="nanoclaw-v2-<group>-<timestamp>"
...60 seconds later...
INFO Spawning container containerName="nanoclaw-v2-<group>-<timestamp+60>"
```

forever, with the pending message count climbing and never dropping. No
error, no WARN, no "Container exited". If a channel has gone unresponsive
and the logs look like this, check that the group's image still exists
before looking anywhere else. **Do not hand-delete `nanoclaw-agent-v2-*`
images that are not `:latest`** — each one is load-bearing for a specific
group.

**Diagnosing it:**

```
# what images exist, and how old is each relative to the base?
docker images --format '{{.Repository}}:{{.Tag}}\t{{.CreatedAt}}' | grep nanoclaw-agent-v2-

# which image does a group actually use, and does it exist?
docker image inspect nanoclaw-agent-v2-<slug>:<group-id> >/dev/null && echo present || echo MISSING
```

**Fixing it**, from inside the orchestrator container — this rebuilds the
derived image on top of the current base and updates the stored tag. It
takes several minutes, because it reinstalls that group's custom packages:

```
cd $NANOCLAW_INSTALL_PATH && pnpm ncl groups restart --id <group-id> --rebuild
```

Note `pnpm ncl`, not bare `ncl`: in the orchestrator container `ncl` is a
pnpm script alias inside NanoClaw's source tree, not a global binary, so it
needs both the `cd` and the `pnpm` prefix. (Bare `/usr/local/bin/ncl` does
exist inside *agent* containers — different image, different story.)
