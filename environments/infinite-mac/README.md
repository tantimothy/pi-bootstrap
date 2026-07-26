# Infinite Mac — Classic Mac OS in a Browser

Builds and serves [mihaip/infinite-mac](https://github.com/mihaip/infinite-mac) — the code behind [infinitemac.org](https://infinitemac.org): System 1 through Mac OS 9, running as WebAssembly entirely in the browser, no plugins.

The emulators themselves run **client-side** (WebAssembly, in whichever browser opens the page) — this environment only builds the static site and serves it. There's no persistent server-side data at all; each emulated Mac's own disk state lives in the browser's IndexedDB.

---

## Will this run on my hardware?

Yes, on both a 64-bit Raspberry Pi and macOS (checked directly rather than assumed):

- WebAssembly is architecture-independent — it runs the same in any browser regardless of the host CPU.
- Upstream's own `Dockerfile` (only used to rebuild the emulator *cores* from C/C++ source, which this environment's own `Dockerfile` never does) explicitly avoids Emscripten's architecture-pinned images: *"Emscripten has separate arm64 vs. x86-64 Docker images, so to simplify things install the SDK manually"* — everything it installs (Node, uv, rustup) has arm64 builds.
- This environment's own build (Node + npm + uv, no Emscripten/Rust needed since the compiled WASM is already committed upstream) has no architecture-specific dependencies either — confirmed by reading `package.json`'s dependency list.

`docker compose build` always builds natively for the host it runs on, so this targets your Pi's actual architecture (arm64/armhf) or your Mac's, with no cross-compilation or emulation involved.

---

## Deployment

```bash
./deploy.sh   # → Environments → Infinite Mac → FAST
```

or directly:

```bash
docker compose up -d --build
```

First build compiles nothing exotic — clones upstream (with submodules), `npm install`, generates a minimal disk/library set (System 1–7.5.5, no CD-ROMs/downloads library), then `vite build`. No ROM files, licensing questions, or external data dump needed for this default "minimal" set — it's built entirely from disk images already committed in upstream's own repo.

Then open **`https://<pi-ip>:4127`** (see the HTTPS note below).

## 🎛️ Deployment Policies

Standard `docker-compose.yml` semantics (`FAST`/`STOP`/`TEARDOWN`/`CLEAN`/`INFO`) — no `run.sh` needed, see [pi-barebones](../pi-barebones/README.md) or [ntopng](../ntopng/README.md) for how the generic dispatcher handles each. `WIPE` is hidden from this environment's menu — there's no persistent data to delete.

**Important**: `FAST` only builds the image once — a plain (non-`CLEAN`) rebuild reuses Docker's cached layers, *including the `git clone` step*, so it will never pick up upstream `infinite-mac` changes on its own. Use the custom action below for that, or `CLEAN` for a full from-scratch rebuild.

---

## 🔧 Custom Actions (in `deploy.sh`'s per-environment menu)

| Action | What it does |
|--------|--------------|
| **Update to latest infinite-mac and rebuild** | Busts the Docker cache from the `git clone` step onward (`--build-arg CACHEBUST=$(date +%s)`) and recreates the container — picks up upstream changes much faster than `CLEAN`, since the `apt`/`uv` toolchain layers above it stay cached. |
| **Shell into the container** | `docker exec -it` a bash shell in the running container. |
| **Tail live logs** | `docker logs -f`. |

---

## HTTPS and the Self-Signed Certificate

`vite preview` (what this container runs) serves over HTTPS with a self-signed certificate — required for the emulators' use of `SharedArrayBuffer`/service workers, which need a secure context. Your browser will show a security warning on first visit; proceed past it (or import the generated cert if you'd rather not see it again). This is the same tradeoff Portainer's HTTPS port makes elsewhere in this repo.

---

## Going Beyond the Minimal Library

This environment builds upstream's **"minimal"/"placeholder"** presets — System 1 through 7.5.5, no CD-ROM library, no downloads library. Upstream's full library (more OS versions, a large software library sourced from Macintosh Garden, self-hosted CD-ROMs) needs things this environment deliberately doesn't automate:

- `import-library` (without `placeholder`) needs a Macintosh Garden data dump file you'd have to supply yourself.
- `import-cd-roms` (without `placeholder`) pulls from upstream's own Cloudflare R2-hosted media.

If you want that, shell into the container (custom action above) or adapt `Dockerfile`'s `import-*` steps yourself — see [upstream's README](https://github.com/mihaip/infinite-mac#command-reference) for the full options.

---

## 💡 Useful Commands

```bash
docker compose -f docker-compose.yml ps          # Stack status
docker logs -f infinite-mac                       # Live logs
docker exec -it infinite-mac bash                 # Shell in
```
