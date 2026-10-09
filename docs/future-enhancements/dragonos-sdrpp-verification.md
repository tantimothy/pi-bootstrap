# dragonos-sdr: verify the SDR++ build

**Status:** shipped unverified.

SDR++ (`environments/dragonos-sdr/Dockerfile`, `ARG SDRPP_VERSION=1.0.4`) was
added from a session that could not run `docker build`. The build is
deliberately non-fatal: a failure prints `WARNING: SDR++ failed to build` and
the rest of the image is unaffected.

## To verify (on a Pi)

1. `REBUILD_POLICY=CLEAN` deploy; confirm the build log has no SDR++ warning
   and `which sdrpp` resolves inside the container.
2. `run.sh --gui sdrpp`: window opens over X11 forwarding, RTL-SDR and HackRF
   appear as sources, audio plays through PulseAudio/PipeWire.
3. Check the OpenGL path works without GPU passthrough (Mesa software
   rendering); if it is unusably slow, document it or consider passing `/dev/dri`.

## Open questions

- 1.0.4 is the only stable tag and predates many `master` fixes. Pinning a
  `master` commit instead (as `acarsdec` is) may be needed if 1.0.4 fails on
  bookworm's libraries (`libvolk2`, `librtaudio` 5.x, GLFW 3.3).
- Once verified, delete this file and drop the "unverified" notes in the
  Dockerfile comment and `README.md`.
