# NanoClaw Environment — Future Enhancements & Refactoring Opportunities

**Status:** ideas only — none of this is implemented as a fix, just
tracked so an untested assumption doesn't quietly get treated as verified
fact. See `docs/lessons-learned/nanoclaw.md` for this environment's actual
debugging history.

## Future Enhancements

### 1. Live-verify the admin-session tmux wrapper and `CLAUDE_MODEL`

`scripts/open-claude-session.sh`'s host-mode tmux branch and container-mode
`nanoclaw-claude-tmux.sh` wrapper (grouped-session pattern, same mechanism
as the standalone `claude-cli` environment's own login shell and the
sibling `nanoclaw-mnemon` environment's identical `claude-tmux.sh`), plus
`CLAUDE_MODEL` passthrough (`docker run -e` in container mode, direct
`.env` sourcing in host mode), were written and syntax-checked
(`bash -n`) but not exercised against a real deploy in either deploy mode.
Not yet live-confirmed:

- Two simultaneous connections (two terminals running "Open a Claude
  Session," or one plus a direct `docker exec`/`tmux attach`) actually land
  on independent tmux windows sharing one `claude --continue` conversation,
  in both `host` and `container` mode.
- The host-mode fallback to a plain, non-tmux `claude` launch actually
  triggers correctly when `tmux` isn't installed (the expected case on a
  fresh macOS host before this environment does anything to install it).
- `scripts/choose-model.sh` actually carries the new `CLAUDE_MODEL` value
  through to the next session in both modes — container-mode recreation,
  and host-mode's "no restart needed, `.env` is read fresh" claim.

Confirm all three on the first real deploy after this change. If the
grouped-session fallback doesn't behave as documented (e.g.
`destroy-unattached on` not cleaning up a detached grouped session, or the
base session not falling through correctly on a cold start), this needs a
follow-up fix, not just doc corrections. Same caveat applies to the
identical mechanism in the `claude-cli` and `nanoclaw-mnemon` environments
— see their own `docs/future-enhancements/` entries.

**Update — the sibling `nanoclaw-mnemon` environment's first real deploy
surfaced the same bugs here (container mode is the identical mechanism),
all now fixed and confirmed live *on `nanoclaw-mnemon`* — this
environment's own copies got the identical code changes but haven't
independently been exercised on a real deploy yet:**

- **`deploy.sh`'s own config form was silently dropping `CLAUDE_MODEL`**
  on the next menu-driven redeploy — fixed in `deploy.sh` itself
  (repo-wide, not specific to either NanoClaw environment).
- **A fresh admin session had no self-awareness of its own environment**
  — fixed with a regenerated `/root/CLAUDE.md` in container mode's
  `scripts/entrypoint.sh` (host mode has no equivalent container to
  regenerate one for). A separate attempt at also persisting this
  session's conversation *history* across container recreation (a
  `${CONTAINER_NAME}_claude_home` named volume) was tried and then
  reverted: never actually requested (losing history was explicitly said
  to be acceptable), and it ran into a genuine OrbStack Docker-
  implementation bug that made deployment fail outright — see
  `docs/lessons-learned/general.md`'s own "Ultimately reverted, not
  shipped" addendum.
- **Root-caused and fixed: "Open a Claude Session" opened plain `bash`
  instead of `claude`, and a freshly-picked `CLAUDE_MODEL` never took
  effect.** Both traced to the grouped-session tmux pattern's own "is
  this the first connection ever" check never actually firing the way it
  assumed — see `docs/lessons-learned/nanoclaw-mnemon.md`'s two entries
  on this for the full investigation and fix (`tmux has-session` gate,
  plus a `claude --continue || claude` fallback for when there's nothing
  to resume yet). Fixed identically in this environment's own
  `scripts/claude-tmux.sh` and `scripts/open-claude-session.sh`'s
  host-mode branch — **not yet independently live-confirmed on `nanoclaw`
  itself**, only on the sibling `nanoclaw-mnemon` environment, since
  container mode is genuinely the same mechanism but host mode's
  non-tmux fallback and the multi-instance/two-simultaneous-connections
  behavior remain entirely untested either way.
