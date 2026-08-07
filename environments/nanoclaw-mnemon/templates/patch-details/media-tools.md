**What this patch is for.** It gives the *agent itself* — not just the
orchestrator — the ability to fetch and transcribe audio/video through its
own Bash tool, so a user can paste a URL into chat and get a transcript
back. Stock NanoClaw's agent sandbox has none of these binaries.

**Files it changes, and where.**

| File | Anchor it splices at | What it adds |
|---|---|---|
| `container/Dockerfile` | the line `# ---- Bun runtime` | `ffmpeg` (apt), `whisper-cli` (whisper.cpp, built from source), `yt-dlp` (release binary) |

The whole block sits inside `# >>> pi-bootstrap:media-tools vN >>>` /
`# <<< pi-bootstrap:media-tools <<<` markers.

If the status above reports **SKIPPED**, the `# ---- Bun runtime` anchor this
patch splices at has moved upstream; apply the block by hand per this
environment's README.

**The pre-marker era (a STALE status).** Blocks written before this script
tracked patch versions carry no markers, and an unmarked block has no reliable
end boundary — so it cannot be replaced in place and is left alone rather than
mangled. Only a CLEAN clears it, by hard-resetting `container/Dockerfile` to
upstream so this patch re-applies at the current version. **The symptom while
stale is specifically item 1 below:** `whisper-cli` fails with
`libwhisper.so.1: cannot open shared object file`, because the old block
predates `-DBUILD_SHARED_LIBS=OFF`. That is exactly how this went unnoticed —
the content-blind check of that era saw `yt-dlp` in the file, called the patch
applied, and never looked at the cmake line again.

**The shape a correct fix has to have.** Each of these three was a real
build or runtime failure, and each is easy to regress by writing the
"obvious" version of the line:

1. **whisper.cpp must be built with `-DBUILD_SHARED_LIBS=OFF`.** Without
   it, cmake links `whisper-cli` dynamically against `libwhisper.so.1` and
   `libggml*.so`, which live under the build tree. The Dockerfile copies
   out only the binary and then deletes that tree, so the shipped
   `whisper-cli` has an unsatisfiable runtime dependency and dies with
   `libwhisper.so.1: cannot open shared object file: No such file or
   directory`. A static build removes the dependency rather than trying to
   arrange matching libs on `LD_LIBRARY_PATH`.
2. **whisper.cpp must be built with clang, not the default GCC.** Debian
   bookworm's GCC 12 hits a known ggml/whisper.cpp incompatibility on
   arm64 — `inlining failed in call to 'always_inline' float16x8_t
   vfmaq_f16(...): target specific option mismatch` — in ggml's ARM NEON
   fp16 codepath. GCC 13+ and clang both compile it fine. So the cmake
   invocation passes `-DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++`.
3. **yt-dlp must be an arch-matched `yt-dlp_linux*` release asset.** The
   plain `yt-dlp` asset is a zipimport script with a
   `#!/usr/bin/env python3` shebang, and this image deliberately has no
   system python3. The asset name is chosen from `uname -m` at build time
   rather than hardcoded, because this image is built on whatever host runs
   it (arm64 on a Pi or Apple Silicon Mac, amd64 on an Intel Mac).

**The failure mode that is NOT a patch bug, and has cost the most time
here.** If `whisper-cli` is missing or dynamically linked *inside a running
agent container*, check the image before touching this patch:

```
# in the agent container that is actually serving messages:
ldd $(which whisper-cli)        # "not a dynamic executable" is the healthy answer
```

```
# on the host, against the current image tag:
docker run --rm <agent-image-tag> ldd /usr/local/bin/whisper-cli
```

If the **image** is fine and the **running container** is broken, nothing
is wrong with this patch — the container predates the image and simply
needs replacing. That exact split (a fresh `docker run` passing while the
live container failed) is why the smoke-test checklist now tests a live
container rather than a throwaway one, and why the deploy script rebuilds
the agent image *before* restarting NanoClaw and then discards any agent
container spawned from the pre-rebuild image. Reporting "whisper is broken"
without distinguishing these two cases will send the next session chasing
the compile flags again, which were already correct.

**Other checks worth running in the agent container:**

```
whisper-cli --help
yt-dlp --version
ffmpeg -version
```

Note that no whisper *model* file is baked into the image (they run
148MB-3GB+, and which one to use is a user choice). The model has to live
in the group's own folder — see this environment's README, "Transcribing
Audio/Video", for the one-time download command and the exact path.
