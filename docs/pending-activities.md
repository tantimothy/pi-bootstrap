# Pending Activities

A snapshot of open follow-ups as of **2026-07-19**. GitHub itself (PR/issue
state) is always the authoritative source for anything below that
references a PR — this file is a convenience index, not a system of
record, and goes stale the moment something merges or gets tested. Prune
an entry the moment it's resolved rather than marking it done in place;
an out-of-date "pending" list is worse than none.

---

## Needs a live test to close out

Both from `docs/future-enhancements/claude-cli-gateway-hardening.md` —
full context there, summarized here for visibility:

- **`claude-cli` gateway redirect API-shape compatibility** — confirm
  LiteLLM/Portkey (as deployed by this repo's `llm-gateways` environment)
  actually serve an Anthropic-Messages-API-compatible endpoint at the
  base URLs `environments/claude-cli/.env.gateway.litellm`/
  `.env.gateway.portkey` currently assume. Currently shipped with an
  explicit "not independently verified" caveat in both files and
  `environments/claude-cli/README.md`.
- **`claude-cli` gateway redirect + `/remote-control` interaction** —
  confirm whether an already-linked `/remote-control` session survives a
  live `point-to-gateway.sh` redirect without needing to re-link.

## Known, deliberately-deferred code quality items

Tracked in full in `docs/refactoring-opportunities.md`, not duplicated
here — includes shared logic between `point-to-gateway.sh`/
`revert-to-claude.sh`, three independent "auto-discover, else prompt,
else fall back" implementations, and `backup.sh`'s manually-maintained
`is_deployed()` case statement.
