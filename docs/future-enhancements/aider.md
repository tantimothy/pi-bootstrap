# Aider Environment — Future Enhancements & Refactoring Opportunities

**Status:** ideas only — none of this is implemented as a fix, just
tracked so an untested assumption doesn't quietly get treated as verified
fact. This environment (and its two extra frontend options) has not yet
had a real deploy against a live Raspberry Pi/host to confirm against.

## Future Enhancements

### 1. Live-verify Frontend Option A (Aider's own `--gui`)

`scripts/aider-gui.sh` launches `aider --gui` (with
`STREAMLIT_SERVER_ADDRESS=0.0.0.0`/`STREAMLIT_SERVER_HEADLESS=true`) in a
detached tmux session, based on reading Aider's own documentation
([aider.chat/docs/usage/browser.html](https://aider.chat/docs/usage/browser.html),
which itself calls the feature experimental) rather than a live test
against the actual installed `aider-chat` pip package version this
environment's Dockerfile pulls. Not yet confirmed:

- That `aider --gui` still exists as a CLI flag in the current `aider-chat`
  release (experimental features get renamed/removed between versions more
  often than stable ones).
- That the `STREAMLIT_SERVER_*` env vars actually control the underlying
  Streamlit server the way assumed — if Aider's own `--gui` wrapper sets
  conflicting Streamlit config itself, this could be a silent no-op rather
  than an error.
- That the browser UI, once reached, can actually make edits/execute
  commands against the mounted workspace the same way the terminal session
  can.

Confirm all three on the first real deploy; if `--gui` no longer exists or
behaves differently, update or remove this frontend option rather than
leaving stale instructions in the README.

### 2. Live-verify Frontend Option B (OpenVSCode Server)

`Dockerfile.ide` builds `lscr.io/linuxserver/openvscode-server` plus a
plain `apt-get install python3-pip` + `pip3 install aider-chat` layer,
based on reading that base image's own documented layout (Ubuntu Jammy,
port 3000, `/config/workspace`) rather than a live build. Not yet
confirmed: that the image actually builds cleanly (Jammy's own package
repos could have shifted since this was written), that PUID/PGID
environment variables are respected the way linuxserver's other images
document, and that `aider` launched from the integrated terminal picks up
the same `ANTHROPIC_API_KEY`/`OPENAI_API_BASE`/etc. environment variables
correctly (linuxserver images run under s6-overlay init, which handles
environment variable propagation to child processes slightly differently
across image families).

### 3. Live-verify `chat-frontends`' `OPENAI_API_BASE_URL` addition

Open WebUI's own documentation states `OLLAMA_BASE_URL` and
`OPENAI_API_BASE_URL` can coexist, merging both provider's models into one
dropdown — not independently confirmed against a live deploy of this
specific combination (Open WebUI + `llm-gateways`' LiteLLM, both pointed
at from the same container). If it turns out one silently overrides the
other instead of merging, this needs a real fix, not just a doc correction.
