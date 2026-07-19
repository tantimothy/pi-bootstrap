# `claude-cli` Gateway Redirect — Hardening

**Status:** shipped, but with two explicitly unverified assumptions (see
`environments/claude-cli/README.md`'s "Pointing Claude CLI at a Gateway"
section and both `.env.gateway.litellm`/`.env.gateway.portkey`'s own
comments). This doc tracks what closing those out — and a couple of real
usability follow-ups — would look like, so they don't only exist as
buried caveats.

## Problem

`environments/claude-cli/scripts/point-to-gateway.sh` redirects Claude
Code's `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN` at a self-hosted
gateway (this repo's own `llm-gateways` environment — LiteLLM or Portkey
— or any other endpoint). It was built and documented honestly as
**not independently verified against a live gateway from inside this
repo** for two specific reasons:

1. Claude Code's `ANTHROPIC_BASE_URL` expects a server speaking the
   Anthropic Messages API shape. `llm-gateways`' own README documents
   calling LiteLLM/Portkey via their OpenAI-compatible
   `/v1/chat/completions`-shaped endpoint — a different format. Both
   projects document *some* Anthropic-compatible route, but nobody has
   confirmed the specific base URLs `.env.gateway.litellm`/
   `.env.gateway.portkey` assume actually serve that shape, for the
   versions this repo currently pins.
2. Claude Code's `/remote-control` linkage is gated on a
   Pro/Max/Team/Enterprise OAuth subscription login — a separate channel
   from wherever `ANTHROPIC_BASE_URL` points model traffic. Whether an
   already-linked `/remote-control` session tolerates a live gateway
   redirect without needing to be re-linked has never been tested against
   a real deploy.

## Proposed follow-ups

### 1. Live-verify the gateway API shape (highest value, lowest effort)

Deploy `llm-gateways` for real, fill in a real `ANTHROPIC_AUTH_TOKEN` in
`.env.gateway.litellm` (and/or `.env.gateway.portkey`), run
`point-to-gateway.sh`, and send `claude` a real message. Two outcomes:

- **It works** — update `environments/claude-cli/README.md` and both
  `.env.gateway.*` files' comments the same way `nanoclaw-mnemon`'s own
  README was updated after its own live-verification saga: replace "not
  independently verified" with a dated, specific confirmation, and remove
  this item from `docs/pending-activities.md`.
- **It doesn't** — figure out the actual correct path/config (LiteLLM and
  Portkey each document their own Anthropic-passthrough route somewhere;
  it may not be the bare base URL these files currently assume) and fix
  `.env.gateway.litellm`/`.env.gateway.portkey`'s defaults, the same way
  `apply_mnemon_patch()` went through two wrong fixes before the verified
  one — see `docs/lessons-learned.md`'s first entry.

### 2. Live-verify `/remote-control` + gateway redirect interaction

Link a `claude-cli` session to `/remote-control`, then run
`point-to-gateway.sh` against it and check from claude.ai/code whether
the session stays linked and keeps responding (now via the gateway) or
needs re-linking. Update the README's caveat either way once known.

### 3. A "new gateway" wizard, mirroring `new-instance.sh`

Right now, adding a gateway beyond LiteLLM/Portkey means manually copying
`.env.gateway.example` to `.env.gateway.<name>` and hand-editing both
values (see the README's "Adding a gateway beyond these two"). A small
`scripts/new-gateway.sh` — prompt for a name, base URL, and token, write
the file, no different in spirit from `new-instance.sh`'s prompt-driven
folder creation — would remove the manual-copy step. Not built yet
because there's no evidence anyone's needed a third gateway; worth
revisiting if that changes.

### 4. Extract shared logic between the two gateway scripts

See `docs/refactoring-opportunities.md`'s first entry — tracked there,
not duplicated here, since it's a code-quality concern rather than a new
capability.
