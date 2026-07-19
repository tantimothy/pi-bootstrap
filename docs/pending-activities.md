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

`claude-cli` multi-instance support (`new-instance.sh`, `deploy.sh`'s A-Z
menu tags — PRs #135/#139, both merged) — nothing below has been run
against a real Docker host yet, only simulated/verified in isolation:

- **End-to-end instance creation** — run the "New Claude CLI Instance..."
  `custom_actions` entry (or `new-instance.sh` directly) and confirm a
  second instance actually builds, deploys, and is independently
  SSH-reachable on its own port, with its own `claude_home`/
  `ssh_host_keys` volumes.
- **The action's own visibility** — confirm "New Claude CLI Instance..."
  actually appears in `deploy.sh`'s real policy menu for `claude-cli`
  (alongside FAST/STOP/CLEAN/etc.), not just in the `custom_actions`
  YAML/parsing logic that was checked directly.
- **A-Z menu tags** — confirm `deploy.sh`'s Environments submenu actually
  renders `A`-`Z` tags past the 9th environment through a real `dialog`
  render, not just the tag-generation/lookup logic checked in isolation.

## Known, deliberately-deferred code quality items

Tracked in full in `docs/refactoring-opportunities.md`, not duplicated
here — includes shared logic between `point-to-gateway.sh`/
`revert-to-claude.sh`, three independent "auto-discover, else prompt,
else fall back" implementations, `backup.sh`'s manually-maintained
`is_deployed()` case statement, `new-instance.sh`'s `sed`-based
`config/environments.yaml` registration and its SSH-port suggestion not
checking real port availability, and the total absence of automated tests
for `lib/*.sh`'s `${VAR}`-expansion contract.
